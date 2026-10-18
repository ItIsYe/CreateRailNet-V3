--[[
Purpose: The interlocking (Stellwerk) is part of every reservation: routes reach SET, signals need them, flank protection
  and overlap are enforced, and a restart rebuilds locks and routes.
Public API: returns table of tests.
]]

pcall(dofile, "tests/harness/cc_bootstrap.lua")

local dispatcher = require("src.master.dispatcher")
local interlocking = require("src.domain.interlocking")
local switch_locks = require("src.domain.switch_locks")
local validate = require("src.shared.validate")

local function cfg()
  return {
    sensor_guard_min_occupy_ms = 0,
    blocks = {
      { id = "B1", entry_signal = "SE1", exit_signal = "SX1", sensors = { "SEN-1" }, switches = { { id = "SW-1", position = "STRAIGHT" } } },
      { id = "B2", entry_signal = "SE2", exit_signal = "SX2", sensors = { "SEN-2" }, switches = {} },
      { id = "B3", entry_signal = "SE3", exit_signal = "SX3", sensors = { "SEN-3" }, switches = {} },
      { id = "B4", entry_signal = "SE4", exit_signal = "SX4", sensors = { "SEN-4" }, switches = {} },
      { id = "O1", entry_signal = "SEO", exit_signal = "SXO", sensors = { "SEN-O" }, switches = {} }
    },
    routes = {
      { id = "R-12", from = "A", to = "B", blocks = { "B1", "B2" } },
      { id = "R-3", from = "C", to = "D", blocks = { "B3" } },
      { id = "R-4", from = "E", to = "F", blocks = { "B4" } },
      { id = "R-O", from = "G", to = "H", blocks = { "O1" } }
    },
    interlocking_routes = {
      { id = "R-3", flank_protection = { { switch_id = "SW-F", position = "STRAIGHT" } }, overlap_block = "O1" },
      { id = "R-4", flank_protection = { { switch_id = "SW-F", position = "DIVERGING" } } }
    }
  }
end

local function adapters()
  local a = { aspects = {}, positions = {} }
  a.signals = { setAspect = function(id, aspect) a.aspects[id] = aspect; return true end }
  a.switches = { setPosition = function(id, position) a.positions[id] = position; return true end }
  return a
end

local function enter(d, n) return d.on_sensor_event_by_sensor("SEN-" .. n, "enter") end
local function leave(d, n) return d.on_sensor_event_by_sensor("SEN-" .. n, "leave") end

