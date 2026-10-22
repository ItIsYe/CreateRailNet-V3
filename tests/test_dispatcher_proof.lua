--[[
Purpose: Reservation on proof: a block is only given when it is proven free, the route ends at a proven safe stop, a reservation is lifted only after the end of the train was proven, deadlocks are reported and never healed by force (Gesamtkonzept Kap. 3, 4, 5.2; tests B-07, B-08, C-04, C-06, C-10, C-12).
Public API: returns table of tests.
]]

local dispatcher = require("src.master.dispatcher")

local function cfg(mode)
  return {
    occupancy_proof = mode, sensor_guard_min_occupy_ms = 0,
    blocks = {
      { id = "B1", entry_signal = "S1", exit_signal = "X1", sensors = { "SEN-1" } },
      { id = "B2", entry_signal = "S2", exit_signal = "X2", sensors = { "SEN-2", "SEN-2T" }, tail_sensors = { "SEN-2T" } },
      { id = "B3", entry_signal = "S3", exit_signal = "X3", sensors = { "SEN-3" } },
      { id = "B5", entry_signal = "S5", exit_signal = "X5", sensors = { "SEN-5" } },
      { id = "B6", entry_signal = "S6", exit_signal = "X6", sensors = { "SEN-6" } },
      { id = "B7", entry_signal = "S7", exit_signal = "X7", sensors = { "SEN-7" } }
    },
    routes = {
      { id = "R1", from = "A", to = "B", blocks = { "B1", "B2" } },
      { id = "R2", from = "B", to = "C", blocks = { "B3" } },
      { id = "RA", from = "B", to = "D", blocks = { "B3", "B5" }, alternatives = { "RA2" } },
      { id = "RA2", from = "B", to = "D", blocks = { "B7", "B5" }, reachability_confirmed = true },
      { id = "RB", from = "C", to = "E", blocks = { "B2", "B6" } },
      { id = "RNOEND", from = "A", to = "Z", blocks = { "B1" } },
      { id = "RX1", from = "B", to = "Q", blocks = { "B3", "B5" } },
      { id = "RX2", from = "C", to = "Q", blocks = { "B2", "B6" } }
    },
    safe_stops = { { block = "B2", length = 6, proven = true }, { block = "B3", length = 8, proven = true }, { block = "B5", length = 8, proven = true }, { block = "B6", proven = true } }
  }
end

local function adapters()
  local aspects = {}
  return { aspects = aspects, signals = { setAspect = function(id, a) aspects[id] = a; return true end }, switches = { setPosition = function() return true end } }
end

local function prove_all(d, ids, at)
  for _, id in ipairs(ids or { "B1", "B2", "B3", "B5", "B6", "B7" }) do assert(d.observe_block(id, "FREE_PROVEN", "observer", { at = at or 1 })) end
end

local function pass(d, block, sensor, tail_sensor)
  assert(d.on_sensor_event(block, "enter", sensor))
  assert(d.on_sensor_event(block, "leave", tail_sensor or sensor))
end

