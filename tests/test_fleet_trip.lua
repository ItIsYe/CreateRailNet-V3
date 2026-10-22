--[[
Purpose: The life of a trip from the request to the proven clearance of the tail, the waiting, uncertain and fault states, the separate ids (Gesamtkonzept Kap. 8.4, 24.1; tests C-01, C-03, C-09, D-02, D-07).
Public API: returns table of tests.
]]

local trip = require("src.fleet.trip")

local CHAIN = { "VALIDATED_BY_FLEET", "TRAIN_CANDIDATE", "STATION_CONFIRMED", "TARGET_PLATFORM_ASSIGNED", "ROUTE_PROPOSED", "DUAL_MASTER_COMMITTED", "ACTUATOR_ELIGIBLE",
  "SCHEDULE_APPLIED", "DEPARTURE_OBSERVED", "EN_ROUTE", "ARRIVAL_OBSERVED", "TAIL_CLEARANCE_PROVEN", "COMPLETE" }

local EVIDENCE = {
  DEPARTURE_OBSERVED = { kind = "departure_observation", ref = "obs-1" },
  ARRIVAL_OBSERVED = { kind = "arrival_observation", ref = "obs-2" },
  TAIL_CLEARANCE_PROVEN = { kind = "tail_clearance", ref = "clr-1" },
  SCHEDULE_APPLIED = { kind = "schedule_applied", ref = "ack-1" },
  DUAL_MASTER_COMMITTED = { kind = "master_commit", ref = "idx-9" }
}

local function walk(t, upto)
  for _, state in ipairs(CHAIN) do
    local ok, err = trip.advance(t, state, EVIDENCE[state])
    assert(ok, state .. ": " .. tostring(err))
    if state == upto then return end
  end
end

