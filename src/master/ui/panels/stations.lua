--[[
Purpose: Master UI panel for stations and their platforms/tracks.
Public API: new(station_registry) -> panel with draw(monitor).
]]

local stations_panel = {}

function stations_panel.new(station_registry)
  local self = {}

  function self.draw(monitor)
    monitor.clear()
    monitor.setCursorPos(1, 1)
    monitor.write("CreateRailNet Stations")

    local row = 3
    local stations = station_registry and station_registry.list() or {}
    for station_id, station in pairs(stations) do
      monitor.setCursorPos(1, row)
      monitor.write(station_id .. " " .. tostring(station.station_type or "mixed") .. " " .. tostring(station.state or "-"))
      row = row + 1
      for platform_id, platform in pairs(station.platforms or {}) do
        monitor.setCursorPos(3, row)
        monitor.write(platform_id .. " " .. tostring(platform.kind or "mixed") .. " " .. tostring(platform.state or "-"))
        row = row + 1
      end
      row = row + 1
    end
  end

  return self
end

return stations_panel
