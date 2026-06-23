--[[
Purpose: OTA update status panel — shows version per node and update history.
Public API: new(registry, audit_log) -> panel with draw(monitor), touch(x, y).
]]

local ota_status = {}

function ota_status.new(registry, audit_log_ref)
  local self = { offset = 0 }

  -- Collect latest OTA result per node from audit log
  local function get_ota_results()
    local results = {}
    local entries = audit_log_ref and audit_log_ref.list and audit_log_ref.list() or {}
    -- Walk backwards to get most recent per node
    for i = #entries, 1, -1 do
      local e = entries[i]
      if e.kind == "ota_success" or e.kind == "ota_failed" then
        local nid = e.data and e.data.node_id
        if nid and not results[nid] then
          results[nid] = {
            node_id = nid,
            success = (e.kind == "ota_success"),
            version = e.data and e.data.version or "?",
            ts = e.ts
          }
        end
      end
    end
    return results
  end

  function self.draw(monitor)
    if not monitor then return end
    local w, h = 51, 19
    if monitor.getSize then w, h = monitor.getSize() end
    monitor.clear()

    monitor.setCursorPos(1, 1)
    monitor.write("== OTA STATUS ==")

    -- Current version from crn_version.txt
    local current_version = "unknown"
    if fs and fs.exists and fs.exists("crn_version.txt") then
      local fh = fs.open("crn_version.txt", "r")
      if fh then current_version = fh.readLine() or "unknown"; fh.close() end
    end
    monitor.setCursorPos(1, 2)
    monitor.write("Master: " .. tostring(current_version):sub(1, w-9))

    -- Per-node OTA results
    local row = 4
    monitor.setCursorPos(1, row); monitor.write("Node             Ver              Status")
    row = row + 1

    local ota_results = get_ota_results()
    local nodes = registry and registry.all and registry.all() or {}
    local sorted = {}
    for id, n in pairs(nodes) do table.insert(sorted, {id=id, n=n}) end
    table.sort(sorted, function(a, b) return a.id < b.id end)

    local max_row = h - 2
    local start = self.offset + 1

    for i = start, #sorted do
      if row > max_row then break end
      local entry = sorted[i]
      local r = ota_results[entry.id]
      local ver = r and r.version or "-"
      local status = r and (r.success and "OK" or "FAIL") or "?"
      monitor.setCursorPos(1, row)
      monitor.write(string.format("%-16s %-16s %s",
        entry.id:sub(1,16),
        tostring(ver):sub(1,16),
        status
      ))
      row = row + 1
    end

    if #sorted == 0 then
      monitor.setCursorPos(1, row)
      monitor.write("  (no nodes registered)")
    end

    -- Footer
    monitor.setCursorPos(1, h - 1)
    monitor.write("Touch: up=scroll up  down=scroll down")
    monitor.setCursorPos(1, h)
    local hint = "Panel manual action: ota_push to update all"
    monitor.write(hint:sub(1, w))
  end

  function self.touch(x, y)
    local h = 19
    if y <= h / 2 then
      self.offset = math.max(0, self.offset - 1)
    else
      self.offset = self.offset + 1
    end
  end

  return self
end

return ota_status
