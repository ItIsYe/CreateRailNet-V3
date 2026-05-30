--[[
Purpose: Offline simulation tests for multi-train route conflicts.
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
    service_plans = {},
    nodes = {
      { id = "MASTER-1", role = "master" },
      { id = "TRAIN-1", role = "train", train_id = "TRAIN-1" },
      { id = "TRAIN-2", role = "train", train_id = "TRAIN-2" },
      { id = "ST-A", role = "station", station_type = "passenger", platforms = { { id = "P1", kind = "passenger", sensor_id = "SEN-A", block_id = "B1" } } },
      { id = "ST-B", role = "station", station_type = "passenger", platforms = { { id = "P1", kind = "passenger", sensor_id = "SEN-B" } } },
      { id = "SIG-IN", role = "signal", adapter = "redstone", side = "right" },
      { id = "SIG-OUT", role = "signal", adapter = "redstone", side = "left" },
      { id = "SEN-1", role = "sensor", adapter = "redstone", side = "front" }
    }
  }
end

return {
  test_second_train_waits_when_block_reserved = function()
    local sim = scenario_runner.new(cfg())
    local ok1 = sim.request_departure("TRAIN-1", { route_id = "R1", from = "ST-A", to = "ST-B" })
    local ok2 = sim.request_departure("TRAIN-2", { route_id = "R1", from = "ST-A", to = "ST-B" })
    assert(ok1)
    assert(not ok2)
    assert(sim.trains.get("TRAIN-1").state == "ROUTE_ASSIGNED")
    assert(sim.trains.get("TRAIN-2").state == "WAITING_FOR_ROUTE")
  end,

  test_queue_process_authorizes_after_release = function()
    local sim = scenario_runner.new(cfg())
    sim.request_departure("TRAIN-1", { route_id = "R1", from = "ST-A", to = "ST-B" })
    sim.request_departure("TRAIN-2", { route_id = "R1", from = "ST-A", to = "ST-B" })
    sim.dispatcher.release_route("TRAIN-1", "R1")
    local processed = sim.route_integration.process_queue()
    assert(#processed >= 1)
    assert(processed[1].ok)
  end
}
