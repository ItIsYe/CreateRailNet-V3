--[[
Purpose: The fleet engine end to end with a simulated world: a timetable makes orders, the fleet picks a train, a platform and a route, waits for the masters, applies the schedule exactly once, and the trip ends only with the proof of the tail (Gesamtkonzept Kap. 2.1, 8, 10, 24.1; tests C-01 to C-12, D-01 to D-10).
Public API: returns table of tests.
]]

local engine_module = require("src.fleet.engine")
local profile_module = require("src.fleet.profile")
local timetable_module = require("src.fleet.timetable")
local fleet_pairs = require("src.fleet.pairs")

local approval = { operator = "tim", confirmed = true }

local function world(extra)
  extra = extra or {}
  local w = { t = 100000, epoch = 8 * 3600 - 60, out = {}, free = { P1 = true, P2 = true }, stations = {} }
  local profiles = profile_module.new({ now = function() return w.t end })
  assert(profiles.register({ immutable_id = "TRAIN-1", create_name_ref = "Sued 1", train_class = "PASSENGER", length = 6, permitted_directions = { "EAST", "WEST" }, line_permissions = { "L1" } }, approval))
  if extra.freight then
    assert(profiles.register({ immutable_id = "FREIGHT-1", create_name_ref = "Fracht 1", train_class = "FREIGHT", length = 10, permitted_directions = { "EAST", "WEST" } }, approval))
  end
  local tt = timetable_module.new({ time = { real = function() return w.epoch end, ingame = function() return 0, 0 end } })
  local pairs_ = fleet_pairs.new({ nodes = { "FLEET-A", "FLEET-B" }, pairs = { { id = "P1", nodes = { "FLEET-A", "FLEET-B" } } }, now = function() return w.t end, timeout_s = 30 })
  pairs_.heartbeat("FLEET-A", { version = 1, checksum = "x" }); pairs_.heartbeat("FLEET-B", { version = 1, checksum = "x" })
  assert(pairs_.assign_train("TRAIN-1", "P1", approval))
  if extra.freight then assert(pairs_.assign_train("FREIGHT-1", "P1", approval)) end
  local line = { id = "L1", kind = "PASSENGER", time_base = "REAL", window = { from = "06:00", to = "22:00" }, departures = { "08:00" }, dwell_s = 30,
    stops = { { station = "NORD" }, { station = "SUED" } }, routes = { EAST = "R-NS" }, origin = "NORD", goal = "SUED", direction = "EAST", train_classes = { "PASSENGER" } }
  local v = assert(tt.add_draft(line)); assert(tt.publish("L1", v, { ["FLEET-A"] = true, ["FLEET-B"] = true }, { "FLEET-A", "FLEET-B" }))
  w.engine = engine_module.new({
    id = "FLEET-A", pair_id = "P1", profiles = profiles, timetable = tt, pairs = pairs_, now = function() return w.t end, ids_prefix = "FA",
    platforms = { SUED = { { id = "P1", block = "BP1", direction = "EAST", length = 12, confirmed = true, preferred = 1 }, { id = "P2", block = "BP2", direction = "EAST", length = 12, confirmed = true, preferred = 2 } } },
    is_free = function(block)
      if w.free_blocks and w.free_blocks[block] ~= nil then return w.free_blocks[block] end
      return w.free[block == "BP1" and "P1" or "P2"] == true
    end,
    depart_timeout_s = 60, route_timeout_s = 120, apply_timeout_s = 30,
    depots = extra.depots, depot_circuit = extra.depot_circuit,
    cargo_may_check = function() return true end
  })
  w.profiles, w.pairs, w.tt = profiles, pairs_, tt
  function w.tick(seconds)
    w.t = w.t + (seconds or 1); w.epoch = w.epoch + (seconds or 1)
    pairs_.heartbeat("FLEET-A", { version = 1, checksum = "x" }); pairs_.heartbeat("FLEET-B", { version = 1, checksum = "x" })
    w.engine.tick()
    for _, m in ipairs(w.engine.take_outbox()) do w.out[#w.out + 1] = m end
  end
  function w.last(kind)
    for i = #w.out, 1, -1 do if w.out[i].type == kind then return w.out[i] end end
  end
  function w.count(kind) local n = 0; for _, m in ipairs(w.out) do if m.type == kind then n = n + 1 end end return n end
  function w.event(ev) w.engine.event(ev); for _, m in ipairs(w.engine.take_outbox()) do w.out[#w.out + 1] = m end end
  return w
end

-- the world answers like the real net would, step by step
local function drive_to_apply(w)
  w.tick(60)  -- 08:00 comes
  local trip = w.engine.trips()[1]
  assert(trip, "a trip was made from the timetable")
  w.event({ type = "station_train", train_id = "TRAIN-1", station = "NORD", present = true })
  w.tick(1)
  local request = w.last("route_request")
  assert(request, "the fleet proposed a route")
  w.event({ type = "route_committed", trip_id = request.trip_id, commit_index = 11 })
  w.event({ type = "route_eligible", trip_id = request.trip_id })
  w.tick(1)
  return trip, w.last("apply_schedule")
end

return {
  test_a_timetable_trip_runs_from_the_clock_to_the_proven_clearance_of_the_tail = function()
    local w = world()
    local trip, apply = drive_to_apply(w)
    assert(apply and apply.trip_id == trip.trip_id and apply.station == "NORD" and apply.destination == "SUED" and apply.platform == "P1", "the schedule names the station, the goal and the platform")
    assert(trip.state == "ACTUATOR_ELIGIBLE", trip.state)
    w.event({ type = "schedule_applied", trip_id = trip.trip_id, command_id = apply.command_id, ok = true })
    assert(trip.state == "SCHEDULE_APPLIED")
    w.event({ type = "departure_observed", trip_id = trip.trip_id, ref = "obs-1" })
    assert(trip.state == "DEPARTURE_OBSERVED")
    w.event({ type = "position", trip_id = trip.trip_id, block = "B3", ref = "obs-2", observed = true })
    assert(trip.state == "EN_ROUTE" and trip.position.block == "B3")
    w.event({ type = "arrival_observed", trip_id = trip.trip_id, ref = "obs-3" })
    assert(trip.state == "ARRIVAL_OBSERVED")
    w.event({ type = "tail_clear", trip_id = trip.trip_id, ref = "clr-1" })
    assert(trip.state == "COMPLETE")
    assert(w.count("apply_schedule") == 1, "the schedule is applied exactly once")
    w.tick(60)
    assert(#w.engine.trips() == 1 or w.engine.trips()[2] == nil, "no second trip for the same departure")
  end,

  test_the_route_request_names_trip_leg_command_and_the_target_platform_and_each_id_is_its_own = function()
    local w = world()
    local trip = drive_to_apply(w)
    local request = w.last("route_request")
    assert(request.train_id == "TRAIN-1" and request.route_id == "R-NS" and request.platform_block == "BP1")
    assert(request.trip_id ~= request.leg_id and request.leg_id ~= request.command_id and request.command_id ~= request.order_id, "separate ids")
    assert(trip.order_id and trip.priority_class == "SCHEDULED_PASSENGER" and trip.assigned_train == "TRAIN-1")
  end,

  test_nothing_happens_when_the_pair_is_not_healthy = function()
    local w = world()
    w.t = w.t + 1000    -- nobody reported for a long time
    w.epoch = w.epoch + 60
    w.engine.tick()
    assert(#w.engine.trips() == 0, "no new automatic activity")
    assert(w.engine.status().auto_blocked:find("silent", 1, true), tostring(w.engine.status().auto_blocked))
    assert(w.engine.queue_size() >= 1, "the order waits, it is not lost")
  end,

  test_a_manual_request_is_a_wish_that_waits_for_the_same_checks = function()
    local w = world()
    local ok, trip_id = w.engine.request({ origin = "NORD", goal = "SUED", direction = "EAST", route_id = "R-NS", train_class = "PASSENGER", line_id = "L1", requested_by = "tim" })
    assert(ok and trip_id)
    local trip = w.engine.trip(trip_id)
    assert(trip.state == "NEW_REQUEST" and trip.origin == "NORD" and trip.requested_by == "tim")
    assert(w.last("route_request") == nil and w.last("apply_schedule") == nil, "a request moves nothing")
    w.tick(1)
    assert(trip.state == "TRAIN_CANDIDATE" and trip.assigned_train == "TRAIN-1", trip.state)
  end,

  test_the_train_must_really_be_at_the_station_and_an_unknown_train_is_not_taken = function()
    local w = world()
    w.tick(60)
    local trip = w.engine.trips()[1]
    w.event({ type = "station_train", train_id = "MYSTERY", station = "NORD", present = true, create_name = "Geisterzug" })
    assert(trip.state == "TRAIN_CANDIDATE", "the wrong train changes nothing: " .. trip.state)
    assert(w.profiles.pending()[1].name == "Geisterzug", "the unknown train is seen, not registered")
    w.event({ type = "station_train", train_id = "TRAIN-1", station = "SUED", present = true })
    assert(trip.state == "TRAIN_CANDIDATE", "at the wrong station")
    w.event({ type = "station_train", train_id = "TRAIN-1", station = "NORD", present = true })
    w.tick(1)
    assert(trip.state == "ROUTE_PROPOSED" or trip.state == "TARGET_PLATFORM_ASSIGNED", trip.state)
  end,

  test_the_station_names_the_train_by_its_create_name = function()
    local w = world()
    w.tick(60)
    local trip = w.engine.trips()[1]
    w.event({ type = "station_train", train_id = "Sued 1", create_name = "Sued 1", station = "NORD", present = true })
    assert(trip.state == "STATION_CONFIRMED", "the Create name is the train's registered identity: " .. trip.state)
  end,

  test_all_platforms_taken_the_trip_waits_and_goes_on_when_one_is_free = function()
    local w = world()
    w.free = {}
    w.tick(60)
    local trip = w.engine.trips()[1]
    w.event({ type = "station_train", train_id = "TRAIN-1", station = "NORD", present = true })
    w.tick(1)
    assert(trip.state == "WAITING" and trip.reason:find("platform", 1, true) and w.last("route_request") == nil, trip.state)
    assert(w.last("hold_at_waiting_point") ~= nil, "the train waits at a safe waiting point before the station")
    w.free = { P2 = true }
    w.tick(1)
    assert(w.last("route_request").platform_block == "BP2" and trip.state == "ROUTE_PROPOSED", "the second platform is taken: " .. trip.state)
  end,

  test_a_train_serves_one_trip_at_a_time_and_the_second_order_waits = function()
    local w = world()
    w.tt.add_draft({ id = "L2", kind = "PASSENGER", time_base = "REAL", window = { from = "06:00", to = "22:00" }, departures = { "08:00" }, stops = { { station = "NORD" }, { station = "SUED" } },
      routes = { EAST = "R-NS" }, origin = "NORD", goal = "SUED", direction = "EAST", train_classes = { "PASSENGER" } })
    assert(w.tt.publish("L2", 1, { ["FLEET-A"] = true, ["FLEET-B"] = true }, { "FLEET-A", "FLEET-B" }))
    w.profiles.get("TRAIN-1").line_permissions = {}
    w.tick(60)
    local trips = w.engine.trips()
    local with_train = 0
    for _, t in ipairs(trips) do if t.assigned_train == "TRAIN-1" then with_train = with_train + 1 end end
    assert(with_train == 1, "one train, one trip: " .. with_train)
    assert(w.engine.queue_size() == 1, "the other order is still waiting")
  end,

  test_a_refused_route_makes_the_trip_wait_and_ask_again_and_too_often_a_fault = function()
    local w = world()
    local trip = drive_to_apply(w)
    -- (the helper committed already; use a second world for the refusal)
    local w2 = world()
    w2.tick(60)
    local t2 = w2.engine.trips()[1]
    w2.event({ type = "station_train", train_id = "TRAIN-1", station = "NORD", present = true })
    w2.tick(1)
    local first = w2.last("route_request")
    w2.event({ type = "route_refused", trip_id = first.trip_id, reason = "block B2 not proven free" })
    assert(t2.state == "WAITING" and t2.reason:find("B2", 1, true))
    w2.tick(31)
    assert(w2.count("route_request") == 2 and w2.last("route_request").command_id ~= first.command_id, "asked again with a new command id")
    for _ = 1, 6 do
      w2.event({ type = "route_refused", trip_id = w2.last("route_request").trip_id, reason = "still not free" })
      w2.tick(31)
    end
    assert(t2.state == "FAULT" and t2.reason:find("too often", 1, true), "it does not ask forever: " .. t2.state)
    assert(w2.count("route_request") == 6, "the first plus five more: " .. w2.count("route_request"))
  end,

  test_no_signal_of_the_schedule_before_the_actuator_is_eligible_and_a_lost_answer_is_never_repeated_blindly = function()
    local w = world()
    local trip, apply = drive_to_apply(w)
    assert(w.count("apply_schedule") == 1)
    w.tick(31)    -- the station never answered
    assert(trip.state == "UNCERTAIN", "no answer: the outcome is unknown: " .. trip.state)
    assert(w.count("apply_schedule") == 1, "the call is not repeated blindly")
    assert(w.last("reconstruct_request") and w.last("reconstruct_request").trip_id == trip.trip_id, "first the real state of the train and the station is asked for")
    w.event({ type = "reconstruction", trip_id = trip.trip_id, state = "EN_ROUTE", ref = "obs-9", block = "B2" })
    assert(trip.state == "EN_ROUTE" and trip.position.block == "B2")
  end,

  test_no_departure_seen_after_the_schedule_is_uncertain_not_complete = function()
    local w = world()
    local trip, apply = drive_to_apply(w)
    w.event({ type = "schedule_applied", trip_id = trip.trip_id, command_id = apply.command_id, ok = true })
    w.tick(61)
    assert(trip.state == "UNCERTAIN", trip.state)
    assert(trip.reason:find("departure", 1, true))
  end,

  test_a_restart_in_the_middle_does_not_make_a_second_trip_or_a_second_schedule = function()
    local w = world()
    local trip, apply = drive_to_apply(w)
    local snap = w.engine.snapshot()
    local w2 = world()
    w2.engine.restore(snap)
    w2.t = w.t + 5; w2.epoch = w.epoch + 5
    w2.tick(1)
    assert(#w2.engine.trips() == 1, "the departure of 08:00 is not made again")
    assert(w2.count("apply_schedule") == 0, "and the schedule is not applied again on the restored engine")
    local restored = w2.engine.trips()[1]
    assert(restored.trip_id == trip.trip_id and restored.state == "ACTUATOR_ELIGIBLE")
    w2.tick(31)
    assert(restored.state == "UNCERTAIN", "the engine does not guess; it asks: " .. restored.state)
    assert(w2.count("apply_schedule") == 0 and w2.count("reconstruct_request") == 1)
  end,

  test_cancelling_a_running_trip_waits_for_a_safe_stop_and_keeps_the_reservations = function()
    local w = world()
    local trip, apply = drive_to_apply(w)
    w.event({ type = "schedule_applied", trip_id = trip.trip_id, command_id = apply.command_id, ok = true })
    w.event({ type = "departure_observed", trip_id = trip.trip_id, ref = "o1" })
    assert(w.engine.cancel(trip.trip_id, "tim"))
    assert(trip.state == "CANCEL_PENDING" and w.last("release_reservation") == nil, "the reservation stays while the train moves")
    w.event({ type = "safe_stop_reached", trip_id = trip.trip_id, ref = "stop-1" })
    assert(trip.state == "CANCELLED")
    assert(w.last("release_reservation") and w.last("release_reservation").trip_id == trip.trip_id, "now the reservation may go")
  end,

  test_the_answer_of_another_schedule_call_is_not_ours = function()
    local w = world()
    local trip, apply = drive_to_apply(w)
    w.event({ type = "schedule_applied", trip_id = trip.trip_id, command_id = "SOMEONE-ELSE", ok = true })
    assert(trip.state == "ACTUATOR_ELIGIBLE", "an answer to another call is no answer: " .. trip.state)
    w.event({ type = "schedule_applied", trip_id = trip.trip_id, command_id = apply.command_id, ok = true })
    assert(trip.state == "SCHEDULE_APPLIED")
  end,

  test_a_train_of_another_pair_is_never_taken = function()
    local w = world()
    w.pairs.release_train("TRAIN-1", approval)
    w.tick(60)
    assert(#w.engine.trips() == 0 and w.engine.queue_size() == 1, "no train belongs to this pair: the order waits")
  end,

  test_cancelling_before_the_schedule_releases_a_route_that_was_asked_for = function()
    local w = world()
    w.tick(60)
    local trip = w.engine.trips()[1]
    w.event({ type = "station_train", train_id = "TRAIN-1", station = "NORD", present = true })
    w.tick(1)
    assert(trip.state == "ROUTE_PROPOSED")
    assert(w.engine.cancel(trip.trip_id, "tim"))
    assert(trip.state == "CANCELLED")
    for _, m in ipairs(w.engine.take_outbox()) do w.out[#w.out + 1] = m end
    assert(w.last("release_reservation") and w.last("release_reservation").trip_id == trip.trip_id)
  end,

  test_an_arrival_without_position_reports_is_still_an_arrival = function()
    local w = world()
    local trip, apply = drive_to_apply(w)
    w.event({ type = "schedule_applied", trip_id = trip.trip_id, command_id = apply.command_id, ok = true })
    w.event({ type = "departure_observed", trip_id = trip.trip_id, ref = "o1" })
    w.event({ type = "arrival_observed", trip_id = trip.trip_id, ref = "o2" })
    assert(trip.state == "ARRIVAL_OBSERVED", trip.state)
  end,

  test_a_departure_the_timetable_hands_out_again_does_not_make_a_second_trip = function()
    local w = world()
    w.tick(60)
    assert(#w.engine.trips() == 1)
    local snap = w.tt.snapshot()
    snap.issued, snap.cursors = {}, {}
    w.tt.restore(snap)
    w.engine.tick()
    assert(#w.engine.trips() == 1 and w.engine.queue_size() == 0, "the trip with this key exists already")
  end,

  test_a_freight_trip_leaves_only_when_the_cargo_rule_is_met_by_proven_goods = function()
    local w = world({ freight = true })
    local ok = w.engine.create_cargo_order({ id = "FR-1", cargo_type = "item", unit = "stack", target_qty = 1000, min_load = 600, departure_rule = "MIN_PARTIAL", proof_mode = "AUTO_INVENTORY",
      source = "MINE", destination = "HUB", origin = "NORD", goal = "SUED", route_id = "R-NS", direction = "EAST", train_class = "FREIGHT" })
    assert(ok)
    w.tick(1)
    local trip = w.engine.trip_for_order("FR-1")
    assert(trip, "a freight order makes a trip")
    w.event({ type = "station_train", train_id = "FREIGHT-1", station = "NORD", present = true })
    w.tick(1)
    local request = w.last("route_request")
    w.event({ type = "route_committed", trip_id = request.trip_id, commit_index = 12 })
    w.event({ type = "route_eligible", trip_id = request.trip_id })
    w.tick(1)
    assert(w.last("apply_schedule") == nil, "nothing is proven loaded: no departure")
    assert(trip.state == "ACTUATOR_ELIGIBLE" and trip.hold_reason:find("minimum", 1, true), tostring(trip.hold_reason))
    w.event({ type = "cargo", order_id = "FR-1", shipment_id = "S1", kind = "loaded", qty = 700, quality = "AUTO_INVENTORY", ref = "inv-1" })
    w.tick(1)
    assert(w.last("apply_schedule") and w.last("apply_schedule").trip_id == trip.trip_id, "700 proven, 600 needed: it leaves")
    w.event({ type = "cargo", order_id = "FR-1", shipment_id = "S1", kind = "unloaded", qty = 650, quality = "AUTO_INVENTORY", ref = "inv-2" })
    local s = w.engine.cargo_summary("FR-1")
    assert(s.delivered == 650 and s.open == 350 and s.in_transit_or_unresolved == 50)
  end,

  test_a_loading_point_that_measured_books_the_quantity_on_the_trip_of_that_train_and_nothing_else = function()
    local w = world({ freight = true })
    assert(w.engine.create_cargo_order({ id = "FR-1", cargo_type = "item", unit = "stack", target_qty = 1000, min_load = 600, departure_rule = "MIN_PARTIAL", proof_mode = "AUTO_INVENTORY",
      source = "MINE", destination = "HUB", origin = "NORD", goal = "SUED", route_id = "R-NS", direction = "EAST", train_class = "FREIGHT" }))
    w.tick(1)
    local trip = w.engine.trip_for_order("FR-1")
    w.event({ type = "station_train", train_id = "FREIGHT-1", station = "NORD", present = true })
    -- the loading point measured 700 stacks for the train FREIGHT-1
    local ok = w.engine.cargo_measure({ type = "cargo_measure", station = "NORD", platform = "P1", train_id = "FREIGHT-1", kind = "loaded", qty = 700, quality = "AUTO_INVENTORY", ref = "NORD/P1#1" })
    assert(ok == true)
    assert(w.engine.cargo_summary("FR-1").loaded == 700)
    assert(w.engine.cargo_measure({ station = "NORD", train_id = "FREIGHT-1", kind = "loaded", qty = 700, quality = "AUTO_INVENTORY", ref = "NORD/P1#1" }) == true, "the same report twice")
    assert(w.engine.cargo_summary("FR-1").loaded == 700, "is booked once")
    -- through the event door as the node sends it
    w.event({ type = "cargo_measure", station = "SUED", platform = "P1", train_id = "FREIGHT-1", kind = "unloaded", qty = 650, quality = "AUTO_INVENTORY", ref = "SUED/P1#1" })
    local summary = w.engine.cargo_summary("FR-1")
    assert(summary.delivered == 650 and summary.in_transit_or_unresolved == 50 and summary.open == 350)
    assert(trip.trip_id and w.engine.report().cargo["FR-1"].unresolved == 50)
  end,

  test_a_measurement_of_a_train_without_cargo_or_a_failed_one_books_nothing = function()
    local w = world({ freight = true })
    assert(w.engine.create_cargo_order({ id = "FR-1", cargo_type = "item", unit = "stack", target_qty = 100, departure_rule = "FULL", proof_mode = "AUTO_INVENTORY",
      source = "MINE", destination = "HUB", origin = "NORD", goal = "SUED", route_id = "R-NS", direction = "EAST", train_class = "FREIGHT" }))
    w.tick(1)
    local ok, why = w.engine.cargo_measure({ station = "NORD", train_id = "TRAIN-1", kind = "loaded", qty = 50, quality = "AUTO_INVENTORY", ref = "x" })
    assert(ok == false and why:find("no trip with cargo", 1, true) and #w.engine.unmatched_measures() == 1)
    local failed_ok, reason = w.engine.cargo_measure({ station = "NORD", train_id = "FREIGHT-1", kind = "loaded", failed = true, reason = "inventory chest_0 cannot be read" })
    assert(failed_ok == false and reason:find("Ladestelle NORD", 1, true))
    local trip = w.engine.trip_for_order("FR-1")
    assert(trip.hold_reason:find("cannot be read", 1, true))
    assert(w.engine.cargo_summary("FR-1").loaded == 0, "no fabricated loading status")
    assert(w.engine.cargo_measure({ station = "NORD", train_id = "FREIGHT-1", kind = "loaded", qty = 0, quality = "AUTO_INVENTORY", ref = "z" }) == true and w.engine.cargo_summary("FR-1").loaded == 0, "nothing moved: nothing booked")
    -- a quality below what the order asks for is not booked either
    local low_ok, low_why = w.engine.cargo_measure({ station = "NORD", train_id = "FREIGHT-1", kind = "loaded", qty = 10, quality = "MANUAL_AUTH", ref = "m", by = "ED" })
    assert(low_ok == false and low_why:find("lower than", 1, true) and w.engine.cargo_summary("FR-1").loaded == 0)
  end,

  test_a_depot_run_chooses_the_track_asks_for_the_route_of_that_track_and_goes_through_the_normal_chain = function()
    local depots = {
      DEP1 = { tracks = { { id = "T1", block = "BD1", length = 8, confirmed = true, preferred = 1, routes = { NORD = "R-D1T1" } }, { id = "T2", block = "BD2", length = 12, confirmed = true, preferred = 2, routes = { NORD = "R-D1T2" } } } }
    }
    local w = world({ depots = depots })
    w.free_blocks = { BD1 = true, BD2 = true }
    local ok, trip_id = w.engine.request_depot({ train_id = "TRAIN-1", origin = "NORD", depot = "DEP1", requested_by = "PANEL-1" })
    assert(ok and trip_id)
    w.tick(1)
    w.event({ type = "station_train", train_id = "TRAIN-1", station = "NORD", present = true })
    w.tick(1)
    local request = w.last("route_request")
    assert(request and request.trip_id == trip_id and request.route_id == "R-D1T1" and request.platform == "T1" and request.platform_block == "BD1", request and tostring(request.route_id))
    local trip = w.engine.trip(trip_id)
    assert(trip.goal == "DEP1" and trip.goal_kind == "depot")
    -- only after both masters: the schedule goes to the station the train stands at, with the depot as destination
    w.event({ type = "route_committed", trip_id = trip_id, commit_index = 5 })
    w.event({ type = "route_eligible", trip_id = trip_id })
    w.tick(1)
    local apply = w.last("apply_schedule")
    assert(apply and apply.station == "NORD" and apply.destination == "DEP1" and apply.platform == "T1" and apply.route_id == "R-D1T1")
  end,

  test_a_track_that_is_taken_gives_way_to_the_next_and_a_full_depot_to_another_depot = function()
    local depots = {
      DEP1 = { tracks = { { id = "T1", block = "BD1", length = 8, confirmed = true, routes = { NORD = "R-D1T1" } } } },
      DEP2 = { tracks = { { id = "T1", block = "BE1", length = 8, confirmed = true, routes = { NORD = "R-D2T1" } } } }
    }
    local w = world({ depots = depots })
    w.free_blocks = { BD1 = false, BE1 = true }
    local ok, trip_id = w.engine.request_depot({ train_id = "TRAIN-1", origin = "NORD", depot = "DEP1" })
    w.tick(1)
    w.event({ type = "station_train", train_id = "TRAIN-1", station = "NORD", present = true })
    w.tick(1)
    local request = w.last("route_request")
    assert(request and request.route_id == "R-D2T1" and w.engine.trip(trip_id).goal == "DEP2" and w.engine.trip(trip_id).depot_alternative == true and w.engine.trip(trip_id).depot_wanted == "DEP1")
  end,

  test_when_every_depot_is_full_the_train_waits_before_the_station_and_goes_when_a_track_is_free_or_uses_the_approved_circuit = function()
    local depots = { DEP1 = { tracks = { { id = "T1", block = "BD1", length = 8, confirmed = true, routes = { NORD = "R-D1T1" } } } } }
    local w = world({ depots = depots })
    w.free_blocks = { BD1 = false }
    local ok, trip_id = w.engine.request_depot({ train_id = "TRAIN-1", origin = "NORD", depot = "DEP1" })
    w.tick(1)
    w.event({ type = "station_train", train_id = "TRAIN-1", station = "NORD", present = true })
    w.tick(1)
    local trip = w.engine.trip(trip_id)
    assert(trip.state == "WAITING" and trip.hold_reason:find("every depot is full", 1, true) and w.last("route_request") == nil)
    assert(w.last("hold_at_waiting_point") and w.last("hold_at_waiting_point").trip_id == trip_id)
    w.free_blocks.BD1 = true
    w.tick(40)
    assert(w.last("route_request") and w.last("route_request").route_id == "R-D1T1", "a track is free: the run goes on")
    -- with an approved circuit the full depot sends the train round instead
    local circuit = world({ depots = depots, depot_circuit = "R-CIRCUIT" })
    circuit.free_blocks = { BD1 = false }
    local _, circuit_trip = circuit.engine.request_depot({ train_id = "TRAIN-1", origin = "NORD", depot = "DEP1" })
    circuit.tick(1)
    circuit.event({ type = "station_train", train_id = "TRAIN-1", station = "NORD", present = true })
    circuit.tick(1)
    assert(circuit.last("route_request").route_id == "R-CIRCUIT" and circuit.engine.trip(circuit_trip).hold_reason:find("circuit", 1, true))
  end,

  test_a_train_that_fits_no_depot_track_is_a_fault_and_a_track_without_a_route_from_here_too = function()
    local w = world({ depots = { DEP1 = { tracks = { { id = "T1", block = "BD1", length = 3, confirmed = true, routes = { NORD = "R" } } } } } })
    w.free_blocks = { BD1 = true }
    local _, trip_id = w.engine.request_depot({ train_id = "TRAIN-1", origin = "NORD", depot = "DEP1" })
    w.tick(1)
    w.event({ type = "station_train", train_id = "TRAIN-1", station = "NORD", present = true })
    w.tick(1)
    assert(w.engine.trip(trip_id).state == "FAULT" and w.engine.trip(trip_id).hold_reason:find("no track in any depot fits", 1, true))
    local nowhere = world({ depots = { DEP1 = { tracks = { { id = "T1", block = "BD1", length = 12, confirmed = true, routes = { ELSEWHERE = "R" } } } } } })
    nowhere.free_blocks = { BD1 = true }
    local _, other = nowhere.engine.request_depot({ train_id = "TRAIN-1", origin = "NORD", depot = "DEP1" })
    nowhere.tick(1)
    nowhere.event({ type = "station_train", train_id = "TRAIN-1", station = "NORD", present = true })
    nowhere.tick(1)
    assert(nowhere.engine.trip(other).state == "FAULT")
  end,

  test_a_depot_run_needs_a_known_depot_and_names_what_is_missing = function()
    local w = world({ depots = { DEP1 = { tracks = {} } } })
    assert(not w.engine.request_depot({ train_id = "TRAIN-1", origin = "NORD", depot = "NOPE" }))
    assert(not w.engine.request_depot({ origin = "NORD", depot = "DEP1" }))
    assert(not w.engine.request_depot(nil))
  end,

  test_a_depot_run_starts_where_the_train_was_seen_and_is_refused_for_a_train_nobody_has_seen = function()
    local depots = { DEP1 = { tracks = { { id = "T1", block = "BD1", length = 12, confirmed = true, routes = { NORD = "R-D1T1" } } } } }
    local w = world({ depots = depots })
    w.free_blocks = { BD1 = true }
    local ok, err = w.engine.request_depot({ train_id = "TRAIN-1", depot = "DEP1" })
    assert(ok == false and err:find("not known", 1, true))
    w.event({ type = "station_train", train_id = "TRAIN-1", station = "NORD", present = true })
    assert(w.engine.station_of("TRAIN-1") == "NORD")
    local ok2, trip_id = w.engine.request_depot({ train_id = "TRAIN-1", depot = "DEP1" })
    assert(ok2 and w.engine.trip(trip_id).origin == "NORD")
    w.event({ type = "station_train", train_id = "TRAIN-1", station = "NORD", present = false })
    assert(w.engine.station_of("TRAIN-1") == nil, "a train that left is no longer 'at' the station")
    local report = w.engine.report()
    assert(report.depots[1] == "DEP1" and report.trains[1] == "TRAIN-1")
  end
}
