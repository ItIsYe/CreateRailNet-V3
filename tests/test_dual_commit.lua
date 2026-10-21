--[[
Purpose: Two real masters with dispatchers, elections, replicas and commit barriers: movement is given only after both masters have the state it depends on, the standby touches no hardware,
  and a failover starts from the committed state (Gesamtkonzept Kap. 5.2, 5.3, 5.4, S-02, S-03, S-06; tests E-02, E-06, E-07, E-08, E-09).
Public API: returns table of tests.
]]

pcall(dofile, "tests/harness/cc_bootstrap.lua")

local cluster_world = require("tests.harness.cluster_world")

local A, B, ARB = cluster_world.A, cluster_world.B, cluster_world.ARB

local function with_cluster(opts, fn)
  local w = cluster_world.new(opts)
  local ok, err = pcall(fn, w)
  w.close()
  if not ok then error(err, 0) end
end

local function count(list, value)
  local n = 0
  for _, item in ipairs(list) do if item == value then n = n + 1 end end
  return n
end

local function authorized(w, train_id) return #w.nodes[train_id].commands("depart_authorized") end

return {
  test_a_cluster_elects_a_leader_and_the_standby_has_the_same_state = function()
    with_cluster({}, function(w)
      w.run(20000)
      assert(w.leader() == A)
      local a, b = w.masters[A], w.masters[B]
      assert(a.replica.committed_idx() >= 1 and a.replica.committed_idx() == b.replica.last_idx())
    end)
  end,

  test_a_route_is_given_after_the_standby_has_it_and_the_standby_touches_no_hardware = function()
    with_cluster({}, function(w)
      w.run(20000)
      w.request("TRAIN-1", "R1")
      w.run(3000)
      local a, b = w.masters[A], w.masters[B]
      assert(count(w.signal_calls(A, "SE1"), "GREEN") >= 1, "the signal of the first block turned green")
      assert(authorized(w, "TRAIN-1") == 1, "the train got its departure")
      local command = w.nodes["TRAIN-1"].commands("depart_authorized")[1]
      assert(command.payload.election_epoch == a.ha.term() and command.payload.election_leader == A and type(command.payload.command_id) == "string")
      assert(b.replica.last_idx() == a.replica.last_idx() and b.replica.committed_idx() == a.replica.committed_idx(), "both hold the same confirmed state")
      assert(#b.hw.calls == 0, "the standby never touched the hardware, it made " .. #b.hw.calls .. " calls")
      assert(b.replica.state().trains and b.replica.state().trains["TRAIN-1"], "but it knows the train")
    end)
  end,

  -- E-02 / R-07: the standby is off: nothing that gives movement leaves the leader
  test_e02_without_the_standby_a_new_route_is_reserved_but_nothing_is_given = function()
    with_cluster({}, function(w)
      w.run(20000)
      w.crash(B)
      w.request("TRAIN-1", "R1")
      w.run(8000)
      local a = w.masters[A]
      assert(a.dispatcher.get_trains()["TRAIN-1"] and a.dispatcher.get_trains()["TRAIN-1"].state == "RESERVED", "the dispatcher of the leader has the reservation")
      assert(count(w.signal_calls(A, "SE1"), "GREEN") == 0, "but the signal stays red: no dual confirmation")
      assert(authorized(w, "TRAIN-1") == 0, "and the train gets no departure")
      assert(a.barrier.count() >= 1, "the movement waits in the barrier")
      -- the standby returns: the waiting actuations go out, in order
      w.restart(B)
      w.run(15000)
      assert(count(w.signal_calls(A, "SE1"), "GREEN") >= 1, "the green comes after the standby confirmed")
      assert(authorized(w, "TRAIN-1") == 1)
      assert(a.barrier.count() == 0)
    end)
  end,

  test_the_switch_is_moved_before_the_signal_turns_green = function()
    with_cluster({}, function(w)
      w.run(20000)
      w.crash(B)
      w.request("TRAIN-1", "R1")
      w.run(3000)
      w.restart(B)
      w.run(15000)
      local order = {}
      for _, call in ipairs(w.masters[A].hw.calls) do
        if call.kind == "switch" or (call.kind == "signal" and call.value == "GREEN") then order[#order + 1] = call.kind .. ":" .. call.id end
      end
      assert(order[1] == "switch:SW-1", "the turnout first, got " .. table.concat(order, ","))
      local first_green
      for i, entry in ipairs(order) do if entry:find("signal", 1, true) then first_green = i; break end end
      assert(first_green and first_green > 1)
    end)
  end,

  test_a_restrictive_command_never_waits = function()
    with_cluster({}, function(w)
      w.run(20000)
      w.crash(B)
      w.request("TRAIN-1", "R1")
      w.run(3000)
      local a = w.masters[A]
      local before = #a.hw.calls
      -- the dispatcher is told that the route is released: the signals go RED at once although the standby is away and the green never went out
      a.dispatcher.release_route("TRAIN-1", "R1")
      assert(#a.hw.calls > before, "RED reached the hardware without confirmation")
      assert(a.hw.calls[#a.hw.calls].value == "RED")
      for _, call in ipairs(a.hw.calls) do assert(call.value ~= "GREEN", "a green that was cancelled must never go out later") end
      w.restart(B)
      w.run(15000)
      assert(count(w.signal_calls(A, "SE1"), "GREEN") == 0, "the cancelled green never appears")
    end)
  end,

  -- E-07: the leader dies between prepare and commit: nothing half-committed is given by the new leader
  test_e07_a_reservation_prepared_on_both_but_committed_on_neither_is_not_carried_out_after_a_failover = function()
    with_cluster({}, function(w)
      w.run(20000)
      local a, b = w.masters[A], w.masters[B]
      -- the answers never reach A: B has the entry durably, A does not know it
      w.blocked[A] = nil
      local original = a.runtime.handle_event
      local silent = true
      a.runtime.handle_event = function(event)
        if silent and event[1] == "modem_message" and event[5].type == "cmd" and event[5].payload.cmd == "repl" and event[5].payload.kind == "ack" then return end
        return original(event)
      end
      w.request("TRAIN-1", "R1")
      w.run(1500)
      assert(b.replica.last_idx() > b.replica.committed_idx(), "B holds a prepared entry that is not committed")
      assert(count(w.signal_calls(A, "SE1"), "GREEN") == 0 and authorized(w, "TRAIN-1") == 0, "nothing was given")
      w.crash(A)
      w.run(40000)
      assert(w.leader() == B)
      assert(b.dispatcher.get_trains()["TRAIN-1"] == nil, "the new leader does not carry the unconfirmed reservation")
      assert(count(w.signal_calls(B, "SE1"), "GREEN") == 0 and authorized(w, "TRAIN-1") == 0, "and gives nothing")
      assert(b.runtime.recovery.required == true, "the operator confirms the state before routes are given again")
    end)
  end,

  -- E-08: committed on both, the actuation did not happen: the new leader rebuilds the output from the committed reservation
  test_e08_a_committed_reservation_is_kept_and_its_signal_is_set_by_the_new_leader = function()
    with_cluster({}, function(w)
      w.run(20000)
      local a, b = w.masters[A], w.masters[B]
      a.hw.drop = true -- the hardware of A swallowed the calls: as if the computer died before the signal was set
      w.request("TRAIN-1", "R1")
      w.run(2500)
      assert(a.replica.committed_idx() == b.replica.committed_idx(), "committed on both")
      w.crash(A)
      w.run(40000)
      assert(w.leader() == B)
      assert(b.dispatcher.get_trains()["TRAIN-1"] and b.dispatcher.get_trains()["TRAIN-1"].state == "RESERVED", "the reservation survived")
      assert(count(w.signal_calls(B, "SE1"), "GREEN") >= 1, "the new leader sets the signal of the committed reservation")
    end)
  end,

  test_a_leader_that_loses_its_majority_drops_what_waits_and_gives_nothing_later = function()
    with_cluster({}, function(w)
      w.run(20000)
      local a = w.masters[A]
      w.isolate(A)
      w.request("TRAIN-1", "R1")
      w.run(10000)
      assert(not a.ha.is_leader(), "A lost its majority within the lease")
      assert(a.barrier.count() == 0, "what waited was dropped")
      assert(count(w.signal_calls(A, "SE1"), "GREEN") == 0 and authorized(w, "TRAIN-1") == 0)
      w.heal_all()
      w.run(40000)
      assert(w.leader() == B or w.leader() == A)
      assert(count(w.signal_calls(A, "SE1"), "GREEN") == 0 or w.leader() == A)
    end)
  end,

  -- what waits in the barrier while the leader still leads is dropped when the leadership goes, and never goes out later
  test_what_waits_is_dropped_when_the_leadership_is_lost = function()
    with_cluster({}, function(w)
      w.run(20000)
      local a = w.masters[A]
      w.crash(B)
      w.request("TRAIN-1", "R1")
      w.run(3000)
      assert(a.ha.is_leader() and a.barrier.count() >= 1, "the movement waits while A still leads")
      w.isolate(A)
      w.run(15000)
      assert(not a.ha.is_leader(), "A lost the leadership")
      assert(a.barrier.count() == 0, "what waited was dropped")
      w.heal_all()
      w.restart(B)
      w.run(40000)
      assert(count(w.signal_calls(A, "SE1"), "GREEN") == 0 and authorized(w, "TRAIN-1") == 0, "the old request never went out")
    end)
  end,

  -- a change that cannot be written to the journal is never confirmed: what it produced waits (and the standby never hears of it)
  test_a_change_that_cannot_be_journaled_gives_no_movement = function()
    with_cluster({}, function(w)
      w.run(20000)
      local a, b = w.masters[A], w.masters[B]
      w.files[A .. ":journal"].fail.open = "state/master_journal.log"
      local before = b.replica.last_idx()
      w.request("TRAIN-1", "R1")
      w.run(6000)
      assert(a.dispatcher.get_trains()["TRAIN-1"], "the dispatcher of the leader reserved")
      assert(count(w.signal_calls(A, "SE1"), "GREEN") == 0 and authorized(w, "TRAIN-1") == 0, "nothing was given")
      assert(a.barrier.count() >= 1, "the movement waits")
      assert(b.replica.last_idx() == before, "the standby heard of nothing")
    end)
  end,

  test_the_waiting_queue_is_bounded_while_the_standby_is_away = function()
    with_cluster({}, function(w)
      w.run(20000)
      w.crash(B)
      w.request("TRAIN-1", "R1")
      w.run(60000)
      assert(w.masters[A].barrier.count() <= 12, "the refresh of the same signals replaces what waits, got " .. w.masters[A].barrier.count())
    end)
  end,

  test_two_trains_on_routes_that_share_a_block_are_never_given_together_and_the_standby_agrees = function()
    with_cluster({}, function(w)
      w.run(20000)
      w.request("TRAIN-1", "R1")
      w.request("TRAIN-2", "R2")
      w.run(5000)
      assert(authorized(w, "TRAIN-1") + authorized(w, "TRAIN-2") == 1, "R1 and R2 share B2: one train only")
      local a, b = w.masters[A], w.masters[B]
      assert(a.replica.committed_idx() == b.replica.committed_idx())
      assert(b.replica.state().trains["TRAIN-2"] == nil or b.replica.state().trains["TRAIN-2"].state ~= "RESERVED" or b.replica.state().trains["TRAIN-1"].state ~= "RESERVED")
    end)
  end
}
