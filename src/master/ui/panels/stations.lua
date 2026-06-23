--[[
Purpose: Master UI panel for station and platform status.
Public API: new(station_registry) -> panel with draw(monitor), touch(x, y).
]]

local stations_panel = {}

local PLAT_SYMBOLS = { EMPTY = ".", DWELLING = "D", READY = "R", UNKNOWN = "?", FAULT = "!" }

function stations_panel.new(station_registry)
  local self = { offset = 0 }

  function self.draw(monitor)
    if not monitor then return end
    local w, h = 51, 19
    if monitor.getSize then w, h = monitor.getSize() end
    monitor.clear()
    monitor.setCursorPos(1, 1)
    monitor.write("== STATIONS ==")

    local stations = station_registry and station_registry.list() or {}
    local sorted = {}
    for id, s in pairs(stations) do table.insert(sorted, {id=id, s=s}) end
    table.sort(sorted, function(a, b) return a.id < b.id end)

    local row = 3
    local max_row = h - 1
    local start = self.offset + 1

    for i = start, #sorted do
      if row > max_row - 1 then break end
      local entry = sorted[i]
      local s = entry.s
      local st = tostring(s.state or "-")
      monitor.setCursorPos(1, row)
      monitor.write(string.format("%-14s %-8s", entry.id:sub(1,14), st:sub(1,8)))
      row = row + 1

      -- Platforms
      local plats = {}
      for pid, p in pairs(s.platforms or {}) do table.insert(plats, {id=pid, p=p}) end
      table.sort(plats, function(a, b) return a.id < b.id end)
      for _, pe in ipairs(plats) do
        if row > max_row - 1 then break end
        local sym = PLAT_SYMBOLS[tostring(pe.p.state)] or "?"
        local train = tostring(pe.p.train_id or ""):sub(1, 10)
        monitor.setCursorPos(3, row)
        monitor.write(string.format("%s %-6s %s %-10s", sym, pe.id:sub(1,6), tostring(pe.p.state or "?"):sub(1,8), train))
        row = row + 1
      end
    end

    if #sorted > 0 then
      monitor.setCursorPos(1, h)
      monitor.write(string.format("Touch to scroll  %d/%d stn", math.min(start, #sorted), #sorted))
    end
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

return stations_panel
