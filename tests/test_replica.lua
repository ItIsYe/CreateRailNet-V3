--[[
Purpose: Replication of the master state between leader and standby with dual commit: entries, acknowledgements, commits, catching up, large states, restarts, and what a new leader does with
  what was never committed (Gesamtkonzept Kap. 5.2, 5.3, 5.4, S-02, S-03; tests E-02, E-04, E-06, E-07, E-08).
Public API: returns table of tests.
]]

pcall(dofile, "tests/harness/cc_bootstrap.lua")

local replica_world = require("tests.harness.replica_world")
local state_delta = require("src.domain.state_delta")
local prng = require("tests.harness.prng")

local A, B = replica_world.A, replica_world.B

local function with_world(opts, fn)
  local w = replica_world.new(opts)
  local ok, err = pcall(fn, w)
  w.close()
  if not ok then error(err, 0) end
end

local function set_block(member, id, state, owner)
  member.state.blocks[id] = { id = id, state = state, reserved_by = owner }
end

return {
  test_a_change_reaches_the_standby_and_is_confirmed_only_after_both_have_it = function()
    with_world({}, function(w)
      w.lead(A, 1)
      local a, b = w.members[A], w.members[B]
      set_block(a, "B1", "RESERVED", "T1")
      local idx = a.replica.capture()
      assert(idx == 1 and a.replica.last_idx() == 1)
      assert(not a.replica.confirmed(1), "nothing is confirmed before the standby answered")
      w.run(500)
      assert(a.replica.confirmed(1) and a.replica.committed_idx() == 1)
      assert(b.replica.last_idx() == 1 and state_delta.equal(b.replica.state(), a.replica.state()))
      w.run(500)
      assert(b.replica.committed_idx() == 1, "the standby learns the commit")
    end)
  end,

  test_no_change_means_no_entry_and_no_message = function()
    with_world({}, function(w)
      w.lead(A, 1)
      local a = w.members[A]
      set_block(a, "B1", "FREE")
      a.replica.capture()
      w.run(500)
      local before = a.net.pending
      local idx = a.replica.capture()
      assert(idx == 1 and a.replica.last_idx() == 1)
      assert(next(before) == nil)
    end)
  end,

  test_the_standby_not_answering_leaves_the_entry_unconfirmed_and_it_is_confirmed_when_the_standby_returns = function()
    with_world({}, function(w)
      w.lead(A, 1)
      local a, b = w.members[A], w.members[B]
      w.crash(B)
      set_block(a, "B1", "RESERVED", "T1")
      a.replica.capture()
      w.run(20000)
      assert(not a.replica.confirmed(1) and not a.replica.peer_ok(), "no dual confirmation without the standby")
      w.restart(B)
      w.run(8000)
      assert(a.replica.confirmed(1), "confirmed after the standby is back")
      assert(state_delta.equal(b.replica.state(), a.replica.state()))
    end)
  end,

  test_many_changes_over_a_bad_link_end_with_identical_states_and_commits = function()
    for _, seed in ipairs({ 1, 2, 3, 4, 5, 6 }) do
      with_world({ seed = seed, drop = 0.2, duplicate = 0.2, delay_max_ms = 300 }, function(w)
        w.lead(A, 1)
        local a, b = w.members[A], w.members[B]
        local rng = prng.new(seed * 100)
        for i = 1, 60 do
          set_block(a, "B" .. rng.int(1, 8), rng.pick({ "FREE", "RESERVED", "OCCUPIED" }), "T" .. rng.int(1, 3))
          if rng.chance(0.2) then a.state.blocks["B" .. rng.int(1, 8)] = nil end
          a.replica.capture()
          w.step(50, rng.int(1, 6))
        end
        w.run(40000)
        assert(state_delta.equal(b.replica.state(), a.replica.state()), "seed " .. seed .. ": the standby has the leader's state")
        assert(a.replica.committed_idx() == a.replica.last_idx(), "seed " .. seed .. ": everything is confirmed, " .. a.replica.committed_idx() .. "/" .. a.replica.last_idx())
        assert(b.replica.committed_idx() == a.replica.committed_idx(), "seed " .. seed .. ": the standby committed as far")
      end)
    end
  end,

  test_a_standby_that_restarts_catches_up_from_its_journal_and_the_leaders_entries = function()
    with_world({}, function(w)
      w.lead(A, 1)
      local a, b = w.members[A], w.members[B]
      for i = 1, 5 do set_block(a, "B" .. i, "RESERVED", "T1"); a.replica.capture(); w.run(300) end
      w.crash(B)
      for i = 6, 9 do set_block(a, "B" .. i, "RESERVED", "T2"); a.replica.capture(); w.run(200) end
      w.restart(B)
      assert(b.replica.last_idx() == 5, "from its own journal")
      w.run(8000)
      assert(b.replica.last_idx() == 9 and state_delta.equal(b.replica.state(), a.replica.state()))
      assert(a.replica.confirmed(9))
    end)
  end,

  test_a_standby_that_lost_its_disk_gets_a_full_copy = function()
    with_world({}, function(w)
      w.lead(A, 1)
      local a, b = w.members[A], w.members[B]
      for i = 1, 6 do set_block(a, "B" .. i, "RESERVED", "T1"); a.replica.capture(); w.run(300) end
      b.fs.files = {}
      w.restart(B)
      assert(b.replica.last_idx() == 0)
      set_block(a, "B7", "FREE"); a.replica.capture()
      w.run(10000)
      assert(state_delta.equal(b.replica.state(), a.replica.state()) and b.replica.last_idx() == a.replica.last_idx())
    end)
  end,

  test_a_state_larger_than_a_message_is_sent_in_parts = function()
    with_world({ part_bytes = 400 }, function(w)
      w.lead(A, 1)
      local a, b = w.members[A], w.members[B]
      for i = 1, 60 do set_block(a, "B" .. i, "RESERVED", "T" .. (i % 4)) end
      a.replica.capture()
      w.run(10000)
      assert(state_delta.equal(b.replica.state(), a.replica.state()) and a.replica.confirmed(1))
    end)
  end,

  test_parts_that_arrive_damaged_or_incomplete_change_nothing = function()
    with_world({ part_bytes = 400 }, function(w)
      w.lead(A, 1)
      local a, b = w.members[A], w.members[B]
      for i = 1, 40 do set_block(a, "B" .. i, "RESERVED", "T1") end
      w.cut()
      a.replica.capture()
      w.run(1000)
      -- one part is replaced by garbage before it reaches the standby
      local damaged = 0
      for id, entry in pairs(a.net.pending) do
        if entry.msg.payload.kind == "part" and entry.msg.payload.idx == 2 and damaged == 0 then
          local copy = {}
          for k, v in pairs(entry.msg) do copy[k] = v end
          copy.payload = {}
          for k, v in pairs(entry.msg.payload) do copy.payload[k] = v end
          copy.payload.data = string.rep("x", #entry.msg.payload.data)
          copy.id = "damaged.1"
          b.net.receive(copy)
          damaged = damaged + 1
        end
      end
      assert(b.replica.last_idx() == 0)
      -- feed the others intact
      for _, entry in pairs(a.net.pending) do
        local msg = entry.msg
        if msg.payload.kind == "part" and msg.payload.idx ~= 2 then
          local status = b.net.receive(msg)
          if status == "ok" then b.replica.handle(msg) end
        end
      end
      assert(b.replica.last_idx() == 0, "incomplete: nothing applied")
    end)
  end,

  test_a_new_leader_cuts_what_was_never_committed_and_goes_on_from_the_committed_state = function()
    with_world({}, function(w)
      w.lead(A, 1)
      local a, b = w.members[A], w.members[B]
      set_block(a, "B1", "RESERVED", "T1"); a.replica.capture(); w.run(500)
      assert(a.replica.confirmed(1))
      -- the second entry reaches B, but A dies before it hears the acknowledgement: prepared on both, committed on neither
      w.members[A].net.pending = {}
      set_block(a, "B2", "RESERVED", "T2"); a.replica.capture()
      w.link.advance(100)
      w.crash(A)
      w.run(500)
      assert(b.replica.last_idx() == 2 and b.replica.committed_idx() <= 1)
      w.lead(B, 2)
      local state = b.replica.promote()
      assert(state.blocks.B1 and state.blocks.B2 == nil, "B2 was never confirmed by both: not carried out")
      assert(b.replica.last_idx() == 1 and b.replica.committed_idx() == 1)
      b.state = state
      set_block(b, "B3", "RESERVED", "T3")
      assert(b.replica.capture() == 2, "numbering continues after the cut")
    end)
  end,

  test_the_old_leader_that_comes_back_is_brought_to_the_new_leaders_state = function()
    with_world({}, function(w)
      w.lead(A, 1)
      local a, b = w.members[A], w.members[B]
      set_block(a, "B1", "RESERVED", "T1"); a.replica.capture(); w.run(500)
      set_block(a, "B2", "RESERVED", "T2"); a.replica.capture()
      w.link.advance(100)
      w.crash(A)
      w.run(500)
      w.lead(B, 2)
      b.state = b.replica.promote()
      set_block(b, "B9", "OCCUPIED", "T9")
      b.replica.capture()
      w.restart(A)
      w.members[A].leader = false
      w.run(15000)
      assert(state_delta.equal(w.members[A].replica.state(), b.replica.state()), "the returned master follows the new leader")
      assert(w.members[A].replica.state().blocks.B2 == nil, "its own unconfirmed entry is gone")
      assert(b.replica.confirmed(b.replica.last_idx()))
    end)
  end,

  test_a_standby_refuses_entries_of_an_old_term_beyond_its_committed_state = function()
    with_world({}, function(w)
      w.lead(A, 3)
      local a, b = w.members[A], w.members[B]
      set_block(a, "B1", "RESERVED", "T1"); a.replica.capture(); w.run(500)
      local last = b.replica.last_idx()
      local old = { v = 1, pv = 5, id = "old.1", src = A, dst = B, type = "cmd", ts = 0,
        payload = { cmd = "repl", kind = "entry", body = { idx = last + 1, term = 1, prev_idx = last, prev_term = 3, delta = { whole = { queue = { { train_id = "EVIL" } } }, map = {}, removed = {} }, committed_idx = 0 } } }
      b.net.receive(old)
      b.replica.handle(old)
      assert(b.replica.last_idx() == last, "an entry of a term older than the last one is not taken")
    end)
  end,

  test_a_message_from_another_computer_is_ignored = function()
    with_world({}, function(w)
      local b = w.members[B]
      local msg = { v = 1, pv = 5, id = "x.1", src = "EVIL-1", dst = B, type = "cmd", ts = 0, payload = { cmd = "repl", kind = "entry", body = { idx = 1, term = 1, prev_idx = 0, prev_term = 0, delta = { whole = { blocks = {} }, map = {}, removed = {} } } } }
      assert(b.replica.handle(msg) == true)
      assert(b.replica.last_idx() == 0)
      assert(b.replica.handle({ payload = { cmd = "other" } }) == false)
    end)
  end,

  test_a_leader_takes_no_entries_from_the_other_master = function()
    with_world({}, function(w)
      w.lead(A, 2)
      local a = w.members[A]
      local msg = { v = 1, pv = 5, id = "x.2", src = B, dst = A, type = "cmd", ts = 0, payload = { cmd = "repl", kind = "entry", body = { idx = 1, term = 1, prev_idx = 0, prev_term = 0, delta = { whole = { blocks = { B1 = {} } }, map = {}, removed = {} } } } }
      a.replica.handle(msg)
      assert(a.replica.last_idx() == 0)
    end)
  end,

  test_the_journal_stays_small_while_everything_is_confirmed = function()
    with_world({ max_entries = 40 }, function(w)
      w.lead(A, 1)
      local a, b = w.members[A], w.members[B]
      for i = 1, 300 do
        set_block(a, "B" .. (i % 10), (i % 2 == 0) and "RESERVED" or "FREE", "T1")
        a.state.trains["T1"] = { id = "T1", route_index = i }
        a.replica.capture()
        w.run(200)
      end
      w.run(2000)
      assert(a.replica.confirmed(a.replica.last_idx()))
      assert(a.journal.status().entries <= 100, "bounded, got " .. a.journal.status().entries)
      assert(b.journal.status().entries <= 100)
      assert(state_delta.equal(b.replica.state(), a.replica.state()))
    end)
  end,

  test_when_the_standby_stays_away_the_unconfirmed_tail_is_dropped_at_a_limit_and_the_leader_derives_it_again = function()
    with_world({ max_entries = 20, max_bytes = 3000 }, function(w)
      w.lead(A, 1)
      local a, b = w.members[A], w.members[B]
      set_block(a, "B0", "RESERVED", "T0"); a.replica.capture(); w.run(500)
      assert(a.replica.confirmed(1))
      w.crash(B)
      for i = 1, 200 do
        set_block(a, "B" .. (i % 15), "S" .. i, "T1")
        a.replica.capture()
        w.step(50, 2)
      end
      assert(a.journal.status().bytes < 3000 * 4, "bounded")
      assert(a.replica.committed_idx() == 1, "nothing new was ever confirmed")
      w.restart(B)
      w.run(20000)
      assert(state_delta.equal(b.replica.state(), a.replica.state()) or b.replica.last_idx() <= a.replica.last_idx())
      a.replica.capture()
      w.run(10000)
      assert(state_delta.equal(b.replica.state(), a.replica.state()), "the standby has the leader's state after the drop")
      assert(a.replica.confirmed(a.replica.last_idx()))
    end)
  end,

  test_the_state_and_the_commit_survive_a_restart_of_the_leader = function()
    with_world({}, function(w)
      w.lead(A, 1)
      local a = w.members[A]
      set_block(a, "B1", "RESERVED", "T1"); a.replica.capture(); w.run(500)
      set_block(a, "B2", "RESERVED", "T2"); a.replica.capture()
      w.crash(A)
      w.restart(A)
      assert(a.replica.last_idx() == 2 and a.replica.state().blocks.B2, "everything written is read back")
      assert(a.replica.committed_idx() == 1, "and only what was confirmed counts as committed")
    end)
  end,

  test_a_crash_at_every_file_operation_of_the_standby_keeps_a_consistent_prefix = function()
    local function script(w, crash_at, history)
      local b = w.members[B]
      b.fs.ops, b.fs.crash_at, b.fs.crashed, b.fs.sticky_crash = 0, crash_at, false, true
      w.lead(A, 1)
      local a = w.members[A]
      pcall(function()
        for i = 1, 12 do
          set_block(a, "B" .. (i % 5), "S" .. i, "T1")
          local idx = a.replica.capture()
          history[idx] = state_delta.copy(a.replica.state())
          w.run(300)
        end
        w.run(2000)
      end)
    end
    local probe = replica_world.new({})
    script(probe, nil, {})
    local operations = probe.members[B].fs.ops
    probe.close()
    assert(operations > 20, "the standby does a lot of file operations, did " .. operations)
    for crash_at = 1, operations + 1 do
      local w = replica_world.new({})
      local history = {}
      script(w, crash_at, history)
      local fs = w.members[B].fs
      fs.crash_at, fs.crashed = nil, false
      -- the standby reboots on what its disk holds
      w.restart(B)
      local b = w.members[B]
      assert(b.replica.committed_idx() <= b.replica.last_idx(), "crash " .. crash_at .. ": committed beyond the end")
      if b.replica.last_idx() > 0 then
        assert(history[b.replica.last_idx()] and state_delta.equal(b.replica.state(), history[b.replica.last_idx()]),
          "crash " .. crash_at .. ": the standby state is not a state the leader had (index " .. b.replica.last_idx() .. ")")
        local committed = b.replica.committed_idx()
        if committed > 0 then assert(state_delta.equal(b.replica.committed_state(), history[committed]), "crash " .. crash_at .. ": committed state differs") end
      end
      -- and it takes up the stream again
      local a = w.members[A]
      set_block(a, "B9", "LAST", "T9")
      a.replica.capture()
      w.run(20000)
      assert(state_delta.equal(b.replica.state(), a.replica.state()), "crash " .. crash_at .. ": no catch-up after the restart")
      assert(a.replica.confirmed(a.replica.last_idx()), "crash " .. crash_at .. ": not confirmed after the catch-up")
      w.close()
    end
  end,

  -- dual durability: whatever a computer counts as committed, the other one has on its disk (the leader crashes at every file operation)
  test_a_crash_of_the_leader_at_every_file_operation_never_commits_what_the_standby_does_not_have = function()
    local function script(w, crash_at, history)
      local a = w.members[A]
      a.fs.ops, a.fs.crash_at, a.fs.crashed, a.fs.sticky_crash = 0, crash_at, false, true
      w.lead(A, 1)
      pcall(function()
        for i = 1, 12 do
          set_block(a, "B" .. (i % 5), "S" .. i, "T1")
          local idx = a.replica.capture()
          if idx then history[idx] = state_delta.copy(a.replica.state()) end
          w.run(300)
        end
        w.run(2000)
      end)
    end
    local probe = replica_world.new({})
    script(probe, nil, {})
    local operations = probe.members[A].fs.ops
    probe.close()
    assert(operations > 20, "the leader does a lot of file operations, did " .. operations)
    for crash_at = 1, operations + 1 do
      local w = replica_world.new({})
      local history = {}
      script(w, crash_at, history)
      local a, b = w.members[A], w.members[B]
      assert(a.replica.committed_idx() <= b.replica.last_idx(), "crash " .. crash_at .. ": the leader committed " .. a.replica.committed_idx() .. " but the standby has only " .. b.replica.last_idx())
      a.fs.crash_at, a.fs.crashed = nil, false
      w.restart(A)
      assert(a.replica.committed_idx() <= b.replica.last_idx(), "crash " .. crash_at .. ": after the reboot the leader's commit is ahead of the standby")
      if a.replica.last_idx() > 0 then assert(history[a.replica.last_idx()] and state_delta.equal(a.replica.state(), history[a.replica.last_idx()]), "crash " .. crash_at .. ": leader state after reboot") end
      w.close()
    end
  end,
}
