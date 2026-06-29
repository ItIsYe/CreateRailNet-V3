--[[
Purpose: OTA update status panel — version tracking per node, push trigger.
]]

local ui_utils = require("src.master.ui.ui_utils")
local ota_status = {}

function ota_status.new(registry, audit_log_ref)
  local self = { offset = 0 }
  local C = ui_utils.colors

  local function get_ota_results()
    local results = {}
    local entries = audit_log_ref and audit_log_ref.list and audit_log_ref.list() or {}
    for i = #entries, 1, -1 do
      local e = entries[i]
      if e.kind == "ota_success" or e.kind == "ota_failed" then
        local nid = e.data and e.data.node_id
        if nid and not results[nid] then
          results[nid] = {
            success = (e.kind == "ota_success"),
            version = e.data and e.data.version or "?",
            ts = e.ts
          }
        end
      end
    end
    return results
  end

  local function master_version()
    if fs and fs.exists and fs.exists("crn_version.txt") then
      local fh = fs.open("crn_version.txt", "r")
      if fh then local v = fh.readLine(); fh.close(); return v or "?" end
    end
    return "nicht gesetzt"
  end

  function self.draw(monitor)
    if not monitor then return end
    local u = ui_utils.new(monitor)
    local w, h = u.size()

    u.clear(C.black)
    u.header(1, "FERNUPDATE  (OTA)", nil, w)

    -- Master version
    local mver = master_version()
    u.fill_line(2, C.blue, w)
    u.write_at(1, 2, " Master-Version: " .. tostring(mver):sub(1, w-18), C.white, C.blue)

    -- Column headers
    u.fill_line(3, C.gray, w)
    u.write_at(1, 3, string.format("%-18s %-18s %-6s %-5s", "NODE-ID", "VERSION", "STATUS", "ROLLE"), C.white, C.gray)

    local ota_results = get_ota_results()
    local nodes = registry and registry.all and registry.all() or {}
    local sorted = {}
    for id, n in pairs(nodes) do table.insert(sorted, {id=id, n=n}) end
    table.sort(sorted, function(a,b) return a.id < b.id end)

    local row = 4
    local start = self.offset + 1

    for i = start, #sorted do
      if row > h - 3 then break end
      local entry = sorted[i]
      local r = ota_results[entry.id]

      u.fill_line(row, C.black, w)
      u.write_at(1, row, tostring(entry.id):sub(1, 17), C.white)

      local ver = r and r.version or "-"
      local same_ver = (r and r.version == mver)
      u.write_at(20, row, tostring(ver):sub(1, 17), same_ver and C.lime or C.yellow)

      if r then
        local sc = r.success and C.lime or C.red
        u.write_at(39, row, r.success and "OK    " or "FEHLER", sc)
      else
        u.write_at(39, row, "?     ", C.lightGray)
      end

      local role_str = tostring(entry.n.role or "?"):sub(1,6)
      u.write_at(46, row, role_str, C.cyan)
      row = row + 1
    end

    if #sorted == 0 then
      u.write_at(3, 4, "Keine Nodes registriert.", C.lightGray)
    end

    u.separator(h - 2, w)
    u.write_at(1, h - 1, "OTA Push: manual action 'ota_push' im Panel", C.lightGray)
    u.footer(h, string.format("Antippen=Scroll  %d/%d Nodes", math.min(self.offset+1, math.max(1, #sorted)), #sorted), w)
  end

  function self.touch(x, y)
    local _, h = 51, 19
    if y > h / 2 then
      self.offset = self.offset + 1
    else
      self.offset = math.max(0, self.offset - 1)
    end
  end

  return self
end

return ota_status
