--[[
Purpose: Deterministic reproductions of dispatcher bugs that the random-walk property test found.
Public API: returns table of tests.
]]

pcall(dofile, "tests/harness/cc_bootstrap.lua")

local dispatcher = require("src.master.dispatcher")

-- The sensor guard rejects events older than 10 s of machine time, so test timestamps count from now.
local function ts(offset_ms)
  return math.floor(os.clock() * 1000) + offset_ms
end

local function cfg()
  return {
    sensor_guard_min_occupy_ms = 0,
    blocks = {
      { id = "B1", entry_signal = "SE1", exit_signal = "SX1", sensors = { "SEN-1" }, switches = {} },
      { id = "B2", entry_signal = "SE2", exit_signal = "SX2", sensors = { "SEN-2" }, switches = {} }
    },
    routes = {
      { id = "R-12", from = "A", to = "B", blocks = { "B1", "B2" } },
      { id = "R-1", from = "C", to = "D", blocks = { "B1" } },
      { id = "R-2", from = "E", to = "F", blocks = { "B2" } }
    }
  }
end

local function corridor_cfg()
  return {
    sensor_guard_min_occupy_ms = 0,
    blocks = {
      { id = "B1", entry_signal = "SE1", exit_signal = "SX1", sensors = { "SEN-1" }, switches = {} },
      { id = "B2", entry_signal = "SE2", exit_signal = "SX2", sensors = { "SEN-2" }, switches = {} },
      { id = "B3", entry_signal = "SE3", exit_signal = "SX3", sensors = { "SEN-3" }, switches = {} }
    },
    routes = {
      { id = "R-AC-1", from = "A", to = "C", blocks = { "B1" } },
      { id = "R-AC-2", from = "A", to = "C", blocks = { "B2" } },
      { id = "R-CA", from = "C", to = "A", blocks = { "B3" } }
    }
  }
end

local function world()
  local aspects = {}
  local adapters = {
    signals = { setAspect = function(id, aspect) aspects[id] = aspect; return true end },
    switches = { setPosition = function() return true end }
  }
  return dispatcher.new(cfg(), adapters), aspects
end

