--[[
Purpose: The fleet pair as real nodes: the active node decides, the partner keeps a durable copy, a decision becomes binding only after the partner has it, a lost partner locks new activity, a restart continues (Gesamtkonzept Kap. 8.1, 8.4, 24.1; tests D-03 to D-05).
Public API: returns table of tests.
]]

pcall(dofile, "tests/harness/cc_bootstrap.lua")

local fleet_world = require("tests.harness.fleet_world")

local A, B = fleet_world.A, fleet_world.B

local function with_world(opts, fn)
  local w = fleet_world.new(opts)
  local ok, err = pcall(fn, w)
  w.close()
  if not ok then error(err, 0) end
end

-- 08:00 plus a little: the line has produced its departure
local function until_departure(w) w.run(130000) end

local function trip_of(w, id) return w.nodes[id].engine.trips()[1] end

return {
  test_the_pair_comes_up_in_step_and_the_partner_holds_the_same_state = function()
    with_world({}, function(w)
      w.run(20000)
      local a, b = w.nodes[A], w.nodes[B]
      assert(a.replica.committed_idx() >= 1, "the active node wrote its profiles and lines")
      assert(b.replica.committed_idx() == a.replica.committed_idx() and b.replica.last_idx() == a.replica.last_idx(), "the partner has everything durably")
      assert(a.engine.status().auto_blocked == nil, tostring(a.engine.status().auto_blocked))
      assert(b.engine.trips ~= nil)
    end)
  end,

  test_a_timetable_trip_is_made_by_the_active_node_and_the_route_request_leaves_only_with_the_partner = function()
    with_world({}, function(w)
      until_departure(w)
      local trip = trip_of(w, A)
      assert(trip and trip.state == "TRAIN_CANDIDATE", trip and trip.state)
      w.master.send_event({ type = "station_train", train_id = "TRAIN-1", station = "NORD", present = true }, A)
      w.master.send_free({ "BP1", "BP2" })
      w.run(8000)
      assert(trip.state == "ROUTE_PROPOSED", trip.state)
      local request = w.master.last("fleet_route")
      assert(request and request.trip_id == trip.trip_id and request.train_id == "TRAIN-1" and request.platform_block == "BP1")
      -- when it left, the partner already had the trip
      local copy = w.nodes[B].replica.committed_state()
      assert(copy.trips and #copy.trips >= 1, "the partner holds the trip")
      local found = false
      for _, t in ipairs(copy.trips) do if t.trip_id == trip.trip_id then found = true end end
      assert(found)
      assert(#w.nodes[B].engine.trips() == 1 and w.nodes[B].engine.trips()[1].trip_id == trip.trip_id, "the engine of the partner follows the committed state")
    end)
  end,

  test_with_the_partner_gone_there_is_no_new_automatic_activity_and_nothing_leaves = function()
    with_world({}, function(w)
      w.run(20000)
      w.crash(B)
      w.run(40000)    -- the partner is silent for longer than the timeout
      until_departure(w)
      assert(w.nodes[A].engine.status().auto_blocked and w.nodes[A].engine.status().auto_blocked:find(B, 1, true), tostring(w.nodes[A].engine.status().auto_blocked))
      assert(#w.nodes[A].engine.trips() == 0, "no trip without the pair")
      assert(w.master.count("fleet_route") == 0)
    end)
  end,

  test_a_route_request_made_before_the_partner_failed_waits_until_the_partner_confirms = function()
    with_world({}, function(w)
      until_departure(w)
      w.master.send_event({ type = "station_train", train_id = "TRAIN-1", station = "NORD", present = true }, A)
      w.master.send_free({ "BP1", "BP2" })
      w.crash(B)
      w.run(5000)
      local trip = trip_of(w, A)
      assert(w.master.count("fleet_route") == 0, "the decision is not binding while the partner does not have it: " .. trip.state)
      w.restart(B)
      w.run(40000)
      assert(w.master.count("fleet_route") >= 1, "the partner is back: the request goes")
    end)
  end,

  -- the checksum of the pair compares the state, not the order in which Lua happened to list its keys: a partner that restarts replays its journal into
  -- tables with another order, and the pair used to lock itself for good ("the partners contradict each other") for a state that was the same
  test_a_partner_that_restarts_is_in_step_again_and_the_pair_does_not_lock_itself = function()
    for _, down in ipairs({ 2000, 20000 }) do
      with_world({}, function(w)
        w.run(20000)
        w.crash(B); w.run(down)
        w.restart(B); w.run(8000)
        local ok, why = w.nodes[A].pair_set.auto_allowed("P1")
        assert(ok == true, "after " .. down .. " ms away: " .. tostring(why))
        assert(w.nodes[A].pair_set.status("P1").locked == false)
      end)
    end
  end,

  test_the_whole_trip_through_real_nodes_with_the_schedule_applied_exactly_once = function()
    with_world({}, function(w)
      until_departure(w)
      local trip = trip_of(w, A)
      w.master.send_event({ type = "station_train", train_id = "TRAIN-1", station = "NORD", present = true }, A)
      w.master.send_free({ "BP1", "BP2" })
      w.run(8000)
      local request = w.master.last("fleet_route")
      w.master.send_event({ type = "route_committed", trip_id = request.trip_id, commit_index = 21 }, A)
      w.master.send_event({ type = "route_eligible", trip_id = request.trip_id }, A)
      w.run(8000)
      assert(w.station.count() == 1 and w.station.inbox[1].command_id and w.station.inbox[1].destination == "SUED" and w.station.inbox[1].platform == "P1", "one schedule call")
      assert(trip.state == "SCHEDULE_APPLIED", "the station's applied ack is the answer: " .. trip.state)
      w.master.send_event({ type = "departure_observed", trip_id = trip.trip_id, ref = "o1" }, A)
      w.master.send_event({ type = "arrival_observed", trip_id = trip.trip_id, ref = "o2" }, A)
      w.master.send_event({ type = "tail_clear", trip_id = trip.trip_id, ref = "o3" }, A)
      w.run(8000)
      assert(trip.state == "COMPLETE", trip.state)
      assert(w.station.count() == 1)
      assert(w.master.last("fleet_complete") ~= nil)
    end)
  end,

  test_a_station_that_stays_silent_makes_the_trip_uncertain_not_repeated = function()
    with_world({}, function(w)
      w.station.answer = false
      until_departure(w)
      local trip = trip_of(w, A)
      w.master.send_event({ type = "station_train", train_id = "TRAIN-1", station = "NORD", present = true }, A)
      w.master.send_free({ "BP1", "BP2" })
      w.run(8000)
      local request = w.master.last("fleet_route")
      w.master.send_event({ type = "route_committed", trip_id = request.trip_id, commit_index = 21 }, A)
      w.master.send_event({ type = "route_eligible", trip_id = request.trip_id }, A)
      w.run(120000)
      assert(trip.state == "UNCERTAIN", trip.state)
      local calls = w.station.count()
      assert(calls >= 1)
      w.run(60000)
      assert(w.station.count() == calls, "the retries of the net are the same message; the fleet never makes a second call")
      assert(w.master.last("fleet_reconstruct") ~= nil)
    end)
  end,

  test_a_restart_of_the_active_node_continues_the_trip_without_making_it_again = function()
    with_world({}, function(w)
      until_departure(w)
      local trip_id = trip_of(w, A).trip_id
      w.master.send_event({ type = "station_train", train_id = "TRAIN-1", station = "NORD", present = true }, A)
      w.master.send_free({ "BP1", "BP2" })
      w.run(8000)
      assert(w.master.count("fleet_route") >= 1)
      local sent = w.master.count("fleet_route")
      w.crash(A)
      w.restart(A)
      w.run(15000)
      assert(#w.nodes[A].engine.trips() == 1 and w.nodes[A].engine.trips()[1].trip_id == trip_id, "the same trip, not a second one")
      assert(w.nodes[A].engine.trips()[1].state == "ROUTE_PROPOSED", w.nodes[A].engine.trips()[1].state)
      w.master.send_event({ type = "route_committed", trip_id = trip_id, commit_index = 22 }, A)
      w.run(2000)
      assert(w.nodes[A].engine.trips()[1].state == "DUAL_MASTER_COMMITTED")
    end)
  end,

  test_the_partner_acts_on_nothing_and_only_the_known_senders_are_heard = function()
    with_world({}, function(w)
      until_departure(w)
      w.master.send_event({ type = "station_train", train_id = "TRAIN-1", station = "NORD", present = true }, B)
      w.run(5000)
      local t = w.nodes[B].engine.trips()[1]
      assert(t == nil or t.state ~= "STATION_CONFIRMED", "the partner does not run the trip")
      local stranger = require("src.shared.net").new(w.link.modem("STRANGER"), 1, "STRANGER", { info = function() end, warn = function() end, error = function() end, debug = function() end })
      stranger.send_reliable("event", A, { type = "fleet_event", ev = { type = "station_train", train_id = "TRAIN-1", station = "NORD", present = true } })
      w.run(5000)
      assert(trip_of(w, A).state == "TRAIN_CANDIDATE", "an event of a stranger is not heard")
    end)
  end,

  test_free_blocks_are_known_only_while_the_master_says_so = function()
    with_world({}, function(w)
      until_departure(w)
      local trip = trip_of(w, A)
      w.master.send_event({ type = "station_train", train_id = "TRAIN-1", station = "NORD", present = true }, A)
      w.run(5000)
      assert(trip.state == "WAITING" and trip.reason:find("platform", 1, true), "no block reported free: no platform: " .. trip.state)
      w.master.send_free({ "BP2" })
      w.run(5000)
      assert(w.master.last("fleet_route") and w.master.last("fleet_route").platform_block == "BP2")
      w.run(30000)   -- the report gets old
    end)
  end,

  test_a_journal_that_cannot_be_written_withholds_every_decision = function()
    with_world({}, function(w)
      w.run(20000)
      w.fs[A].journal.fail.open = "state/fleet_journal.log"
      until_departure(w)
      assert(#w.nodes[A].engine.trips() == 0, "the node does not make decisions it cannot write down")
      w.master.send_event({ type = "station_train", train_id = "TRAIN-1", station = "NORD", present = true }, A)
      w.master.send_free({ "BP1", "BP2" })
      w.run(10000)
      assert(w.master.count("fleet_route") == 0)
    end)
  end,

  test_a_message_waits_when_its_state_could_not_be_written_down = function()
    with_world({}, function(w)
      until_departure(w)
      local trip = trip_of(w, A)
      assert(trip and trip.state == "TRAIN_CANDIDATE")
      w.master.send_free({ "BP1", "BP2" })
      w.run(3000)
      w.fs[A].journal.fail.open = "state/fleet_journal.log"
      w.master.send_event({ type = "station_train", train_id = "TRAIN-1", station = "NORD", present = true }, A)
      w.run(10000)
      assert(w.master.count("fleet_route") == 0, "the route request depends on a state the node could not write: it stays")
    end)
  end,

  test_a_stranger_cannot_vouch_for_the_partner = function()
    with_world({}, function(w)
      w.run(20000)
      w.crash(B)
      w.run(40000)
      local json = require("src.shared.json")
      local checksum = require("src.shared.checksum")
      local a = w.nodes[A]
      local idx = a.replica.committed_idx()
      local sum = checksum.hex(checksum.adler32(json.encode(a.replica.committed_state())))
      local stranger = require("src.shared.net").new(w.link.modem("STRANGER"), 1, "STRANGER", { info = function() end, warn = function() end, error = function() end, debug = function() end })
      for _ = 1, 140 do
        stranger.send("event", A, { type = "fleet_pair", version = idx, checksum = sum })
        w.run(1000)
      end
      assert(a.engine.status().auto_blocked ~= nil and #a.engine.trips() == 0, "only the partner itself says whether it is alive")
    end)
  end,

  test_a_report_of_free_blocks_gets_old = function()
    with_world({}, function(w)
      until_departure(w)
      local trip = trip_of(w, A)
      w.master.send_free({ "BP1", "BP2" })
      w.run(30000)     -- nobody repeats the report: it is stale
      w.master.send_event({ type = "station_train", train_id = "TRAIN-1", station = "NORD", present = true }, A)
      w.run(3000)
      assert(trip.state == "WAITING" and trip.reason:find("platform", 1, true), "a stale report is no proof that a platform is free: " .. trip.state)
      assert(w.master.count("fleet_route") == 0)
    end)
  end,

  test_an_acknowledgement_without_applied_is_not_an_applied_schedule = function()
    with_world({ apply_timeout_s = 600 }, function(w)
      w.station.applied = false
      until_departure(w)
      local trip = trip_of(w, A)
      w.master.send_event({ type = "station_train", train_id = "TRAIN-1", station = "NORD", present = true }, A)
      w.master.send_free({ "BP1", "BP2" })
      w.run(8000)
      local request = w.master.last("fleet_route")
      w.master.send_event({ type = "route_committed", trip_id = request.trip_id, commit_index = 21 }, A)
      w.master.send_event({ type = "route_eligible", trip_id = request.trip_id }, A)
      w.run(20000)
      assert(w.station.count() == 1)
      assert(trip.state == "ACTUATOR_ELIGIBLE", "delivered is not applied: " .. trip.state)
    end)
  end,

  test_a_schedule_call_that_ran_out_of_retries_is_reported_to_the_engine = function()
    with_world({ apply_timeout_s = 3000 }, function(w)
      w.station.answer = false
      until_departure(w)
      local trip = trip_of(w, A)
      w.master.send_event({ type = "station_train", train_id = "TRAIN-1", station = "NORD", present = true }, A)
      w.master.send_free({ "BP1", "BP2" })
      w.run(8000)
      local request = w.master.last("fleet_route")
      w.master.send_event({ type = "route_committed", trip_id = request.trip_id, commit_index = 21 }, A)
      w.master.send_event({ type = "route_eligible", trip_id = request.trip_id }, A)
      w.run(200000)
      assert(trip.state == "UNCERTAIN" and trip.reason:find("no answer from", 1, true), tostring(trip.state) .. " " .. tostring(trip.reason))
    end)
  end,

  test_the_message_that_ends_a_trip_waits_when_the_end_could_not_be_written_down = function()
    with_world({}, function(w)
      until_departure(w)
      local trip = trip_of(w, A)
      w.master.send_event({ type = "station_train", train_id = "TRAIN-1", station = "NORD", present = true }, A)
      w.master.send_free({ "BP1", "BP2" })
      w.run(8000)
      local request = w.master.last("fleet_route")
      w.master.send_event({ type = "route_committed", trip_id = request.trip_id, commit_index = 21 }, A)
      w.master.send_event({ type = "route_eligible", trip_id = request.trip_id }, A)
      w.run(8000)
      w.master.send_event({ type = "departure_observed", trip_id = trip.trip_id, ref = "o1" }, A)
      w.master.send_event({ type = "arrival_observed", trip_id = trip.trip_id, ref = "o2" }, A)
      w.run(3000)
      w.fs[A].journal.fail.open = "state/fleet_journal.log"
      w.master.send_event({ type = "tail_clear", trip_id = trip.trip_id, ref = "o3" }, A)
      w.run(8000)
      assert(trip.state == "COMPLETE")
      assert(w.master.count("fleet_complete") == 0, "the end of the trip is not binding before it is written down")
    end)
  end
}
