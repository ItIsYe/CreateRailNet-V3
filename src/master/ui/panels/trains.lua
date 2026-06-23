--[[
Purpose: Master UI panel for train status.
Public API: new(train_registry) -> panel with draw(monitor), touch(x, y).
]]

local trains_panel = {}

local STATE_SYMBOLS = {
  OFFLINE = "~", REGISTERING = "?", QUEUED = "Q", WAITING_FOR_ROUTE = "W",
  ROUTE_ASSIGNED = "A", RUNNING = ">", ARRIVING = "v", ARRIVED = ".",
  FAULT = "!", MAINTENANCE = "M",
}

function trains_panel.new(train_registry)
  local self = { offset = 0 }

  function self.draw(monitor)
    if not monitor then return end
    local w, h = 51, 19
    if monitor.getSize then w, h = monitor.getSize() end
    monitor.clear()
    monitor.setCursorPos(1, 1)
    monitor.write("== TRAINS ==")

    local trains = train_registry and train_registry.list() or {}
    -- Sort by train_id for stable display
    local sorted = {}
    for id, t in pairs(trains) do table.insert(sorted, {id=id, t=t}) end
    table.sort(sorted, function(a, b) return a.id < b.id end)

    local row = 3
    local max_row = h - 1
    local start = self.offset + 1

    for i = start, #sorted do
      if row > max_row - 2 then break end
      local entry = sorted[i]
      local t = entry.t
      local sym = STATE_SYMBOLS[tostring(t.state)] or "?"
      monitor.setCursorPos(1, row)
      monitor.write(string.format("%s %-12s %-10s", sym, entry.id:sub(1,12), tostring(t.state or "?"):sub(1,10)))
      row = row + 1
      if row <= max_row then
        monitor.setCursorPos(3, row)
        local route = tostring(t.route_id or "-"):sub(1, math.floor(w/2)-4)
        local dest  = tostring(t.destination or t.create_destination or "-"):sub(1, math.floor(w/2)-4)
        monitor.write("R:" .. route .. "  D:" .. dest)
        row = row + 1
      end
    end

    -- Scroll indicator
    if #sorted > 0 then
      monitor.setCursorPos(1, h)
      monitor.write(string.format("Touch up/down to scroll  %d/%d", math.min(start, #sorted), #sorted))
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

return trains_panel