return {
  test_the_normal_way_goes_through_every_state_in_the_order_of_the_concept = function()
    local t = trip.new({ trip_id = "T1", order_id = "O1", origin = "manual" })
    assert(t.state == "NEW_REQUEST")
    walk(t)
    assert(t.state == "COMPLETE" and trip.is_final(t.state))
    assert(#t.history == 14, "every state is in the history: " .. #t.history)
  end,

  test_no_state_is_skipped_and_none_goes_back = function()
    local t = trip.new({ trip_id = "T1" })
    local ok, err = trip.advance(t, "ROUTE_PROPOSED")
    assert(not ok and err:find("NEW_REQUEST", 1, true) and t.state == "NEW_REQUEST", tostring(err))
    walk(t, "TRAIN_CANDIDATE")
    assert(not trip.advance(t, "VALIDATED_BY_FLEET"))
    assert(trip.advance(t, "STATION_CONFIRMED") == true)
    assert(not trip.advance(t, "NONSENSE"))
  end,

  test_a_manual_request_is_a_wish_not_a_command = function()
    local t = trip.new({ trip_id = "T1", origin = "manual" })
    assert(not trip.may_move(t), "a requested trip moves nothing")
    walk(t, "ACTUATOR_ELIGIBLE")
    assert(not trip.may_move(t), "eligible is still not moving")
    assert(trip.advance(t, "SCHEDULE_APPLIED", EVIDENCE.SCHEDULE_APPLIED))
    assert(trip.may_move(t) == true, "after the schedule was applied the train may be on its way")
  end,

  test_the_steps_that_state_a_physical_fact_need_their_evidence = function()
    for state, evidence in pairs(EVIDENCE) do
      local t = trip.new({ trip_id = "T-" .. state })
      local before = CHAIN[(function() for i, s in ipairs(CHAIN) do if s == state then return i - 1 end end end)()]
      if before then walk(t, before) end
      local ok, err = trip.advance(t, state, nil)
      assert(not ok and err:find("evidence", 1, true), state .. " without evidence: " .. tostring(err))
      local wrong = trip.advance(t, state, { kind = "something_else", ref = "x" })
      assert(not wrong, state .. " with evidence of the wrong kind")
      assert(trip.advance(t, state, evidence), state)
      assert(t.evidence[#t.evidence].ref == evidence.ref)
    end
  end,

  test_an_accepted_schedule_is_not_a_departure = function()
    local t = trip.new({ trip_id = "T1" })
    walk(t, "SCHEDULE_APPLIED")
    local ok, err = trip.advance(t, "EN_ROUTE", { kind = "schedule_applied", ref = "ack-2" })
    assert(not ok, "the acknowledgement of the call is not the observation of the departure")
    assert(not trip.advance(t, "DEPARTURE_OBSERVED", { kind = "schedule_applied", ref = "ack-2" }))
    assert(trip.advance(t, "DEPARTURE_OBSERVED", EVIDENCE.DEPARTURE_OBSERVED))
  end,

  test_before_the_schedule_is_applied_a_missing_proof_means_waiting_and_resuming = function()
    local t = trip.new({ trip_id = "T1" })
    walk(t, "STATION_CONFIRMED")
    assert(trip.wait(t, "all platforms occupied"))
    assert(t.state == "WAITING" and t.waiting_from == "STATION_CONFIRMED" and t.reason == "all platforms occupied")
    assert(not trip.advance(t, "TARGET_PLATFORM_ASSIGNED"), "a waiting trip first resumes")
    assert(trip.resume(t) and t.state == "STATION_CONFIRMED")
    assert(trip.advance(t, "TARGET_PLATFORM_ASSIGNED"))
  end,

  test_once_the_schedule_is_applied_a_missing_proof_is_uncertain_never_waiting = function()
    local t = trip.new({ trip_id = "T1" })
    walk(t, "SCHEDULE_APPLIED")
    local ok, err = trip.wait(t, "no departure seen")
    assert(not ok and err:find("uncertain", 1, true), tostring(err))
    assert(trip.uncertain(t, "no departure seen") and t.state == "UNCERTAIN")
    assert(not trip.resume(t), "an uncertain trip is not resumed by a click, it is reconstructed")
    assert(trip.reconstruct(t, "EN_ROUTE", { kind = "position_observation", ref = "obs-7" }))
    assert(t.state == "EN_ROUTE" and t.evidence[#t.evidence].ref == "obs-7")
    assert(not trip.reconstruct(t, "EN_ROUTE", nil))
  end,

  test_reconstruction_of_an_uncertain_trip_needs_an_observation = function()
    local t = trip.new({ trip_id = "T1" })
    walk(t, "SCHEDULE_APPLIED")
    trip.uncertain(t, "x")
    local ok, err = trip.reconstruct(t, "EN_ROUTE", nil)
    assert(not ok and err:find("observation", 1, true) and t.state == "UNCERTAIN", tostring(err))
    assert(not trip.reconstruct(t, "EN_ROUTE", { kind = "position_observation" }), "a reference is needed")
    assert(not trip.reconstruct(t, "COMPLETE", { kind = "position_observation", ref = "r" }), "not to any state")
    local fresh = trip.new({ trip_id = "T2" })
    assert(not trip.reconstruct(fresh, "EN_ROUTE", { kind = "position_observation", ref = "r" }), "only an uncertain trip")
  end,

  test_cancel_before_the_schedule_ends_the_trip_and_after_it_only_at_a_proven_safe_stop = function()
    local early = trip.new({ trip_id = "E" })
    walk(early, "ROUTE_PROPOSED")
    assert(trip.cancel(early, "operator") and early.state == "CANCELLED" and trip.is_final(early.state))
    local running = trip.new({ trip_id = "R" })
    walk(running, "EN_ROUTE")
    assert(trip.cancel(running, "operator"))
    assert(running.state == "CANCEL_PENDING" and trip.may_move(running) == true, "the train is still moving and its reservations stay")
    assert(not trip.advance(running, "CANCELLED", nil))
    assert(trip.advance(running, "CANCELLED", { kind = "safe_stop_reached", ref = "stop-3" }))
    assert(running.state == "CANCELLED")
    assert(not trip.cancel(running, "again"), "a final trip is final")
  end,

  test_a_fault_is_possible_everywhere_and_final_states_stay_final = function()
    for _, upto in ipairs({ "VALIDATED_BY_FLEET", "ROUTE_PROPOSED", "SCHEDULE_APPLIED", "EN_ROUTE" }) do
      local t = trip.new({ trip_id = "F" .. upto })
      walk(t, upto)
      assert(trip.fault(t, "boom") and t.state == "FAULT" and t.reason == "boom")
      assert(not trip.advance(t, "COMPLETE"))
    end
    local done = trip.new({ trip_id = "D" }); walk(done)
    assert(not trip.fault(done, "late") and done.state == "COMPLETE")
  end,

  test_a_moving_trip_is_never_shown_with_a_last_known_position_as_the_real_one = function()
    local t = trip.new({ trip_id = "T1" })
    walk(t, "EN_ROUTE")
    trip.record_position(t, { block = "B4", at = 100, quality = "observed" })
    local view = trip.position_view(t, 400, 60)
    assert(view.block == "B4" and view.stale == true and view.proven == false, "older than the limit: stale, not proven")
    local fresh = trip.position_view(t, 120, 60)
    assert(fresh.stale == false and fresh.proven == true)
    assert(trip.position_view(trip.new({ trip_id = "N" }), 0, 60).block == nil)
  end,

  test_ids_are_separate_and_a_restart_does_not_repeat_them = function()
    local ids = trip.ids({ prefix = "FA", run = "boot7" })
    local order, order2 = ids.order(), ids.order()
    local trip_id = ids.trip()
    local leg = ids.leg(trip_id)
    local command = ids.command(trip_id)
    assert(order ~= order2 and order:find("FA", 1, true))
    assert(trip_id ~= order and leg ~= trip_id and command ~= leg and leg:find(trip_id, 1, true))
    local again = trip.ids({ prefix = "FA", run = "boot8", state = ids.snapshot() })
    assert(again.order() ~= order and again.order() ~= order2, "counted on from the saved state")
    assert(ids.command(trip_id) ~= command)
    assert(trip.trip_id_from_key("L1/v1/d0/08:00") == "TRIP-L1/v1/d0/08:00" and trip.trip_id_from_key("L1/v1/d0/08:00") == trip.trip_id_from_key("L1/v1/d0/08:00"))
  end,

  test_snapshot_and_restore_keep_the_trip = function()
    local t = trip.new({ trip_id = "T1", order_id = "O1" })
    walk(t, "ROUTE_PROPOSED")
    local copy = trip.restore(trip.snapshot(t))
    assert(copy.state == "ROUTE_PROPOSED" and copy.order_id == "O1" and #copy.history == #t.history)
    assert(trip.advance(copy, "DUAL_MASTER_COMMITTED", EVIDENCE.DUAL_MASTER_COMMITTED))
    assert(trip.restore({ state = "WHATEVER", trip_id = "X" }).state == "UNCERTAIN")
  end
}
