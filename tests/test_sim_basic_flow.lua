--[[
Purpose: Offline simulation tests for normal train service flow.
Public API: returns table of tests.
]]

local scenario_runner = require("src.sim.scenario_runner")

local function cfg()
  return {
    v = 1,
    channel = 777,
    master_id = "MASTER-1",
    blocks = {
      { id = "B1", entry_signal = "SIG-IN", exit_signal = "SIG-OUT", sensors = { "SEN-1" }, switches = {} }
    },
    routes = {
      { id = "R1", from = "ST-A", to = "ST-B", blocks = { "B1" }, priority = 10, kind = "passenger" }
    },
    service_plans = {
      { id = "SP1", train_id = "TRAIN-1", stops = { { from = "ST-A", to = "ST-B", route_id = "R1", kind = "passenger", dwell_seconds = 1 } } }
    },
    nodes = {
      { id = "MASTER-1", role = "master" },
      { id = "TRAIN-1", role = "train", train_id = "TRAIN-1", service_plan = "SP1" },
      { id = "ST-A", role = "station", station_type = "passenger", platforms = { { id = "P1", kind = "passenger", sensor_id = "SEN-A", block_id = "B1" } } },
      { id = "ST-B", role = "station", station_type = "passenger", platforms = { { id = "P1", kind = "passenger", sensor_id = "SEN-B" } } },
      { id = "SIG-IN", role = "signal", adapter = "redstone", side = "right" },
      { id = "SIG-OUT", role = "signal", adapter = "redstone", side = "left" },
      { id = "SEN-1", role = "sensor", adapter = "redstone", side = "front" }
    }
  }
end

return {
  test_service_plan_sends_create_schedule = function()
    local sim = scenario_runner.new(cfg())
    local ok = sim.send_service_plan("TRAIN-1")
    assert(ok)
    local last = sim.network.last()
    assert(last.payload.cmd == "set_schedule")
    assert(last.payload.schedule.entries[1].instruction.id == "create:destination")
    assert(last.payload.schedule.entries[1].instruction.data.text == "ST-B")
  end,

  test_departure_reserves_route = function()
    local sim = scenario_runner.new(cfg())
    local ok = sim.request_departure("TRAIN-1", { route_id = "R1", from = "ST-A", to = "ST-B" })
    assert(ok)
    local train = sim.trains.get("TRAIN-1")
    assert(train.state == "ROUTE_ASSIGNED")
    assert(train.route_id == "R1")
    local overview = sim.dispatcher.get_overview()
    assert(overview.B1.state == "RESERVED")
  end,

  test_arrival_advances_service_plan_complete = function()
    local sim = scenario_runner.new(cfg())
    sim.request_departure("TRAIN-1", { route_id = "R1", from = "ST-A", to = "ST-B" })
    local ok = sim.arrive_station("TRAIN-1", "ST-B", "P1", "R1")
    assert(ok)
    local plan = sim.service_plans.for_train("TRAIN-1")
    assert(plan.state == "COMPLETE")
    local train = sim.trains.get("TRAIN-1")
    assert(train.state == "ARRIVED")
  end
}