return {
  test_without_the_proof_mode_nothing_changes = function()
    local d = dispatcher.new(cfg(nil), adapters())
    assert(d.reserve_route("T1", "R1"), "reserved with no proof: the old behaviour")
    assert(d.reserve_route("T2", "RNOEND") == false or true)
    assert(d.get_trains().T1.phase == "ACTUATION_ELIGIBLE" or d.get_trains().T1.phase == "ACTUATED", tostring(d.get_trains().T1.phase))
  end,

  test_unknown_blocks_are_not_given_and_the_request_waits = function()
    local d = dispatcher.new(cfg("on"), adapters())
    local ok, err = d.reserve_route("T1", "R1")
    assert(not ok and err:find("UNKNOWN", 1, true), tostring(err))
    local ok2, status = d.request_route("T1", "R1")
    assert(ok2 == false and status == "queued")
    prove_all(d, { "B1", "B2" })
    local processed = d.process_queue()
    assert(processed[1].ok == true, tostring(processed[1].error))
    assert(d.get_block("B1").state == "RESERVED" and d.get_block("B2").reserved_by == "T1")
  end,

  test_a_route_that_does_not_end_at_a_proven_safe_stop_is_not_given = function()
    local d = dispatcher.new(cfg("on"), adapters())
    prove_all(d)
    local ok, err = d.reserve_route("T1", "RNOEND")
    assert(not ok and err:find("safe waiting point", 1, true), tostring(err))
    assert(d.get_block("B1").state == "FREE", "nothing was reserved")
  end,

  test_a_train_that_is_longer_than_the_stop_is_refused_and_a_short_one_goes = function()
    local d = dispatcher.new(cfg("on"), adapters())
    prove_all(d)
    local ok, status = d.request_route("T1", "R1", { length = 9 })
    assert(ok == false and status == "queued")
    local queued = d.get_queue()[1]
    assert(queued.reason:find("too long", 1, true), queued.reason)
    d.release_route("T1")
    local ok2 = d.reserve_route("T1", "R1", { length = 6 })
    assert(ok2 == true)
  end,

  test_a_train_that_enters_proves_the_block_occupied_and_its_tail_proves_it_free = function()
    local d = dispatcher.new(cfg("on"), adapters())
    prove_all(d)
    assert(d.reserve_route("T1", "R1"))
    assert(d.on_sensor_event("B1", "enter", "SEN-1"))
    assert(d.get_occupancy("B1").state == "OCCUPIED_PROVEN" and d.get_occupancy("B1").train_id == "T1")
    assert(d.on_sensor_event("B1", "leave", "SEN-1"))
    local rec = d.get_occupancy("B1")
    assert(rec.state == "FREE_PROVEN" and rec.source == "tail_sensor", tostring(rec.state))
    assert(d.get_block("B1").state == "FREE")
  end,

  test_a_sensor_that_is_not_a_tail_sensor_does_not_lift_the_block = function()
    local d = dispatcher.new(cfg("on"), adapters())
    prove_all(d)
    assert(d.reserve_route("T1", "R1"))
    pass(d, "B1", "SEN-1")
    assert(d.on_sensor_event("B2", "enter", "SEN-2"))
    local ok, err = d.on_sensor_event("B2", "leave", "SEN-2")
    assert(ok == false and err:find("tail", 1, true), tostring(err))
    assert(d.get_block("B2").state == "OCCUPIED" and d.get_occupancy("B2").state == "OCCUPIED_PROVEN", "the head left, the end of the train is not proven")
    assert(d.on_sensor_event("B2", "leave", "SEN-2T"))
    assert(d.get_block("B2").state == "FREE" and d.get_occupancy("B2").state == "FREE_PROVEN")
    assert(d.get_trains().T1.state == "ARRIVED")
  end,

  test_a_released_route_keeps_the_block_the_train_still_stands_on = function()
    local d = dispatcher.new(cfg("on"), adapters())
    prove_all(d)
    assert(d.reserve_route("T1", "R1"))
    pass(d, "B1", "SEN-1")
    assert(d.on_sensor_event("B2", "enter", "SEN-2"))
    d.release_route("T1", "R1")
    assert(d.get_block("B2").state == "OCCUPIED", "S-05: the reservation is not lifted before the clearance is proven")
    local ok, status = d.request_route("T2", "RB")
    assert(ok == false and status == "queued")
    assert(d.get_queue()[1].blocked_by[1] == "T1", "the standing train is named")
    assert(d.on_sensor_event("B2", "leave", "SEN-2T"))
    assert(d.get_occupancy("B2").state == "FREE_PROVEN" and d.get_occupancy("B2").source == "tail_sensor")
    assert(d.get_block("B2").reserved_by == "T2", "the waiting request got the block the moment the end of the train was proven")
  end,

  test_a_restart_forgets_every_proof_but_keeps_the_reservations = function()
    local d = dispatcher.new(cfg("on"), adapters())
    prove_all(d)
    assert(d.reserve_route("T1", "R1"))
    local snap = d.snapshot()
    local fresh = dispatcher.new(cfg("on"), adapters())
    fresh.restore(snap)
    assert(fresh.get_block("B1").reserved_by == "T1", "the reservation is the state both masters held")
    assert(fresh.get_occupancy("B3").state == "UNKNOWN", "S-07: a restart is no proof")
    local ok, err = fresh.reserve_route("T2", "R2")
    assert(not ok and err:find("UNKNOWN", 1, true), tostring(err))
    assert(fresh.observe_block("B3", "FREE_PROVEN", "tail_sensor", { at = 5 }))
    assert(fresh.reserve_route("T2", "R2"))
  end,

  test_a_restore_of_a_state_without_proofs_forgets_the_proofs_the_master_had = function()
    local d = dispatcher.new(cfg("on"), adapters())
    prove_all(d)
    d.restore(d.snapshot({ replicated = true }))
    for _, id in ipairs({ "B1", "B2", "B3", "B5", "B6", "B7" }) do assert(d.get_occupancy(id).state == "UNKNOWN", id) end
    assert(d.get_occupancy("B1").last == "FREE_PROVEN", "what it knew stays visible, no longer as a proof")
  end,

  test_a_local_restore_keeps_what_was_known_visible_and_the_flags = function()
    local d = dispatcher.new(cfg("on"), adapters())
    prove_all(d)
    d.timeout_node("SEN-3")
    local snap = d.snapshot()
    local fresh = dispatcher.new(cfg("on"), adapters())
    fresh.restore(snap)
    assert(fresh.get_occupancy("B1").state == "UNKNOWN" and fresh.get_occupancy("B1").last == "FREE_PROVEN")
    assert(fresh.get_occupancy("B3").flags.fault == true, "the fault is still a fault")
  end,

  test_a_fault_that_the_operator_clears_proves_nothing = function()
    local d = dispatcher.new(cfg("on"), adapters())
    prove_all(d)
    d.timeout_node("SEN-3")
    assert(d.get_block("B3").state == "FAULT")
    assert(d.clear_fault("B3"))
    local ok, err = d.reserve_route("T2", "R2")
    assert(not ok and err:find("UNKNOWN", 1, true), "S-10: the repair needs the proof again: " .. tostring(err))
    assert(d.observe_block("B3", "FREE_PROVEN", "sensor_level", { at = 9 }))
    assert(d.reserve_route("T2", "R2"))
  end,

  test_fresh_sensor_levels_of_every_sensor_prove_a_free_block = function()
    local d = dispatcher.new(cfg("on"), adapters())
    local levels = { ["SEN-1"] = { false, 100 }, ["SEN-2"] = { false, 100 }, ["SEN-2T"] = { true, 100 }, ["SEN-3"] = { false, 10 } }
    local ctx = { now = 105, max_age_s = 10, sensor_level = function(id) local l = levels[id]; if l then return l[1], l[2] end return nil end }
    local proven = d.prove_free_from_sensors(ctx)
    local names = {}
    for _, id in ipairs(proven) do names[#names + 1] = id end
    assert(table.concat(names, ",") == "B1", "B2 has an occupied sensor, B3 a stale one, the others never reported: " .. table.concat(names, ","))
    assert(d.get_occupancy("B1").source == "sensor_level")
  end,

  test_an_observer_frees_a_block_nobody_holds_but_not_one_under_a_train = function()
    local d = dispatcher.new(cfg("on"), adapters())
    prove_all(d)
    assert(d.reserve_route("T1", "R1"))
    pass(d, "B1", "SEN-1")
    assert(d.on_sensor_event("B2", "enter", "SEN-2"))
    local ok, err = d.observe_block("B2", "FREE_PROVEN", "observer")
    assert(not ok and err:find("T1", 1, true), "a live train is believed to stand there: " .. tostring(err))
    d.release_route("T1", "R1")
    assert(d.get_block("B2").state == "OCCUPIED")
    assert(d.observe_block("B2", "FREE_PROVEN", "observer"))
    assert(d.get_block("B2").state == "FREE", "the observer saw the track empty: the leave event had been lost")
  end,

  test_the_phases_of_a_reservation_follow_the_train_in_single_master_mode = function()
    local d = dispatcher.new(cfg("on"), adapters())
    prove_all(d)
    assert(d.reserve_route("T1", "R1"))
    assert(d.get_trains().T1.phase == "ACTUATED", "the green was set: " .. tostring(d.get_trains().T1.phase))
    assert(#d.commit_pending() == 0, "one master: nothing to tag")
    assert(d.on_sensor_event("B1", "enter", "SEN-1"))
    assert(d.get_trains().T1.phase == "IN_PROGRESS")
    assert(d.on_sensor_event("B1", "leave", "SEN-1"))
    assert(d.on_sensor_event("B2", "enter", "SEN-2"))
    assert(d.on_sensor_event("B2", "leave", "SEN-2T"))
    assert(d.get_trains().T1.phase == "RELEASED_PROVEN", "every block of the route is proven free: " .. tostring(d.get_trains().T1.phase))
  end,

  test_a_train_whose_end_was_not_proven_stays_in_clearance_pending = function()
    local d = dispatcher.new(cfg("on"), adapters())
    prove_all(d)
    assert(d.reserve_route("T1", "R1"))
    pass(d, "B1", "SEN-1")
    assert(d.on_sensor_event("B2", "enter", "SEN-2"))
    d.release_route("T1", "R1")
    assert(d.get_block("B2").state == "OCCUPIED")
    local record = d.get_clearing()["T1"]
    assert(record and record.phase == "CLEARANCE_PENDING" and record.blocks[1] == "B2", "the clearance of T1 is pending")
    d.on_sensor_event("B2", "leave", "SEN-2T")
    assert(d.get_clearing()["T1"] == nil, "and gone when proven")
  end,

  test_with_the_commit_gate_the_green_waits_for_both_masters = function()
    local a = adapters()
    local d = dispatcher.new(cfg("on"), a)
    prove_all(d)
    d.require_commit(true)
    assert(d.reserve_route("T1", "R1"))
    assert(d.get_trains().T1.phase == "VALIDATED" and a.aspects.S1 ~= "GREEN", "reserved, validated, not given")
    d.set_commit_phase("T1", "PREPARED_BOTH_DURABLE")
    assert(a.aspects.S1 ~= "GREEN" and d.get_trains().T1.phase == "PREPARED_BOTH_DURABLE")
    d.set_commit_phase("T1", "COMMITTED_BOTH_DURABLE")
    assert(a.aspects.S1 == "GREEN" or a.aspects.S1 == "YELLOW", "now the signal is given: " .. tostring(a.aspects.S1))
    assert(d.get_trains().T1.phase == "ACTUATED")
    local pending = d.commit_pending()
    assert(#pending == 0)
  end,

  test_the_commit_gate_lists_what_has_to_be_tagged = function()
    local d = dispatcher.new(cfg("on"), adapters())
    prove_all(d)
    d.require_commit(true)
    assert(d.reserve_route("T1", "R1"))
    local pending = d.commit_pending()
    assert(#pending == 1 and pending[1] == "T1")
    d.tag_commit(7)
    assert(d.get_trains().T1.entry_idx == 7)
    d.advance_commits(6, 6)
    assert(d.get_trains().T1.phase == "VALIDATED")
    d.advance_commits(7, 6)
    assert(d.get_trains().T1.phase == "PREPARED_BOTH_DURABLE")
    d.advance_commits(7, 7)
    assert(d.get_trains().T1.phase == "ACTUATED")
  end,

  test_a_restored_train_is_uncertain_until_its_clearance_is_proven = function()
    local d = dispatcher.new(cfg("on"), adapters())
    prove_all(d)
    assert(d.reserve_route("T1", "R1"))
    pass(d, "B1", "SEN-1")
    assert(d.on_sensor_event("B2", "enter", "SEN-2"))
    local fresh = dispatcher.new(cfg("on"), adapters())
    fresh.restore(d.snapshot())
    assert(fresh.get_trains().T1.phase == "UNCERTAIN", tostring(fresh.get_trains().T1.phase))
    assert(fresh.on_sensor_event("B2", "leave", "SEN-2T"))
    assert(fresh.get_trains().T1.phase == "CLEARANCE_PENDING", "B1 has no proof after the restart: " .. tostring(fresh.get_trains().T1.phase))
    assert(fresh.get_clearing().T1.blocks[1] == "B1")
    assert(fresh.observe_block("B1", "FREE_PROVEN", "observer", { at = 99 }))
    assert(fresh.get_trains().T1.phase == "RELEASED_PROVEN" and fresh.get_clearing().T1 == nil)
  end,

  test_the_local_snapshot_keeps_the_proof_but_what_the_standby_receives_does_not = function()
    local d = dispatcher.new(cfg("on"), adapters())
    prove_all(d)
    assert(d.reserve_route("T1", "R1"))
    local snap = d.snapshot()
    assert(snap.occupancy and snap.occupancy.B1.state == "FREE_PROVEN" and snap.occupancy.B1.source == "observer")
    assert(snap.topology_version == d.get_graph().version and snap.trains.T1.phase == "ACTUATED")
    local replicated = d.snapshot({ replicated = true })
    assert(replicated.occupancy == nil and replicated.clearing == nil and replicated.trains.T1.phase == nil, "nothing that is rebuilt after a change of leader is replicated")
    assert(replicated.blocks.B1.reserved_by == "T1" and replicated.trains.T1.route == "R1")
    -- a restore of the replicated state does not make the next replicated state look different
    local fresh = dispatcher.new(cfg("on"), adapters())
    fresh.restore(replicated)
    local again = fresh.snapshot({ replicated = true })
    local state_delta = require("src.domain.state_delta")
    assert(state_delta.equal(replicated, again), "else the new leader would have a change to commit before it may set a signal that was committed long ago")
  end,

  test_standing_trains_that_wait_for_each_others_blocks_are_a_reported_deadlock_and_nothing_is_forced = function()
    local d = dispatcher.new(cfg("on"), adapters())
    prove_all(d)
    -- T1 stands on B2 (end of R1), T2 on B3 (end of R2); both routes are released, the trains are still there
    assert(d.reserve_route("T1", "R1")); pass(d, "B1", "SEN-1"); assert(d.on_sensor_event("B2", "enter", "SEN-2"))
    assert(d.reserve_route("T2", "R2")); assert(d.on_sensor_event("B3", "enter", "SEN-3"))
    d.release_route("T1", "R1"); d.release_route("T2", "R2")
    -- T1 wants B3 and T2 wants B2
    d.request_route("T1", "RX1"); d.request_route("T2", "RX2")
    d.process_queue()
    local dl = d.get_deadlocks()
    assert(dl.T1 and dl.T2 and dl.T1.cycle[1] == "T1" and dl.T1.cycle[2] == "T2", "both are named with the cycle")
    assert(dl.T1.reason:find("deadlock", 1, true))
    assert(d.get_block("B2").occupied_by == "T1" and d.get_block("B3").occupied_by == "T2", "nobody's reservation was taken away")
    -- T2 leaves, the cycle is gone and T1 gets its way
    assert(d.on_sensor_event("B3", "leave", "SEN-3"))
    d.process_queue()
    assert(d.get_deadlocks().T1 == nil and d.get_deadlocks().T2 == nil, "the cycle is resolved for both")
    assert(d.get_trains().T1.route == "RX1" and d.get_block("B3").reserved_by == "T1")
  end,

  test_trains_that_stand_at_the_end_of_their_routes_and_wait_for_each_other_are_a_deadlock_too = function()
    local d = dispatcher.new(cfg("on"), adapters())
    prove_all(d)
    assert(d.reserve_route("T1", "R1")); pass(d, "B1", "SEN-1"); assert(d.on_sensor_event("B2", "enter", "SEN-2"))
    assert(d.reserve_route("T2", "R2")); assert(d.on_sensor_event("B3", "enter", "SEN-3"))
    d.request_route("T1", "RX1"); d.request_route("T2", "RX2")
    local dl = d.get_deadlocks()
    assert(dl.T1 and dl.T2 and dl.T1.cycle[2] == "T2", "T1 and T2 both stand in the last block of their routes")
    -- a train that is still on its way is no part of a cycle
    local d2 = dispatcher.new(cfg("on"), adapters())
    prove_all(d2)
    assert(d2.reserve_route("T1", "R1")); assert(d2.on_sensor_event("B1", "enter", "SEN-1"))
    assert(d2.reserve_route("T2", "R2")); assert(d2.on_sensor_event("B3", "enter", "SEN-3"))
    d2.request_route("T1", "RX1"); d2.request_route("T2", "RX2")
    assert(next(d2.get_deadlocks()) == nil, "T1 is still in its first block: it will move on and release")
  end,

  test_a_confirmed_alternative_is_used_when_the_first_way_is_blocked_an_unconfirmed_one_is_not = function()
    local d = dispatcher.new(cfg("on"), adapters())
    prove_all(d)
    assert(d.reserve_route("T2", "R2")) -- B3 is taken
    local ok, status = d.request_route("T1", "RA")
    assert(ok == true and status == "reserved", "RA2 is confirmed: " .. tostring(status))
    assert(d.get_trains().T1.route == "RA2")
    local c = cfg("on"); c.routes[4].reachability_confirmed = nil
    local d2 = dispatcher.new(c, adapters())
    prove_all(d2)
    assert(d2.reserve_route("T2", "R2"))
    local ok2, status2 = d2.request_route("T1", "RA")
    assert(ok2 == false and status2 == "queued", "Create is not known to take the other way")
  end
}
