--[[
Purpose: Master UI panel for onboard train nodes.
Public API: new(train_registry) -> panel with draw(monitor).
]]

local trains_panel = {}

function trains_panel.new(train_registry)
  local self = {}

  function self.draw(monitor)
    if not monitor then return end
    monitor.clear()
    monitor.setCursorPos(1, 1)
    monitor.write("CreateRailNet Trains")

    local row = 3
    local trains = train_registry and train_registry.list() or {}
    for train_id, train in pairs(trains) do
      monitor.setCursorPos(1, row)
      monitor.write(train_id .. " " .. tostring(train.state or "UNKNOWN"))
      row = row + 1
      monitor.setCursorPos(3, row)
      monitor.write("Route: " .. tostring(train.route_id or "-"))
      row = row + 1
      monitor.setCursorPos(3, row)
      monitor.write("Dest: " .. tostring(train.destination or "-"))
      row = row + 2
    end
  end

  return self
end

return trains_panel
