--[[
Purpose: Master UI panel for depot and track status.
Public API: new(depot_registry) -> panel with draw(monitor), touch(x, y).
]]

local depots_panel = {}

local TRACK_SYMBOLS = { EMPTY = ".", READY = "R", OCCUPIED = "O", UNKNOWN = "?", FAULT = "!" }

function depots_panel.new(depot_registry)
  local self = { offset = 0 }

  function self.draw(monitor)
    if not monitor then return end
    local w, h = 51, 19
    if monitor.getSize then w, h = monitor.getSize() end
    monitor.clear()
    monitor.setCursorPos(1, 1)
    monitor.write("== DEPOTS ==")

    local depots = depot_registry and depot_registry.list() or {}
    local sorted = {}
    for id, d in pairs(depots) do table.insert(sorted, {id=id, d=d}) end
    table.sort(sorted, function(a, b) return a.id < b.id end)

    local row = 3
    local max_row = h - 1
    local start = self.offset + 1

    for i = start, #sorted do
      if row > max_row - 1 then break end
      local entry = sorted[i]
      local d = entry.d
      local qlen = #(d.queue or {})
      monitor.setCursorPos(1, row)
      monitor.write(string.format("%-14s %-8s Q:%d", entry.id:sub(1,14), tostring(d.state or "-"):sub(1,8), qlen))
      row = row + 1

      -- Tracks
      local tracks = {}
      for tid, t in pairs(d.tracks or {}) do table.insert(tracks, {id=tid, t=t}) end
      table.sort(tracks, function(a, b) return a.id < b.id end)
      for _, te in ipairs(tracks) do
        if row > max_row - 1 then break end
        local sym = TRACK_SYMBOLS[tostring(te.t.state)] or "?"
        local train = tostring(te.t.train_id or ""):sub(1, 10)
        monitor.setCursorPos(3, row)
        monitor.write(string.format("%s %-6s %s %-10s", sym, te.id:sub(1,6), tostring(te.t.state or "?"):sub(1,8), train))
        row = row + 1
      end
    end

    if #sorted > 0 then
      monitor.setCursorPos(1, h)
      monitor.write(string.format("Touch to scroll  %d/%d depot", math.min(start, #sorted), #sorted))
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

return depots_panel
