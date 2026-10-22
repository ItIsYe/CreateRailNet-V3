--[[
Purpose: The master side of the fleet: a route request of a fleet node becomes a reservation, the fleet hears what became of it from the state of the dispatcher (committed, eligible, departure, position, arrival, tail clearance), and nothing is trusted from a stranger (Gesamtkonzept Kap. 2.1, 24.1).
Public API: returns table of tests.
]]

local dispatcher_module = require("src.master.dispatcher")
local fleet_bridge = require("src.master.fleet_bridge")

local quiet = { info = function() end, warn = function() end, error = function() end, debug = function() end }

local function plan(proof)
  return {
    occupancy_proof = proof, sensor_guard_min_occupy_ms = 0,
    nodes = { { id = "MASTER-1", role = "master" }, { id = "FLEET-A", role = "fleet" }, { id = "FLEET-B", role = "fleet" }, { id = "SEN-1", role = "sensor" } },
    fleet = { pairs = { { id = "P1", nodes = { "FLEET-A", "FLEET-B" }, trains = { "TRAIN-1" } } } },
    blocks = {
      { id = "B1", entry_signal = "S1", exit_signal = "X1", sensors = { "SEN-1" } },
      { id = "B2", entry_signal = "S2", exit_signal = "X2", sensors = { "SEN-2" } },
      { id = "BP1", entry_signal = "S3", exit_signal = "X3", sensors = { "SEN-3" } }
    },
    routes = { { id = "R-NS", from = "NORD", to = "SUED", blocks = { "B1", "B2", "BP1" } } },
    safe_stops = { { block = "BP1", length = 12, proven = true } }
  }
end

