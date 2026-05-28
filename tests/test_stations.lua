--[[
Purpose: Station registry and station node tests.
Public API: returns table of tests.
]]

local stations = require("src.domain.stations")
local station_node = require("src.nodes.station_node")

local function fake_monitor()
  return {
    lines = {},
    cursor = {1, 1},
    clear = function(self) self.lines = {} end,
    setCursorPos = function(self, x, y) self.cursor = {x, y} end,
    write = function(self, text) self.lines[self.cursor[2]] = text end
  }
end

return {
  test_station_registry_loads_multiple_platforms = function()
    local reg = stations.new({ nodes = {
      { id = "ST-A", role = "station", station_type = "mixed", platforms = {
        { id = "P1", kind = "passenger", sensor_id = "SEN-P1" },
        { id = "F1", kind = "freight", sensor_id = "SEN-F1" }
      } }
    } })
    local station = reg.get("ST-A")
    assert(station)
    assert(station.station_type == "mixed")
    assert(station.platforms.P1.kind == "passenger")
    assert(station.platforms.F1.kind == "freight")
  end,

  test_station_registry_updates_platform = function()
    local reg = stations.new({ nodes = {} })
    reg.update_platform("ST-B", "P2", { state = "READY_TO_DEPART", train_id = "TRAIN-1" })
    local station = reg.get("ST-B")
    assert(station.platforms.P2.state == "READY_TO_DEPART")
    assert(station.platforms.P2.train_id == "TRAIN-1")
  end,

  test_station_node_builds_platform_map = function()
    local platforms = station_node.build_platform_map({ station_type = "passenger", platforms = {
      { id = "A", sensor_id = "SEN-A", dwell_seconds = 5 }
    } })
    assert(platforms.A)
    assert(platforms.A.kind == "passenger")
    assert(platforms.A.sensor_id == "SEN-A")
    assert(platforms.A.dwell_seconds == 5)
  end,

  test_station_render_writes_monitor = function()
    local monitor = fake_monitor()
    station_node.render_status(monitor, {
      station_id = "ST-C",
      station_type = "freight",
      state = "ONLINE",
      platforms = { G1 = { id = "G1", kind = "freight", state = "EMPTY" } }
    })
    assert(monitor.lines[1] == "CreateRailNet Station")
    assert(string.find(monitor.lines[3], "ST-C"))
    assert(string.find(monitor.lines[4], "freight"))
  end
}
