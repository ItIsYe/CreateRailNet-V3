--[[
Purpose: Station registry and station node tests.
Public API: returns table of tests.
]]

local stations = require("src.domain.stations")
local station_node = require("src.nodes.station_node")

local function fake_monitor()
  local m = { lines = {}, cursor = {1, 1} }
  function m.clear() m.lines = {} end
  function m.setCursorPos(x, y) m.cursor = {x, y} end
  function m.write(text) m.lines[m.cursor[2]] = text end
  return m
end

local function contains_line(lines, text)
  for _, line in pairs(lines or {}) do
    if string.find(tostring(line), text, 1, true) then return true end
  end
  return false
end

return {
  test_station_registry_loads_multiple_platforms = function()
    local reg = stations.new({ nodes = { { id = "ST-A", role = "station", station_type = "mixed", platforms = { { id = "P1", kind = "passenger", sensor_id = "SEN-P1" }, { id = "F1", kind = "freight", sensor_id = "SEN-F1" } } } } })
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

  test_station_finds_matching_free_platform = function()
    local reg = stations.new({ nodes = { { id = "ST-A", role = "station", station_type = "mixed", platforms = { { id = "P1", kind = "passenger" }, { id = "F1", kind = "freight" } } } } })
    local platform = reg.find_available_platform("ST-A", { kind = "freight" })
    assert(platform.id == "F1")
  end,

  test_station_reserve_and_release_platform = function()
    local reg = stations.new({ nodes = { { id = "ST-A", role = "station", platforms = { { id = "P1", kind = "passenger" } } } } })
    local platform = reg.reserve_platform("ST-A", { train_id = "TRAIN-1", route_id = "R1", kind = "passenger" })
    assert(platform.state == "RESERVED")
    assert(platform.train_id == "TRAIN-1")
    local ok = reg.release_platform("ST-A", "P1")
    assert(ok)
    assert(reg.get("ST-A").platforms.P1.state == "EMPTY")
  end,

  test_station_rejects_occupied_platform = function()
    local reg = stations.new({ nodes = { { id = "ST-A", role = "station", platforms = { { id = "P1", kind = "passenger", state = "OCCUPIED" } } } } })
    local platform, err = reg.find_available_platform("ST-A", { kind = "passenger" })
    assert(platform == nil)
    assert(err == "no available platform")
  end,

  test_station_node_builds_platform_map = function()
    local platforms = station_node.build_platform_map({ station_type = "passenger", platforms = { { id = "A", sensor_id = "SEN-A", dwell_seconds = 5 } } })
    assert(platforms.A)
    assert(platforms.A.kind == "passenger")
    assert(platforms.A.sensor_id == "SEN-A")
    assert(platforms.A.dwell_seconds == 5)
  end,

  test_station_render_writes_monitor = function()
    local monitor = fake_monitor()
    station_node.render_status(monitor, { station_id = "ST-C", station_type = "freight", state = "ONLINE", platforms = { G1 = { id = "G1", kind = "freight", state = "EMPTY" } } })
    assert(monitor.lines[1] == "CreateRailNet Station")
    assert(contains_line(monitor.lines, "ST-C"))
    assert(contains_line(monitor.lines, "freight"))
  end
}