return {
  -- found by seed 1 of test_dispatcher_property: T2 finished, T3 took B1, then release_route(T2) freed B1 under T3
  test_release_route_keeps_blocks_that_now_belong_to_another_train = function()
    local d = world()
    assert(d.reserve_route("T1", "R-1"))
    assert(d.on_sensor_event_by_sensor("SEN-1", "enter", ts(1000)))
    assert(d.on_sensor_event_by_sensor("SEN-1", "leave", ts(3000)))
    assert(d.reserve_route("T2", "R-1"))
    assert(d.release_route("T1", "R-1"))
    local block = d.get_block("B1")
    assert(block.state == dispatcher.STATES.RESERVED and block.reserved_by == "T2", "B1 must stay reserved for T2")
  end,

  test_release_route_cancels_blocks_the_train_still_holds = function()
    local d, aspects = world()
    assert(d.reserve_route("T1", "R-12"))
    assert(d.release_route("T1", "R-12"))
    assert(d.get_block("B1").state == dispatcher.STATES.FREE and d.get_block("B2").state == dispatcher.STATES.FREE)
    assert(aspects.SE1 == "RED" and aspects.SE2 == "RED")
  end,

  -- found by seed 19 of test_dispatcher_property: the second same-direction train overwrote the shared opp: group,
  -- so it vanished when that train finished although the first one was still on the corridor
  test_opposite_direction_stays_blocked_while_any_same_direction_train_is_active = function()
    local aspects = {}
    local d = dispatcher.new(corridor_cfg(), {
      signals = { setAspect = function(id, aspect) aspects[id] = aspect; return true end },
      switches = { setPosition = function() return true end }
    })
    assert(d.reserve_route("T1", "R-AC-1"))
    assert(d.reserve_route("T2", "R-AC-2"))
    assert(d.on_sensor_event_by_sensor("SEN-2", "enter", ts(1000)))
    assert(d.on_sensor_event_by_sensor("SEN-2", "leave", ts(3000)))
    local ok, status = d.request_route("T3", "R-CA")
    assert(ok == false and status == "queued", "T1 is still running A->C, C->A must wait")
    assert(d.on_sensor_event_by_sensor("SEN-1", "enter", ts(5000)))
    assert(d.on_sensor_event_by_sensor("SEN-1", "leave", ts(7000)))
    assert(d.get_trains().T3.state == dispatcher.TRAIN_STATES.RESERVED, "after the last A->C train is done the queue admits T3")
  end,

  -- found by seed 1001 of test_dispatcher_chaos: a second request replaced the train record and leaked the old blocks
  test_new_request_of_a_train_that_has_not_entered_replaces_its_old_route = function()
    local d = world()
    assert(d.reserve_route("T1", "R-1"))
    assert(d.reserve_route("T1", "R-2"))
    assert(d.get_block("B1").state == dispatcher.STATES.FREE, "old route must be cancelled, not leaked")
    assert(d.get_block("B2").reserved_by == "T1")
    assert(d.get_conflicts()["block:B1"] == nil)
    assert(d.get_trains().T1.route == "R-2")
  end,

  test_repeating_the_granted_route_is_idempotent = function()
    local d = world()
    assert(d.reserve_route("T1", "R-1"))
    local ok, status = d.request_route("T1", "R-1")
    assert(ok == true and status == "reserved")
    assert(d.get_block("B1").reserved_by == "T1" and #d.get_queue() == 0)
  end,

  test_running_train_keeps_its_route_and_the_second_request_waits = function()
    local d = world()
    assert(d.reserve_route("T1", "R-12"))
    assert(d.on_sensor_event_by_sensor("SEN-1", "enter", ts(1000)))
    local ok, status = d.request_route("T1", "R-2")
    assert(ok == false and status == "queued")
    local t1 = d.get_trains().T1
    assert(t1.state == dispatcher.TRAIN_STATES.RUNNING and t1.route == "R-12", "the running record must not be overwritten")
    assert(d.get_block("B1").state == dispatcher.STATES.OCCUPIED and d.get_block("B1").occupied_by == "T1")
    assert(d.on_sensor_event_by_sensor("SEN-1", "leave", ts(3000)))
    assert(d.on_sensor_event_by_sensor("SEN-2", "enter", ts(4000)))
    assert(d.on_sensor_event_by_sensor("SEN-2", "leave", ts(6000)))
    assert(d.get_trains().T1.route == "R-2" and d.get_trains().T1.state == dispatcher.TRAIN_STATES.RESERVED, "the waiting request is granted after the first route")
  end,

  test_identical_waiting_requests_are_queued_once = function()
    local d = world()
    assert(d.reserve_route("T1", "R-1"))
    d.request_route("T2", "R-1")
    d.request_route("T2", "R-1")
    assert(#d.get_queue() == 1)
  end,

  -- a sensor that never reports a block must not leave it reserved after the train arrived
  test_arrival_releases_blocks_whose_sensor_events_were_missed = function()
    local d = world()
    assert(d.reserve_route("T1", "R-12"))
    assert(d.on_sensor_event_by_sensor("SEN-2", "enter", ts(1000)))
    assert(d.on_sensor_event_by_sensor("SEN-2", "leave", ts(3000)))
    assert(d.get_trains().T1.state == dispatcher.TRAIN_STATES.ARRIVED)
    assert(d.get_block("B1").state == dispatcher.STATES.FREE, "B1 was never reported but the train is gone")
  end,

  -- found by seed 1001 of test_dispatcher_chaos: a timed-out train kept its queued request and got a route later
  test_timed_out_train_loses_its_queued_request = function()
    local d = world()
    assert(d.reserve_route("T1", "R-1"))
    d.request_route("T2", "R-1")
    assert(#d.get_queue() == 1)
    d.timeout_node("T2")
    assert(#d.get_queue() == 0, "an offline train must not receive a route")
    assert(d.get_trains().T2.state == dispatcher.TRAIN_STATES.FAULT)
    assert(d.on_sensor_event_by_sensor("SEN-1", "enter", ts(1000)))
    assert(d.on_sensor_event_by_sensor("SEN-1", "leave", ts(3000)))
    assert(d.get_block("B1").state == dispatcher.STATES.FREE, "B1 must not be reserved for the dead train")
  end,

  -- a timed-out train keeps its blocks reserved (it may still stand on them) but must not keep a proceed signal
  test_timed_out_train_gets_red_on_the_blocks_it_holds = function()
    local d, aspects = world()
    assert(d.reserve_route("T1", "R-1"))
    assert(aspects.SE1 == "GREEN")
    d.timeout_node("T1")
    assert(aspects.SE1 == "RED")
    assert(d.get_block("B1").reserved_by == "T1", "the block stays blocked for everybody else")
  end,

  -- found by seed 1004 of test_dispatcher_chaos: restore() re-ran the signal logic for a FAULT train and showed GREEN
  test_restore_does_not_give_a_faulted_train_a_proceed_signal = function()
    local d, aspects = world()
    assert(d.reserve_route("T1", "R-1"))
    d.timeout_node("T1")
    assert(d.restore(d.snapshot()))
    assert(aspects.SE1 == "RED", "restore must keep RED for a train in FAULT, got " .. tostring(aspects.SE1))
  end,

  -- found by seed 1004 of test_dispatcher_chaos: after a timeout the train asked for a new route, its old blocks leaked
  test_train_that_comes_back_after_a_timeout_releases_its_old_blocks_with_the_new_request = function()
    local d = world()
    assert(d.reserve_route("T1", "R-1"))
    d.timeout_node("T1")
    assert(d.get_block("B1").reserved_by == "T1")
    assert(d.reserve_route("T1", "R-2"))
    assert(d.get_block("B1").state == dispatcher.STATES.FREE, "old blocks must not stay reserved for a train that moved on")
    assert(d.get_block("B2").reserved_by == "T1")
  end,

  test_fault_blocks_stay_fault_when_their_train_moves_on = function()
    local d = world()
    assert(d.reserve_route("T1", "R-1"))
    d.get_block("B1").state = dispatcher.STATES.FAULT
    d.timeout_node("T1")
    assert(d.reserve_route("T1", "R-2"))
    assert(d.get_block("B1").state == dispatcher.STATES.FAULT, "a faulted block needs a repair, not a new request")
  end,

  -- found by seed 1003 of test_dispatcher_chaos: restore() reset the signal of a block that belonged to another train
  -- because a queued train's stub record still listed that block (outcome depended on pairs() order)
  test_restore_keeps_the_signal_of_a_waiting_train_when_another_train_queues_for_its_block = function()
    for _ = 1, 5 do
      local d, aspects = world()
      assert(d.reserve_route("T1", "R-1"))
      d.request_route("T2", "R-1")
      assert(d.restore(d.snapshot()))
      assert(aspects.SE1 == "GREEN", "T1 still waits on B1, got " .. tostring(aspects.SE1))
    end
  end,

  -- found by seed 1039 of test_dispatcher_chaos: a FAULT block still carrying the train's name was re-reserved by it
  test_faulted_block_is_not_reserved_again_by_the_train_that_held_it = function()
    local d = world()
    assert(d.reserve_route("T1", "R-12"))
    local ok = d.on_sensor_event_by_sensor("SEN-2", "leave", ts(1000))
    assert(ok == false, "leave on a block nobody occupies is a sensor fault")
    assert(d.get_block("B2").state == dispatcher.STATES.FAULT)
    local granted = d.request_route("T1", "R-2")
    assert(granted == false, "R-2 needs the faulted block")
    assert(d.get_block("B2").state == dispatcher.STATES.FAULT, "the fault must survive the new request")
  end,

  -- found by seed 1044 of test_dispatcher_chaos: an older queued request cancelled the route the train had been given since
  test_old_queued_request_does_not_cancel_the_route_the_train_got_in_the_meantime = function()
    local d = world()
    assert(d.reserve_route("T2", "R-1"))
    local queued = d.request_route("T1", "R-1")
    assert(queued == false)
    assert(d.reserve_route("T1", "R-2"), "T1 asks again and gets another route right away")
    assert(d.on_sensor_event_by_sensor("SEN-1", "enter", ts(1000)))
    assert(d.on_sensor_event_by_sensor("SEN-1", "leave", ts(3000)))
    local t1 = d.get_trains().T1
    assert(t1.route == "R-2" and t1.state == dispatcher.TRAIN_STATES.RESERVED, "T1 keeps R-2, got " .. tostring(t1.route) .. "/" .. tostring(t1.state))
    assert(d.get_block("B2").reserved_by == "T1" and d.get_block("B1").state == dispatcher.STATES.FREE)
  end,

  -- found by seed 62 of the wide chaos hunt: a node timeout dropped the corridor lock of a train that may still be running
  test_timed_out_train_keeps_its_corridor_locked_until_it_is_seen_again = function()
    local d = dispatcher.new(corridor_cfg(), {
      signals = { setAspect = function() return true end },
      switches = { setPosition = function() return true end }
    })
    assert(d.reserve_route("T1", "R-AC-1"))
    d.timeout_node("T1")
    local ok, status = d.request_route("T3", "R-CA")
    assert(ok == false and status == "queued", "T1 may still be on the corridor, C->A has to wait")
    assert(d.on_sensor_event_by_sensor("SEN-1", "enter", ts(1000)), "the sensor sees T1 again")
    assert(d.get_trains().T1.state == dispatcher.TRAIN_STATES.RUNNING)
    assert(d.get_conflicts()["opp:A<->C"], "and the corridor is still claimed")
    assert(d.on_sensor_event_by_sensor("SEN-1", "leave", ts(3000)))
    assert(d.get_trains().T3.state == dispatcher.TRAIN_STATES.RESERVED, "once T1 is through, T3 gets the corridor")
  end,

  test_train_that_asks_again_after_a_timeout_gives_up_its_old_locks = function()
    local d = dispatcher.new(corridor_cfg(), {
      signals = { setAspect = function() return true end },
      switches = { setPosition = function() return true end }
    })
    assert(d.reserve_route("T1", "R-AC-1"))
    d.timeout_node("T1")
    assert(d.reserve_route("T1", "R-CA"))
    assert(d.get_conflicts()["block:B1"] == nil and d.get_conflicts()["block:B3"])
  end,

  -- a train longer than a block occupies two blocks at once; leaving the first must not finish the route
  test_leaving_an_earlier_block_does_not_advance_a_train_that_is_still_in_the_next_one = function()
    local d = world()
    assert(d.reserve_route("T1", "R-12"))
    assert(d.on_sensor_event_by_sensor("SEN-1", "enter", ts(1000)))
    assert(d.on_sensor_event_by_sensor("SEN-2", "enter", ts(2000)))
    assert(d.on_sensor_event_by_sensor("SEN-1", "leave", ts(3000)))
    local t1 = d.get_trains().T1
    assert(t1.state == dispatcher.TRAIN_STATES.RUNNING and t1.current_block == "B2", "T1 is still in B2, got " .. tostring(t1.state))
    assert(d.get_block("B2").occupied_by == "T1")
    assert(d.on_sensor_event_by_sensor("SEN-2", "leave", ts(5000)))
    assert(d.get_trains().T1.state == dispatcher.TRAIN_STATES.ARRIVED)
    assert(d.get_block("B1").state == dispatcher.STATES.FREE and d.get_block("B2").state == dispatcher.STATES.FREE)
  end,

  -- found by seed 258 of the wide chaos hunt: sensor events out of order made the index point at a block already given up
  test_out_of_order_enter_events_do_not_move_the_train_backwards = function()
    local d = world()
    assert(d.reserve_route("T1", "R-12"))
    assert(d.on_sensor_event_by_sensor("SEN-2", "enter", ts(1000)))
    assert(d.on_sensor_event_by_sensor("SEN-1", "enter", ts(2000)))
    local t1 = d.get_trains().T1
    assert(t1.current_block == "B2" and t1.route_index == 2, "the furthest block wins, got " .. tostring(t1.current_block))
    assert(d.on_sensor_event_by_sensor("SEN-2", "leave", ts(4000)))
    assert(d.get_trains().T1.state == dispatcher.TRAIN_STATES.ARRIVED)
    assert(d.get_block("B1").state == dispatcher.STATES.FREE, "the late block is released with the arrival")
  end,

  -- there was no way to repair a FAULT block short of editing the state file; every node timeout left some behind
  test_operator_can_clear_a_fault_block_nobody_is_using = function()
    local d, aspects = world()
    assert(d.on_sensor_event_by_sensor("SEN-1", "leave", ts(1000)) == false)
    assert(d.get_block("B1").state == dispatcher.STATES.FAULT)
    assert(d.reserve_route("T1", "R-1") == false, "a FAULT block cannot be reserved")
    assert(d.clear_fault("B1"))
    assert(d.get_block("B1").state == dispatcher.STATES.FREE and aspects.SE1 == "RED")
    assert(d.clear_fault("B1") == false, "only FAULT blocks can be cleared")
    assert(d.clear_fault("nope") == false)
  end,

  test_clear_fault_refuses_a_block_of_a_train_that_is_on_its_way = function()
    local d = world()
    assert(d.reserve_route("T1", "R-12"))
    d.get_block("B2").state = dispatcher.STATES.FAULT
    local ok, err = d.clear_fault("B2")
    assert(ok == false and tostring(err):find("T1"))
    assert(d.release_route("T1", "R-12"))
    assert(d.get_block("B2").state == dispatcher.STATES.FAULT, "releasing the train leaves the fault for the operator")
    assert(d.clear_fault("B2"))
  end,

  test_clear_fault_frees_a_block_still_held_by_a_timed_out_train = function()
    local d = world()
    assert(d.reserve_route("T1", "R-1"))
    d.get_block("B1").state = dispatcher.STATES.FAULT
    d.timeout_node("T1")
    assert(d.clear_fault("B1"))
    assert(d.get_block("B1").reserved_by == nil and d.get_block("B1").state == dispatcher.STATES.FREE)
  end
}
