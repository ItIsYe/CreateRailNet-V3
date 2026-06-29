--[[
Purpose: Multi-train dispatcher tests for route queue, switch locks, direction conflicts, and train progress.
Public API: returns table of tests.
]]

local dispatcher = require("src.master.dispatcher")

local function cfg()
  return {
    sensor_guard_min_occupy_ms = 0,
    blocks = {
      { id = "B1", entry_signal = "SIG-1", exit_signal = "SIG-2", sensors = { "SEN-1" }, switches = { { id = "SW-1", position = "STRAIGHT" } } },
      { id = "B2", entry_signal = "SIG-3", exit_signal = "SIG-4", sensors = { "SEN-2" }, switches = { { id = "SW-1", position = "DIVERGING" } } },
      { id = "B3", entry_signal = "SIG-5", exit_signal = "SIG-6", sensors = { "SEN-3" }, switches = {} }
    },
    routes = {
      { id = "R1", from = "A", to = "B", blocks = { "B1" }, priority = 1 },
      { id = "R2", from = "A", to = "C", blocks = { "B2" }, priority = 5 },
      { id = "R-AB", from = "ST-A", to = "ST-B", blocks = { "B3" }, priority = 10 },
      { id = "R-BA", from = "ST-B", to = "ST-A", blocks = { "B3" }, priority = 10 }
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
    assert(string.find(err, "switch locked") or string.find(err, "conflict group"), err)
  end,

  test_opposite_direction_route_is_queued_with_diagnostic = function()
    local a = adapters()
    local d = dispatcher.new(cfg(), a)
    assert(d.reserve_route("TRAIN-1", "R-AB"))
    local ok2, status = d.request_route("TRAIN-2", "R-BA")
    assert(ok2 == false)
    assert(status == "queued")
    local queued = d.get_queue()[1]
    assert(queued.route_id == "R-BA")
    assert(queued.direction == "ST-B->ST-A")
    assert(queued.conflict_group == "opp:ST-A<->ST-B" or queued.conflict_group == "block:B3")
    assert(string.find(queued.reason, "conflict") or string.find(queued.reason, "block not free"), queued.reason)
  end,

  test_conflict_groups_release_after_train_finishes = function()
    local a = adapters()
    local d = dispatcher.new(cfg(), a)
    assert(d.reserve_route("TRAIN-1", "R-AB"))
    assert(d.get_conflicts()["opp:ST-A<->ST-B"])
    assert(d.on_sensor_event_by_sensor("SEN-3", "enter"))
    assert(d.on_sensor_event_by_sensor("SEN-3", "leave"))
    assert(d.get_conflicts()["opp:ST-A<->ST-B"] == nil)
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
