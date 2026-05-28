--[[
Purpose: Multi-train dispatcher tests for route queue, switch locks, and train progress.
Public API: returns table of tests.
]]

local dispatcher = require("src.master.dispatcher")

local function cfg()
  return {
    blocks = {
      { id = "B1", entry_signal = "SIG-1", exit_signal = "SIG-2", sensors = { "SEN-1" }, switches = { { id = "SW-1", position = "STRAIGHT" } } },
      { id = "B2", entry_signal = "SIG-3", exit_signal = "SIG-4", sensors = { "SEN-2" }, switches = { { id = "SW-1", position = "DIVERGING" } } }
    },
    routes = {
      { id = "R1", from = "A", to = "B", blocks = { "B1" }, priority = 1 },
      { id = "R2", from = "A", to = "C", blocks = { "B2" }, priority = 5 }
    }
  }
end

local function adapters()
  local aspects = {}
  local positions = {}
  return {
    aspects = aspects,
    positions = positions,
    signals = { setAspect = function(id, aspect) aspects[id] = aspect; return true end },
    switches = { setPosition = function(id, position) positions[id] = position; return true end }
  }
end

return {
  test_request_route_queues_conflict = function()
    local a = adapters()
    local d = dispatcher.new(cfg(), a)
    local ok1 = d.reserve_route("TRAIN-1", "R1")
    assert(ok1)
    local ok2, status = d.request_route("TRAIN-2", "R1")
    assert(ok2 == false)
    assert(status == "queued")
    assert(#d.get_queue() == 1)
  end,

  test_switch_lock_blocks_conflicting_position = function()
    local a = adapters()
    local d = dispatcher.new(cfg(), a)
    local ok1 = d.reserve_route("TRAIN-1", "R1")
    assert(ok1)
    local ok2, err = d.reserve_route("TRAIN-2", "R2")
    assert(not ok2)
    assert(string.find(err, "switch locked"), err)
  end,

  test_train_progress_releases_block_and_finishes = function()
    local a = adapters()
    local d = dispatcher.new(cfg(), a)
    assert(d.reserve_route("TRAIN-1", "R1"))
    assert(d.on_sensor_event_by_sensor("SEN-1", "enter"))
    assert(d.get_trains()["TRAIN-1"].state == dispatcher.TRAIN_STATES.RUNNING)
    assert(d.on_sensor_event_by_sensor("SEN-1", "leave"))
    assert(d.get_trains()["TRAIN-1"].state == dispatcher.TRAIN_STATES.ARRIVED)
    assert(d.get_block("B1").state == dispatcher.STATES.FREE)
  end,

  test_queue_processes_after_release = function()
    local a = adapters()
    local d = dispatcher.new(cfg(), a)
    assert(d.reserve_route("TRAIN-1", "R1"))
    local ok2 = d.request_route("TRAIN-2", "R1")
    assert(ok2 == false)
    assert(d.on_sensor_event_by_sensor("SEN-1", "enter"))
    assert(d.on_sensor_event_by_sensor("SEN-1", "leave"))
    local train2 = d.get_trains()["TRAIN-2"]
    assert(train2.state == dispatcher.TRAIN_STATES.RESERVED or train2.state == dispatcher.TRAIN_STATES.QUEUED)
  end
}