local function world(proof)
  local cfg = plan(proof)
  local sent = {}
  local network = {
    send_reliable = function(kind, dst, payload) sent[#sent + 1] = { kind = kind, dst = dst, payload = payload }; return { id = "m" .. #sent } end,
    ack_for = function() end
  }
  local aspects = {}
  local d = dispatcher_module.new(cfg, { signals = { setAspect = function(id, a) aspects[id] = a; return true end }, switches = { setPosition = function() return true end } })
  local clock = { t = 0 }
  local bridge = fleet_bridge.new({ dispatcher = d, network = network, config = cfg, logger = quiet, now = function() return clock.t end, train_length = function(id) return id == "TRAIN-1" and 6 or nil end })
  local w = { cfg = cfg, d = d, bridge = bridge, sent = sent, clock = clock, aspects = aspects }
  function w.events(kind)
    local out = {}
    for _, m in ipairs(sent) do
      if m.payload.type == "fleet_event" and m.payload.ev.type == kind then out[#out + 1] = m end
    end
    return out
  end
  function w.route(extra)
    local payload = { type = "fleet_route", trip_id = "T1", leg_id = "T1/L1", command_id = "T1/C1", train_id = "TRAIN-1", route_id = "R-NS", platform_block = "BP1", fleet_pair = "P1" }
    for k, v in pairs(extra or {}) do payload[k] = v end
    return bridge.handle({ src = "FLEET-A", id = "msg-" .. #sent, type = "event", payload = payload })
  end
  return w
end

local function prove_all(w)
  for _, id in ipairs({ "B1", "B2", "BP1" }) do assert(w.d.observe_block(id, "FREE_PROVEN", "observer", { at = 1 })) end
end

return {
  test_a_route_request_of_a_fleet_node_reserves_the_route_and_the_answer_names_the_trip = function()
    local w = world(); 
    assert(w.route() == true)
    assert(w.d.get_block("B1").reserved_by == "TRAIN-1" and w.d.get_trains()["TRAIN-1"].route == "R-NS")
    w.bridge.poll()
    local committed = w.events("route_committed")
    assert(#committed == 2 and committed[1].payload.ev.trip_id == "T1", "both fleet nodes of the pair hear it")
    assert(committed[1].dst ~= committed[2].dst)
    assert(#w.events("route_eligible") == 2)
    w.bridge.poll()
    assert(#w.events("route_committed") == 2, "said once")
  end,

  test_the_length_of_the_train_goes_to_the_reservation_and_a_stop_that_is_too_short_refuses = function()
    local w = world("on"); prove_all(w)
    assert(w.route() == true)
    assert(w.d.get_trains()["TRAIN-1"].length == 6)
    local short = world("on")
    short.d.get_graph().stops.BP1.length = 4
    prove_all(short)
    short.route()
    local refused = short.events("route_refused")
    assert(#refused == 2 and refused[1].payload.ev.reason:find("too long", 1, true), refused[1] and refused[1].payload.ev.reason)
    assert(short.d.get_trains()["TRAIN-1"] == nil)
  end,

  test_a_refused_reservation_is_told_with_the_reason_and_nothing_stays_queued = function()
    local w = world("on")      -- nothing proven free
    assert(w.route() == true)
    local refused = w.events("route_refused")
    assert(#refused == 2 and refused[1].payload.ev.reason:find("UNKNOWN", 1, true) and refused[1].payload.ev.trip_id == "T1", refused[1] and refused[1].payload.ev.reason)
    assert(#w.d.get_queue() == 0, "the dispatcher keeps no request of the fleet: the fleet asks again")
    assert(w.d.get_block("B1").state == "FREE")
  end,

  test_the_same_command_twice_is_answered_again_and_reserves_once = function()
    local w = world()
    w.route(); w.bridge.poll()
    local before = #w.sent
    w.route()
    assert(w.d.get_trains()["TRAIN-1"].route == "R-NS")
    assert(#w.sent > before, "the answer is repeated for a request that came again")
    local count = 0
    for _, m in ipairs(w.sent) do if m.payload.ev and m.payload.ev.type == "route_refused" then count = count + 1 end end
    assert(count == 0, "no refusal for the repeat of an accepted request")
  end,

  test_only_a_fleet_node_of_the_plan_may_ask = function()
    local w = world()
    local handled = w.bridge.handle({ src = "SEN-1", id = "x", type = "event", payload = { type = "fleet_route", trip_id = "T9", train_id = "TRAIN-1", route_id = "R-NS", command_id = "C9" } })
    assert(handled == true, "taken in, so the sender does not retry")
    assert(w.d.get_trains()["TRAIN-1"] == nil and #w.sent == 0, "but nothing was reserved and nobody was told")
    local stranger = w.bridge.handle({ src = "NOBODY", id = "y", type = "event", payload = { type = "fleet_route", trip_id = "T9", train_id = "TRAIN-1", route_id = "R-NS", command_id = "C9" } })
    assert(stranger == true and w.d.get_trains()["TRAIN-1"] == nil)
  end,

  test_a_train_the_pair_does_not_own_is_refused = function()
    local w = world()
    w.route({ train_id = "TRAIN-9" })
    local refused = w.events("route_refused")
    assert(#refused >= 1 and refused[1].payload.ev.reason:find("pair", 1, true), refused[1] and refused[1].payload.ev.reason)
    assert(w.d.get_trains()["TRAIN-9"] == nil)
  end,

  test_the_movement_of_the_train_is_reported_as_observations_from_the_dispatcher = function()
    local w = world()
    w.route(); w.bridge.poll()
    assert(w.d.on_sensor_event("B1", "enter", "SEN-1"))
    w.bridge.poll()
    local departure = w.events("departure_observed")
    assert(#departure == 2 and departure[1].payload.ev.ref, "the first block was entered")
    local positions = w.events("position")
    assert(positions[#positions].payload.ev.block == "B1" and positions[#positions].payload.ev.observed == true)
    assert(w.d.on_sensor_event("B1", "leave", "SEN-1"))
    assert(w.d.on_sensor_event("B2", "enter", "SEN-2"))
    assert(w.d.on_sensor_event("B2", "leave", "SEN-2"))
    assert(w.d.on_sensor_event("BP1", "enter", "SEN-3"))
    w.bridge.poll()
    assert(#w.events("arrival_observed") == 2, "the last block of the route was entered")
    assert(w.d.on_sensor_event("BP1", "leave", "SEN-3"))
    w.bridge.poll()
    local tail = w.events("tail_clear")
    assert(#tail == 2, "the route is finished and every block is proven free: " .. #tail)
    assert(#w.events("departure_observed") == 2, "not repeated")
  end,

  test_the_tail_of_a_train_is_not_cleared_while_a_block_is_not_proven_free = function()
    local w = world("on"); prove_all(w)
    w.route(); w.bridge.poll()
    for _, step in ipairs({ { "B1", "SEN-1" }, { "B2", "SEN-2" }, { "BP1", "SEN-3" } }) do
      assert(w.d.on_sensor_event(step[1], "enter", step[2]))
      w.bridge.poll()
      if step[1] ~= "BP1" then assert(w.d.on_sensor_event(step[1], "leave", step[2])) end
    end
    w.d.release_route("TRAIN-1", "R-NS")   -- the route is released while the train still stands in BP1
    w.bridge.poll()
    assert(#w.events("tail_clear") == 0, "BP1 is not proven free: no clearance")
    assert(w.d.on_sensor_event("BP1", "leave", "SEN-3"))
    w.bridge.poll()
    assert(#w.events("tail_clear") == 2)
  end,

  test_a_release_of_the_fleet_frees_the_route_only_through_the_dispatcher = function()
    local w = world()
    w.route(); w.bridge.poll()
    assert(w.bridge.handle({ src = "FLEET-A", id = "r", type = "event", payload = { type = "fleet_release", trip_id = "T1", train_id = "TRAIN-1", leg_id = "T1/L1" } }) == true)
    assert(w.d.get_block("B1").state == "FREE" and w.d.get_trains()["TRAIN-1"] == nil)
    -- a train that stands in a block is not freed by a message
    local w2 = world("on"); prove_all(w2)
    w2.route(); w2.bridge.poll()
    assert(w2.d.on_sensor_event("B1", "enter", "SEN-1"))
    w2.bridge.handle({ src = "FLEET-A", id = "r", type = "event", payload = { type = "fleet_release", trip_id = "T1", train_id = "TRAIN-1" } })
    assert(w2.d.get_block("B1").state == "OCCUPIED", "the dispatcher keeps what the train still occupies")
  end,

  test_a_reconstruction_request_is_answered_from_the_state_of_the_dispatcher_not_from_a_guess = function()
    local w = world()
    w.route(); w.bridge.poll()
    assert(w.d.on_sensor_event("B1", "enter", "SEN-1"))
    w.bridge.handle({ src = "FLEET-A", id = "q", type = "event", payload = { type = "fleet_reconstruct", trip_id = "T1", train_id = "TRAIN-1" } })
    local answers = w.events("reconstruction")
    assert(#answers == 2 and answers[1].payload.ev.state == "EN_ROUTE" and answers[1].payload.ev.block == "B1" and answers[1].payload.ev.ref, "the train is in B1")
    local w2 = world()
    w2.bridge.handle({ src = "FLEET-A", id = "q", type = "event", payload = { type = "fleet_reconstruct", trip_id = "T7", train_id = "TRAIN-1" } })
    assert(#w2.events("reconstruction") == 0, "nothing is known about the trip: nothing is claimed")
  end,

  test_the_blocks_that_can_be_reserved_are_reported_to_the_fleet_and_only_proven_ones = function()
    local w = world("on")
    assert(w.d.observe_block("B1", "FREE_PROVEN", "observer", { at = 1 }))
    w.bridge.report_blocks()
    local report = w.sent[#w.sent]
    assert(report.payload.type == "fleet_blocks" and #report.payload.free == 1 and report.payload.free[1] == "B1")
    assert(w.sent[#w.sent - 1].payload.type == "fleet_blocks", "to both nodes")
    local off = world()
    off.bridge.report_blocks()
    assert(#off.sent[#off.sent].payload.free == 3, "without the proof mode the dispatcher's FREE counts")
    local w2 = world("on")
    prove_all(w2); w2.route(); 
    w2.bridge.report_blocks()
    local free = w2.sent[#w2.sent].payload.free
    assert(#free == 0, "reserved blocks are not offered")
  end,

  test_a_train_that_arrives_in_or_leaves_a_station_is_told_to_every_pair = function()
    local w = world()
    w.bridge.on_station_event({ type = "train_arrived_station", train_id = "TRAIN-1", train_name = "Sued 1", platform_id = "N1" }, "NORD")
    local seen = w.events("station_train")
    assert(#seen == 2 and seen[1].payload.ev.station == "NORD" and seen[1].payload.ev.present == true and seen[1].payload.ev.create_name == "Sued 1")
    w.bridge.on_station_event({ type = "train_left_station", train_id = "TRAIN-1", train_name = "Sued 1" }, "NORD")
    local all = w.events("station_train")
    assert(#all == 4 and all[3].payload.ev.present == false)
  end,

  test_nothing_is_told_as_committed_or_eligible_before_both_masters_hold_the_reservation = function()
    local w = world()
    w.d.require_commit(true)
    assert(w.route() == true)
    w.bridge.poll()
    assert(#w.events("route_committed") == 0 and #w.events("route_eligible") == 0, "validated is not committed")
    w.d.set_commit_phase("TRAIN-1", "PREPARED_BOTH_DURABLE")
    w.bridge.poll()
    assert(#w.events("route_committed") == 0 and #w.events("route_eligible") == 0, "prepared is not committed")
    w.d.set_commit_phase("TRAIN-1", "COMMITTED_BOTH_DURABLE")
    w.bridge.poll()
    assert(#w.events("route_committed") == 2 and #w.events("route_eligible") == 2)
  end,

  test_a_reconstruction_for_a_trip_the_bridge_never_saw_is_not_answered_even_if_the_train_is_known = function()
    local w = world()
    assert(w.d.reserve_route("TRAIN-1", "R-NS"))
    assert(w.d.on_sensor_event("B1", "enter", "SEN-1"))
    w.bridge.handle({ src = "FLEET-A", id = "q", type = "event", payload = { type = "fleet_reconstruct", trip_id = "T7", train_id = "TRAIN-1" } })
    assert(#w.events("reconstruction") == 0, "the bridge does not know trip T7: it claims nothing")
  end
}
