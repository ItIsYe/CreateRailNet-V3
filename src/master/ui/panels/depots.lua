--[[
Purpose: Master UI panel for depots and their tracks/staging slots.
Public API: new(depot_registry) -> panel with draw(monitor).
]]

local depots_panel = {}

function depots_panel.new(depot_registry)
  local self = {}

  function self.draw(monitor)
    if not monitor then return end
    monitor.clear()
    monitor.setCursorPos(1, 1)
    monitor.write("CreateRailNet Depots")

    local row = 3
    local depots = depot_registry and depot_registry.list() or {}
    for depot_id, depot in pairs(depots) do
      monitor.setCursorPos(1, row)
      monitor.write(depot_id .. " " .. tostring(depot.depot_type or "mixed") .. " " .. tostring(depot.state or "-"))
      row = row + 1
      for track_id, track in pairs(depot.tracks or {}) do
        monitor.setCursorPos(3, row)
        monitor.write(track_id .. " " .. tostring(track.kind or "mixed") .. " " .. tostring(track.state or "-"))
        row = row + 1
      end
      monitor.setCursorPos(3, row)
      monitor.write("Queue: " .. tostring(#(depot.queue or {})))
      row = row + 2
    end
  end

  return self
end

return depots_panel