return {
  test_reserved_route_reaches_set_and_owns_signals = function()
    local a = adapters()
    local d = dispatcher.new(cfg(), a)
    assert(d.get_interlocking()["R-12"].status == "VACANT")
    assert(d.reserve_route("T1", "R-12"))
    local status = d.get_interlocking()["R-12"]
    assert(status.status == "SET", status.status)
    assert(status.owner == "T1:R-12" and status.train_id == "T1")
    assert(a.aspects.SE1 == "GREEN" or a.aspects.SE1 == "YELLOW", tostring(a.aspects.SE1))
    -- the manual path agrees with the dispatcher on the same signal
    assert(d.set_signal("SE1", "GREEN"))
    -- the block behind SE2 is reserved too, but it is not the next one: SE2 stays with the dispatcher's own progress
    assert(d.get_overview()["B1"].interlocking_route == "R-12")
  end,

  test_manual_proceed_without_route_is_refused = function()
    local d = dispatcher.new(cfg(), adapters())
    local ok, err = d.set_signal("SE1", "GREEN")
    assert(ok == false and string.find(err, "SICHERHEIT"), tostring(err))
    assert(d.set_signal("SE1", "RED"))
  end,

  test_manual_proceed_refused_for_cleared_or_faulted_blocks = function()
    local d = dispatcher.new(cfg(), adapters())
    assert(d.reserve_route("T1", "R-12"))
    assert(enter(d, 1) and leave(d, 1))
    -- B1 is behind the train now, B2 is ahead
    assert(d.set_signal("SE2", "GREEN"))
    local ok = d.set_signal("SE1", "GREEN")
    assert(ok == false, "signal of a cleared block must not go green")
    d.timeout_node("SE2")
    ok = d.set_signal("SE2", "GREEN")
    assert(ok == false, "signal of a FAULT block must not go green")
  end,

  test_route_follows_the_train_to_vacant = function()
    local d = dispatcher.new(cfg(), adapters())
    assert(d.reserve_route("T1", "R-12"))
    assert(enter(d, 1))
    assert(d.get_interlocking()["R-12"].status == "OCCUPIED")
    assert(leave(d, 1))
    assert(d.get_interlocking()["R-12"].status == "DISSOLVING")
    assert(d.get_interlocking()["R-12"].cleared.B1)
    assert(enter(d, 2))
    assert(d.get_interlocking()["R-12"].status == "DISSOLVING", "a later block is no new occupation")
    assert(leave(d, 2))
    assert(d.get_interlocking()["R-12"].status == "VACANT")
    assert(next(d.get_switch_locks()) == nil, "locks are released with the route")
    -- the same route can be set again
    assert(d.reserve_route("T2", "R-12"))
  end,

  test_release_route_dissolves_interlocking = function()
    local d = dispatcher.new(cfg(), adapters())
    assert(d.reserve_route("T1", "R-12"))
    assert(d.release_route("T1", "R-12"))
    assert(d.get_interlocking()["R-12"].status == "VACANT")
    assert(d.reserve_route("T2", "R-12"))
  end,

  test_missed_leave_still_dissolves_on_finish = function()
    local d = dispatcher.new(cfg(), adapters())
    assert(d.reserve_route("T1", "R-12"))
    assert(enter(d, 1))
    assert(d.release_route("T1", "R-12"))
    assert(d.get_interlocking()["R-12"].status == "VACANT")
  end,

  test_cancel_with_foreign_owner_is_refused = function()
    local d = dispatcher.new(cfg(), adapters())
    assert(d.reserve_route("T1", "R-12"))
    local ok, err = d.interlocking.cancel_route("R-12", "T9:R-12")
    assert(ok == false and string.find(err, "belongs to"), tostring(err))
    assert(d.get_interlocking()["R-12"].status == "SET")
    local ok2 = d.interlocking.enter_route("R-12", "T9:R-12")
    assert(ok2 == false)
    assert(d.get_interlocking()["R-12"].status == "SET")
  end,

  test_flank_protection_is_locked_and_set = function()
    local a = adapters()
    local d = dispatcher.new(cfg(), a)
    assert(d.reserve_route("T1", "R-3"))
    assert(a.positions["SW-F"] == "STRAIGHT", "flank switch was not set")
    local locks = d.get_switch_locks()
    assert(locks["SW-F"] and locks["SW-F"].owner == "T1:R-3:flank", tostring(locks["SW-F"] and locks["SW-F"].owner))
  end,

  test_flank_conflict_refuses_and_leaves_nothing_behind = function()
    local a = adapters()
    local d = dispatcher.new(cfg(), a)
    assert(d.reserve_route("T1", "R-3"))
    local ok, err = d.reserve_route("T2", "R-4")
    assert(ok == false and string.find(err, "flank"), tostring(err))
    assert(d.get_block("B4").state == dispatcher.STATES.FREE)
    assert(d.get_interlocking()["R-4"].status == "VACANT")
    assert(a.aspects.SE4 ~= "GREEN" and a.aspects.SE4 ~= "YELLOW")
    local locks = d.get_switch_locks()
    for _, lock in pairs(locks) do assert(string.sub(lock.owner, 1, 5) == "T1:R-", "foreign lock left: " .. lock.owner) end
    -- it is queued like any other conflict and goes through once T1 is done
    local queued_ok, status = d.request_route("T2", "R-4")
    assert(queued_ok == false and status == "queued")
    assert(enter(d, 3) and leave(d, 3))
    assert(d.get_trains()["T2"].state == dispatcher.TRAIN_STATES.RESERVED, d.get_trains()["T2"].state)
    assert(a.positions["SW-F"] == "DIVERGING")
  end,

  test_flank_locks_are_released_with_the_route = function()
    local d = dispatcher.new(cfg(), adapters())
    assert(d.reserve_route("T1", "R-3"))
    assert(enter(d, 3) and leave(d, 3))
    assert(next(d.get_switch_locks()) == nil)
  end,

  test_overlap_block_is_kept_for_the_train = function()
    local a = adapters()
    local d = dispatcher.new(cfg(), a)
    assert(d.reserve_route("T1", "R-3"))
    local ov = d.get_block("O1")
    assert(ov.state == dispatcher.STATES.RESERVED and ov.reserved_by == "T1", tostring(ov.state))
    assert(a.aspects.SEO == "RED" and a.aspects.SXO == "RED")
    -- nobody else gets it, not even as a block of another route
    local ok, err = d.reserve_route("T2", "R-O")
    assert(ok == false and err, "overlap block was handed out")
    assert(not d.set_signal("SEO", "GREEN"), "no proceed on an overlap signal")
    -- done: the overlap is free again
    assert(enter(d, 3) and leave(d, 3))
    assert(d.get_block("O1").state == dispatcher.STATES.FREE)
    assert(d.get_block("O1").overlap_for == nil)
    assert(d.reserve_route("T2", "R-O"))
  end,

  test_route_is_refused_while_overlap_is_taken = function()
    local d = dispatcher.new(cfg(), adapters())
    assert(d.reserve_route("T2", "R-O"))
    local ok, err = d.reserve_route("T1", "R-3")
    assert(ok == false and string.find(err, "overlap"), tostring(err))
    assert(d.get_block("B3").state == dispatcher.STATES.FREE)
    assert(d.get_interlocking()["R-3"].status == "VACANT")
  end,

  test_entering_the_overlap_faults_it = function()
    local d = dispatcher.new(cfg(), adapters())
    assert(d.reserve_route("T1", "R-3"))
    assert(enter(d, 3))
    local ok, err = d.on_sensor_event_by_sensor("SEN-O", "enter")
    assert(ok == false and string.find(err, "overlap"), tostring(err))
    assert(d.get_block("O1").state == dispatcher.STATES.FAULT)
    -- the route finishes normally, the faulted overlap stays for the operator
    assert(leave(d, 3))
    assert(d.get_block("O1").state == dispatcher.STATES.FAULT)
    assert(d.clear_fault("O1"))
  end,

  test_restore_rebuilds_locks_and_routes = function()
    local a = adapters()
    local d = dispatcher.new(cfg(), a)
    assert(d.reserve_route("T1", "R-12"))
    assert(d.reserve_route("T2", "R-3"))
    assert(enter(d, 1))
    local snap = d.snapshot()

    local a2 = adapters()
    local d2 = dispatcher.new(cfg(), a2)
    assert(d2.restore(snap))
    local locks = d2.get_switch_locks()
    assert(locks["SW-1"] and locks["SW-1"].owner == "T1:R-12", "switch lock of the running train is back")
    assert(locks["SW-F"] and locks["SW-F"].owner == "T2:R-3:flank", "flank lock is back")
    local il = d2.get_interlocking()
    assert(il["R-12"].status == "OCCUPIED", il["R-12"].status)
    assert(il["R-3"].status == "SET", il["R-3"].status)
    assert(d2.get_block("O1").overlap_for == "R-3" and d2.get_block("O1").state == dispatcher.STATES.RESERVED)
    -- the restarted dispatcher still protects the route: nobody else can take the blocks or the switch
    local ok = d2.reserve_route("T3", "R-4")
    assert(ok == false)
    -- and the waiting train gets its signal back
    assert(a2.aspects.SE3 == "GREEN" or a2.aspects.SE3 == "YELLOW", tostring(a2.aspects.SE3))
    -- the train goes on as if nothing happened
    assert(leave(d2, 1))
    assert(d2.get_interlocking()["R-12"].status == "DISSOLVING")
    assert(a2.aspects.SE2 == "GREEN" or a2.aspects.SE2 == "YELLOW", tostring(a2.aspects.SE2))
    assert(enter(d2, 2) and leave(d2, 2))
    assert(d2.get_interlocking()["R-12"].status == "VACANT")
  end,

  test_restore_keeps_progress_of_a_train_between_blocks = function()
    local d = dispatcher.new(cfg(), adapters())
    assert(d.reserve_route("T1", "R-12"))
    assert(enter(d, 1) and leave(d, 1))
    local a2 = adapters()
    local d2 = dispatcher.new(cfg(), a2)
    assert(d2.restore(d.snapshot()))
    local status = d2.get_interlocking()["R-12"]
    assert(status.status == "DISSOLVING" and status.cleared.B1, status.status)
    assert(not d2.set_signal("SE1", "GREEN"), "the block behind the train stays closed")
    assert(d2.set_signal("SE2", "GREEN"))
  end,

  test_restore_twice_does_not_stack_locks = function()
    local d = dispatcher.new(cfg(), adapters())
    assert(d.reserve_route("T1", "R-12"))
    local snap = d.snapshot()
    assert(d.restore(snap) and d.restore(snap))
    assert(d.release_route("T1", "R-12"))
    assert(next(d.get_switch_locks()) == nil)
    assert(d.get_interlocking()["R-12"].status == "VACANT")
  end,

  test_restore_with_contradicting_snapshot_fails_closed = function()
    local d = dispatcher.new(cfg(), adapters())
    assert(d.reserve_route("T1", "R-3"))
    local snap = d.snapshot()
    -- the flank switch of R-4 and R-3 contradict: a hand-edited snapshot claims both trains are on their way
    snap.trains["T2"] = { id = "T2", route = "R-4", state = "RESERVED", route_index = 1 }
    snap.blocks["B4"] = { id = "B4", state = "RESERVED", reserved_by = "T2" }
    local a2 = adapters()
    local d2 = dispatcher.new(cfg(), a2)
    assert(d2.restore(snap))
    assert(d2.get_trains()["T2"].state == dispatcher.TRAIN_STATES.FAULT)
    assert(d2.get_block("B4").state == dispatcher.STATES.FAULT)
    assert(a2.aspects.SE4 ~= "GREEN" and a2.aspects.SE4 ~= "YELLOW")
    assert(d2.get_interlocking()["R-4"].status == "VACANT")
  end,

  test_faulted_train_keeps_route_until_released = function()
    local d = dispatcher.new(cfg(), adapters())
    assert(d.reserve_route("T1", "R-12"))
    d.timeout_node("SEN-1")
    assert(d.get_trains()["T1"].state == dispatcher.TRAIN_STATES.FAULT)
    assert(d.get_interlocking()["R-12"].status == "SET", "a timed-out train may still be on the track")
    local ok = d.reserve_route("T2", "R-12")
    assert(ok == false)
    assert(d.release_route("T1", "R-12"))
    assert(d.get_interlocking()["R-12"].status == "VACANT")
  end,

  test_restore_keeps_route_of_faulted_train = function()
    local d = dispatcher.new(cfg(), adapters())
    assert(d.reserve_route("T1", "R-12"))
    d.timeout_node("SEN-1")
    local d2 = dispatcher.new(cfg(), adapters())
    assert(d2.restore(d.snapshot()))
    assert(d2.get_interlocking()["R-12"].status == "SET")
    assert(d2.get_switch_locks()["SW-1"], "a timed-out train keeps its switch lock across a restart")
  end,

  test_derived_fields_come_from_the_blocks = function()
    local il = interlocking.new(cfg(), nil, nil)
    local route = il.get_route("R-12")
    assert(route.entry_signal == "SE1" and route.exit_signal == "SX2")
    assert(#route.switches == 1 and route.switches[1].id == "SW-1" and route.switches[1].position == "STRAIGHT")
    assert(route.signal_blocks.SE1[1] == "B1" and route.signal_blocks.SE2[1] == "B2")
    assert(il.get_route("R-3").overlap_block == "O1", "explicit fields overlay the derived ones")
  end,

  test_standalone_interlocking_still_works = function()
    local blocks = { Z1 = { id = "Z1", state = "FREE" }, Z2 = { id = "Z2", state = "FREE" } }
    local locks = switch_locks.new()
    local il = interlocking.new({
      interlocking_routes = {
        { id = "X", entry_signal = "S1", exit_signal = "S2", blocks = { "Z1" }, switches = { { id = "W", position = "STRAIGHT" } } },
        { id = "Y", entry_signal = "S3", exit_signal = "S4", blocks = { "Z2" }, switches = { { id = "W", position = "DIVERGING" } } }
      }
    }, locks, blocks)
    assert(not il.is_signal_green_allowed("S1"))
    assert(il.set_route("X"))
    assert(il.is_signal_green_allowed("S1"))
    local ok, err = il.set_route("Y")
    assert(ok == false and string.find(err, "switch"), tostring(err))
    blocks.Z1.state = "OCCUPIED"
    il.cancel_route("X")
    ok, err = il.set_route("X")
    assert(ok == false and string.find(err, "block occupied"), tostring(err))
    assert(next(locks.list()) == nil)
  end,

  test_validate_accepts_overlay_entries_without_signal = function()
    local _, errors = validate.validate_config(cfg())
    for _, e in ipairs(errors or {}) do assert(not string.find(e, "interlocking_routes", 1, true), "unexpected: " .. e) end
  end,

  test_validate_flags_bad_overlap_and_unknown_standalone = function()
    local c = cfg()
    c.interlocking_routes[1].overlap_block = "NOPE"
    c.interlocking_routes[2].overlap_block = "B4"
    c.interlocking_routes[#c.interlocking_routes + 1] = { id = "ALONE" }
    local _, errors = validate.validate_config(c)
    local joined = table.concat(errors or {}, "\n")
    assert(string.find(joined, "interlocking_routes[1].overlap_block", 1, true), joined)
    assert(string.find(joined, "interlocking_routes[2].overlap_block", 1, true), joined)
    assert(string.find(joined, "interlocking_routes[3].entry_signal", 1, true), joined)
  end
}
