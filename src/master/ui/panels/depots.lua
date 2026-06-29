--[[
Purpose: Depot panel — track occupancy, queue status, readiness.
]]

local ui_utils = require("src.master.ui.ui_utils")
local depots_panel = {}

local TRACK_LABELS = {
  EMPTY="FREI", OCCUPIED="BESETZT", STAGING="STAGING",
  READY="BEREIT", DEPARTING="ABFAHRT", FAULT="STOERUNG"
}

function depots_panel.new(depot_registry)
  local self = { offset = 0 }
  local C = ui_utils.colors

  function self.draw(monitor)
    if not monitor then return end
    local u = ui_utils.new(monitor)
    local w, h = u.size()

    u.clear(C.black)
    u.header(1, "ABSTELLANLAGEN", nil, w)

    local depots = depot_registry and depot_registry.list() or {}
    local sorted = {}
    for id, d in pairs(depots) do table.insert(sorted, {id=id, d=d}) end
    table.sort(sorted, function(a, b) return a.id < b.id end)

    if #sorted == 0 then
      u.write_at(3, 4, "Kein Depot registriert.", C.lightGray)
      u.footer(h, "Warte auf Depot-Verbindung...", w)
      return
    end

    u.fill_line(2, C.gray, w)
    u.write_at(1, 2, string.format("%-16s %-8s %-10s %-14s", "DEPOT", "STATUS", "GLEIS", "ZUG"), C.white, C.gray)

    local row = 3
    local start = self.offset + 1

    for i = start, #sorted do
      if row > h - 2 then break end
      local entry = sorted[i]
      local d = entry.d

      -- Depot header
      u.fill_line(row, C.black, w)
      local d_online = (d.state == "ONLINE")
      u.write_at(1, row, (d_online and "■" or "□") .. " ", d_online and C.lime or C.gray)
      u.write_at(3, row, tostring(entry.id):sub(1, 14), C.white)
      u.write_at(18, row, tostring(d.state or "-"):sub(1, 8), d_online and C.lime or C.gray)

      -- Queue display
      local qlen = #(d.queue or {})
      if qlen > 0 then
        u.write_at(w - 8, row, "Warte:" .. qlen, C.yellow)
      end
      row = row + 1

      -- Tracks
      local tracks = {}
      for tid, t in pairs(d.tracks or {}) do table.insert(tracks, {id=tid, t=t}) end
      table.sort(tracks, function(a,b) return a.id < b.id end)

      for _, te in ipairs(tracks) do
        if row > h - 2 then break end
        local t = te.t
        local state_col = (ui_utils.STATE_COLORS[tostring(t.state)] or {fg=C.lightGray}).fg
        local track_label = TRACK_LABELS[tostring(t.state)] or tostring(t.state or "?")

        u.fill_line(row, C.black, w)
        u.write_at(3, row, "  " .. tostring(te.id):sub(1,6), C.lightGray)
        u.state_badge(10, row, t.state)
        u.write_at(15, row, track_label:sub(1,8), state_col)

        local train_str = tostring(t.train_name or t.train_id or ""):sub(1, 14)
        if train_str ~= "" then
          u.write_at(24, row, train_str, C.yellow)
        end

        -- Destination/route if staged
        local route = tostring(t.route_id or ""):sub(1, 8)
        if route ~= "" then
          u.write_at(w - #route - 2, row, route, C.cyan)
        end
        row = row + 1
      end

      -- Queue items (first 2)
      for qi = 1, math.min(2, qlen) do
        if row > h - 2 then break end
        local qitem = d.queue[qi]
        if qitem then
          u.fill_line(row, C.black, w)
          u.write_at(3, row, string.format("  Q%d %s -> %s", qi,
            tostring(qitem.train_id or "?"):sub(1,8),
            tostring(qitem.destination or qitem.route_id or "?"):sub(1,10)), C.orange)
          row = row + 1
        end
      end

      -- Separator
      if row <= h - 2 and i < #sorted then
        u.fill_line(row, C.black, w)
        u.write_at(1, row, string.rep("-", w), C.gray)
        row = row + 1
      end
    end

    u.footer(h, string.format("Antippen zum Scrollen  %d/%d Depot", math.min(self.offset+1, #sorted), #sorted), w)
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

return depots_panel
