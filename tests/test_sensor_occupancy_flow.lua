--[[
Purpose: Sensor-driven station/depot occupancy flow tests.
Public API: returns table of tests.
]]

local runtime_factory = require("src.master.runtime")
local stations = require("src.domain.stations")
local depots = require("src.domain.depots")

local function fake_network()
  return {
    receive = function() return "ok" end,
    ack_for = function() end,
    send = function() end,
    tick = function() end
  }
end

local function fake_ui()
  return { mark_dirty = function() end, draw = function() end, handle_touch = function() end }
end

local function context_with_station_depot()
  local cfg = { nodes = {
    { id = "ST-A", role = "station", platforms = { { id = "P1", kind = "passenger" } } },
    { id = "DEPOT-1", role = "depot", tracks = { { id = "D1", kind = "storage" } } }
  } }
  return {
    config = cfg,
    station_registry = stations.new(cfg),
    depot_registry = depots.new(cfg),
    registry = { all = function() return {} end, register = function() end, heartbeat = function() end },
    dispatcher = { get_overview = function() return {} end, timeout_node = function() end },
    network = fake_network(),
    ui = fake_ui(),
    pull_event = function() return "terminate" end
  }
end

return {
  test_station_arrival_sets_dwelling_with_train_name = function()
    local ctx = context_with_station_depot()
    local rt = runtime_factory.new(ctx)
    rt.handle_event({ "modem_message", nil, nil, nil, { type = "event", src = "ST-A", payload = { type = "train_arrived_station", station_id = "ST-A", platform_id = "P1", train_id = "TRAIN-1", train_name = "Regio 1", route_id = "R1" } } })
    local platform = ctx.station_registry.get("ST-A").platforms.P1
    assert(platform.state == "DWELLING")
    assert(platform.train_id == "TRAIN-1")
    assert(platform.train_name == "Regio 1")
  end,

  test_station_left_releases_platform = function()
    local ctx = context_with_station_depot()
    ctx.station_registry.update_platform("ST-A", "P1", { state = "DWELLING", train_id = "TRAIN-1", train_name = "Regio 1" })
    local rt = runtime_factory.new(ctx)
    rt.handle_event({ "modem_message", nil, nil, nil, { type = "event", src = "ST-A", payload = { type = "train_left_station", station_id = "ST-A", platform_id = "P1", train_id = "TRAIN-1" } } })
    local platform = ctx.station_registry.get("ST-A").platforms.P1
    assert(platform.state == "EMPTY")
    assert(platform.train_id == nil)
  end,

  test_depot_arrival_sets_occupied_with_train_name = function()
    local ctx = context_with_station_depot()
    local rt = runtime_factory.new(ctx)
    rt.handle_event({ "modem_message", nil, nil, nil, { type = "event", src = "DEPOT-1", payload = { type = "depot_train_arrived", depot_id = "DEPOT-1", track_id = "D1", train_id = "TRAIN-1", train_name = "Regio 1", route_id = "R1" } } })
    local track = ctx.depot_registry.get("DEPOT-1").tracks.D1
    assert(track.state == "OCCUPIED")
    assert(track.train_name == "Regio 1")
  end,

  test_depot_left_releases_track = function()
    local ctx = context_with_station_depot()
    ctx.depot_registry.update_track("DEPOT-1", "D1", { state = "OCCUPIED", train_id = "TRAIN-1", train_name = "Regio 1" })
    local rt = runtime_factory.new(ctx)
    rt.handle_event({ "modem_message", nil, nil, nil, { type = "event", src = "DEPOT-1", payload = { type = "depot_train_left", depot_id = "DEPOT-1", track_id = "D1", train_id = "TRAIN-1" } } })
    local track = ctx.depot_registry.get("DEPOT-1").tracks.D1
    assert(track.state == "EMPTY")
    assert(track.train_id == nil)
  end
}
