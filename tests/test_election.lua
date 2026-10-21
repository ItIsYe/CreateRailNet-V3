--[[
Purpose: The election of the active master: one valid leader at a time, failover when a master, the arbiter or a link fails, no leadership without a majority, a cut-off leader is fenced
  (Gesamtkonzept Kap. 5.1, 5.3, S-01, S-02, tests E-01 .. E-05).
Public API: returns table of tests.
]]

pcall(dofile, "tests/harness/cc_bootstrap.lua")

local election_world = require("tests.harness.election_world")
local election = require("src.domain.election")

local A, B, ARB = election_world.A, election_world.B, election_world.ARB

local function no_violations(w, label)
  assert(#w.violations == 0, (label or "run") .. ": " .. table.concat(w.violations, "; "))
end

local function single_leader(w)
  local leaders = w.leaders()
  assert(#leaders == 1, "expected one valid leader, got " .. #leaders .. " (" .. table.concat(leaders, ",") .. ")")
  return leaders[1], w.members[leaders[1]].election.term()
end

return {
  test_a_cold_start_elects_the_preferred_master_with_the_arbiter = function()
    local w = election_world.new({})
    w.run(15000)
    local leader, term = single_leader(w)
    assert(leader == A and term >= 1)
    assert(w.members[B].election.role() == "follower" and w.members[B].election.leader() == A)
    local voters = w.members[A].election.elected_by()
    assert(#voters >= 2)
    no_violations(w)
  end,

  -- E-01: the leading master is switched off
  test_e01_when_the_leader_dies_the_other_master_leads_after_a_bounded_time = function()
    local w = election_world.new({})
    w.run(15000)
    local _, first_term = single_leader(w)
    w.crash(A)
    local waited = 0
    while #w.leaders() == 0 and waited < 30000 do w.run(500); waited = waited + 500 end
    local leader, term = single_leader(w)
    assert(leader == B and term > first_term, "B leads in a later term")
    assert(waited <= 20000, "failover took " .. waited .. " ms")
    no_violations(w)
    -- the old leader comes back and does not take over: its term is old, B is alive
    w.restart(A)
    w.run(30000)
    local again = single_leader(w)
    assert(again == B, "the returning master must not take the lead from a working one")
    assert(w.members[A].election.role() == "follower" and w.members[A].election.term() == w.members[B].election.term())
    no_violations(w)
  end,

  -- E-02: the standby master is switched off: the leader keeps its leadership with the arbiter (new releases then need P4's two-master confirmation, which stops there)
  test_e02_without_the_standby_the_leader_stays_valid = function()
    local w = election_world.new({})
    w.run(15000)
    local _, term = single_leader(w)
    w.crash(B)
    w.run(30000)
    local leader, term2 = single_leader(w)
    assert(leader == A and term2 == term, "no new election is needed")
    no_violations(w)
  end,

  -- E-03: the arbiter is switched off: both masters still make a majority
  test_e03_without_the_arbiter_the_two_masters_keep_the_leadership = function()
    local w = election_world.new({})
    w.run(15000)
    local _, term = single_leader(w)
    w.crash(ARB)
    w.run(30000)
    local leader, term2 = single_leader(w)
    assert(leader == A and term2 == term)
    -- and they can still elect when the leader then fails
    w.crash(A)
    w.run(30000)
    assert(#w.leaders() == 0, "B alone is not a majority: no valid leader")
    w.restart(A)
    w.run(30000)
    single_leader(w)
    no_violations(w)
  end,

  -- E-04: the link between the masters is cut: the arbiter decides, there is one leader
  test_e04_a_cut_link_between_the_masters_leaves_exactly_one_leader = function()
    local w = election_world.new({})
    w.run(15000)
    w.cut(A, B)
    w.run(60000)
    local leader = single_leader(w)
    assert(leader == A, "A has the arbiter and keeps the lead; B cannot win against a live leader the arbiter follows")
    no_violations(w)
    w.heal_all()
    w.run(20000)
    assert(single_leader(w) == A)
    no_violations(w)
  end,

  -- E-05: a partition: the cut-off leader stops acting by itself, the other side elects a new one, nobody is ever leader twice at once
  test_e05_a_partition_moves_the_leadership_to_the_side_with_the_majority_and_fences_the_old_leader = function()
    local w = election_world.new({})
    w.run(15000)
    local _, old_term = single_leader(w)
    w.isolate(A)
    -- inside one lease the old leader is no longer valid
    w.run(3500)
    assert(#w.leaders() == 0 or w.leaders()[1] ~= A, "A must stop being a valid leader within its lease")
    w.run(30000)
    local leader, term = single_leader(w)
    assert(leader == B and term > old_term)
    -- the partition heals: A learns the new term from the first answer
    w.heal_all()
    w.run(15000)
    assert(single_leader(w) == B)
    assert(w.members[A].election.role() == "follower" and w.members[A].election.term() == w.members[B].election.term())
    no_violations(w)
  end,

  test_without_a_majority_there_is_no_leader = function()
    local w = election_world.new({})
    w.run(15000)
    w.crash(B)
    w.crash(ARB)
    w.run(30000)
    assert(#w.leaders() == 0, "a master alone has no leadership")
    assert(w.members[A].election.role() ~= "leader" or not w.members[A].election.is_leader())
    no_violations(w)
    w.restart(ARB)
    w.run(30000)
    assert(single_leader(w) == A, "with the arbiter back, A is valid again")
    no_violations(w)
  end,

  test_all_computers_restarting_keep_their_terms_and_elect_again = function()
    local w = election_world.new({})
    w.run(15000)
    local _, term = single_leader(w)
    for _, id in ipairs({ A, B, ARB }) do w.crash(id) end
    w.run(2000)
    for _, id in ipairs({ A, B, ARB }) do w.restart(id) end
    w.run(30000)
    local _, term2 = single_leader(w)
    assert(term2 >= term, "terms never go back")
    no_violations(w)
  end,

  test_a_voter_that_restarts_cannot_vote_twice_in_one_term = function()
    local w = election_world.new({})
    local arbiter = w.members[ARB]
    -- master A asks in term 5, the arbiter grants; it restarts; master B asks in term 5 too
    local first = arbiter.election.on_message(A, "vote_request", { term = 5, candidate = A, last_commit = 0 })
    assert(first[1].payload.granted == true)
    w.restart(ARB)
    local second = arbiter.election.on_message(B, "vote_request", { term = 5, candidate = B, last_commit = 0 })
    assert(second[1].payload.granted == false, "the vote was stored before the answer: the restarted arbiter still remembers it")
    local repeated = arbiter.election.on_message(A, "vote_request", { term = 5, candidate = A, last_commit = 0 })
    assert(repeated[1].payload.granted == true, "the same candidate may ask again")
  end,

  test_a_vote_that_cannot_be_stored_is_not_given = function()
    local w = election_world.new({})
    local arbiter = w.members[ARB]
    arbiter.fail_writes = true
    local reply = arbiter.election.on_message(A, "vote_request", { term = 3, candidate = A, last_commit = 0 })
    assert(reply[1].payload.granted == false)
    arbiter.fail_writes = false
    reply = arbiter.election.on_message(A, "vote_request", { term = 3, candidate = A, last_commit = 0 })
    assert(reply[1].payload.granted == true)
  end,

  test_a_candidate_whose_term_cannot_be_stored_does_not_run = function()
    local w = election_world.new({})
    w.members[A].fail_writes = true
    w.run(40000)
    assert(w.members[A].election.role() ~= "leader" and w.members[A].election.status().write_failed)
    w.members[A].fail_writes = false
    w.run(30000)
    assert(#w.leaders() == 1)
    no_violations(w)
  end,

  test_a_master_with_a_shorter_committed_history_does_not_get_the_vote_of_the_other_master = function()
    local commits = { [A] = 3, [B] = 9, [ARB] = 0 }
    local w = election_world.new({ last_commit = function(id) return commits[id] end })
    w.members[ARB].election.on_message(B, "vote_request", { term = 1, candidate = B, last_commit = 9 })
    -- B (9) is asked by A (3): refused although the term is new
    local reply = w.members[B].election.on_message(A, "vote_request", { term = 4, candidate = A, last_commit = 3 })
    assert(reply[1].payload.granted == false, "a vote for a candidate that is behind would lose committed entries")
    reply = w.members[B].election.on_message(A, "vote_request", { term = 5, candidate = A, last_commit = 9 })
    assert(reply[1].payload.granted == true)
  end,

  test_a_message_from_a_stranger_or_with_a_bad_shape_is_ignored = function()
    local w = election_world.new({})
    local e = w.members[A].election
    assert(#e.on_message("EVIL-1", "vote_request", { term = 99, candidate = "EVIL-1" }) == 0)
    assert(e.term() == 0, "a stranger cannot move the term")
    assert(#e.on_message(B, "vote_request", "not a table") == 0)
    assert(#e.on_message(B, "vote_request", { term = "x" }) == 0)
    assert(#e.on_message(B, "vote_request", { term = 1, candidate = ARB }) == 0, "the arbiter is no candidate")
    assert(#e.on_message(B, "vote_request", { term = 1, candidate = A }) == 0, "a request that names another candidate than its sender")
    assert(#e.on_message(B, "lead_beat", { term = 0, leader = A }) >= 0)
  end,

  test_the_arbiter_never_runs_for_leader = function()
    local w = election_world.new({})
    w.crash(A)
    w.crash(B)
    w.run(60000)
    assert(w.members[ARB].election.role() == "follower" and w.members[ARB].election.term() == 0)
  end,

  -- the property: whatever the network and the computers do, never two valid leaders at once, never two leaders in one term, terms never go back
  test_random_failures_never_give_two_leaders_at_once = function()
    for seed = 1, 40 do
      local w = election_world.new({ seed = seed, drop = 0.15, duplicate = 0.1, delay_max_ms = 400, drift = 0.02 })
      local ids = { A, B, ARB }
      local rng = w.rng
      for _ = 1, 90 do
        local pick = rng.int(1, 10)
        local id = ids[rng.int(1, 3)]
        if pick == 1 then w.crash(id)
        elseif pick == 2 then w.restart(id)
        elseif pick == 3 then w.cut(id, ids[rng.int(1, 3)])
        elseif pick == 4 then w.isolate(id)
        elseif pick == 5 then w.heal_all()
        end
        w.run(rng.int(500, 4000))
      end
      no_violations(w, "seed " .. seed)
      -- afterwards the network heals and everything is up: exactly one valid leader comes back
      w.heal_all()
      for _, id in ipairs(ids) do w.restart(id) end
      w.run(60000)
      local leader = single_leader(w)
      assert(leader, "seed " .. seed)
      no_violations(w, "seed " .. seed .. " after healing")
    end
  end,

  test_the_election_logic_is_pure_and_takes_its_inputs_from_the_caller = function()
    local now = 0
    local saved
    local e = election.new({ id = A, voters = { A, B, ARB }, masters = { A, B }, now_ms = function() return now end,
      store = { load = function() return saved end, save = function(term, vote) saved = { term = term, voted_for = vote }; return true end } })
    assert(#e.tick() == 0, "nothing happens before the timeout")
    now = 6000
    local out = e.tick()
    assert(#out == 2 and out[1].kind == "pre_vote_request" and e.role() == "follower" and e.term() == 0, "first only the question, the term stays")
    assert(saved == nil, "a question stores nothing")
    e.on_message(ARB, "pre_vote_reply", { term = 0, granted = true, voter = ARB })
    out = e.tick()
    assert(#out == 2 and out[1].kind == "vote_request" and e.role() == "candidate" and e.term() == 1)
    assert(saved.term == 1 and saved.voted_for == A, "the vote for itself is stored before the request goes out")
    e.on_message(ARB, "vote_reply", { term = 1, granted = true, voter = ARB })
    assert(e.role() == "leader" and e.is_leader())
    now = 6000 + 4000
    assert(not e.is_leader(), "a lease that no beat renewed runs out")
  end,

  test_a_master_that_is_cut_off_does_not_push_the_term_up_and_does_not_disturb_the_leader_when_it_returns = function()
    local w = election_world.new({})
    w.run(15000)
    local leader, term = single_leader(w)
    w.isolate(B)
    w.run(120000)
    assert(w.members[B].election.term() == term, "pre-votes fail without a majority: the term of the cut-off master stays")
    w.heal_all()
    w.run(30000)
    local again, term_again = single_leader(w)
    assert(again == leader and term_again == term, "the leader stays, nothing was disturbed")
    no_violations(w)
  end,

  test_pre_votes_are_refused_while_a_live_leader_is_followed_and_change_no_state = function()
    local w = election_world.new({})
    w.run(15000)
    local arbiter = w.members[ARB].election
    local term = arbiter.term()
    local reply = arbiter.on_message(B, "pre_vote_request", { term = term + 5, candidate = B, last_commit = 0 })
    assert(reply[1].kind == "pre_vote_reply" and reply[1].payload.granted == false)
    assert(arbiter.term() == term, "a question does not move the term")
    local leader_reply = w.members[A].election.on_message(B, "pre_vote_request", { term = term + 5, candidate = B, last_commit = 0 })
    assert(leader_reply[1].payload.granted == false, "a valid leader never helps a challenger")
    w.run(20000)
    assert(single_leader(w) == A)
  end,

  test_a_vote_request_while_a_live_leader_is_followed_is_refused_without_moving_the_term = function()
    local w = election_world.new({})
    w.run(15000)
    local arbiter = w.members[ARB].election
    local term = arbiter.term()
    local reply = arbiter.on_message(B, "vote_request", { term = term + 5, candidate = B, last_commit = 0 })
    assert(reply[1].payload.granted == false and reply[1].payload.term == term)
    assert(arbiter.term() == term, "a disturbing request leaves the term alone")
    w.run(10000)
    assert(single_leader(w) == A and w.members[A].election.term() == term)
  end,

  test_a_granted_vote_holds_the_voter_back_from_the_next_candidate = function()
    local w = election_world.new({})
    local arbiter = w.members[ARB].election
    assert(arbiter.on_message(A, "vote_request", { term = 7, candidate = A, last_commit = 0 })[1].payload.granted == true)
    -- A may be leader any moment: B asks in the next term right away and gets nothing
    assert(arbiter.on_message(B, "vote_request", { term = 8, candidate = B, last_commit = 0 })[1].payload.granted == false)
  end,

  test_a_vote_counts_from_the_first_request_not_from_the_answer = function()
    local now, saved = 0, nil
    local e = election.new({ id = A, voters = { A, B, ARB }, masters = { A, B }, now_ms = function() return now end,
      store = { load = function() return saved end, save = function(term, vote) saved = { term = term, voted_for = vote }; return true end } })
    now = 6000
    e.tick()
    e.on_message(ARB, "pre_vote_reply", { term = 0, granted = true, voter = ARB })
    e.tick()                       -- candidate, first request at 6000
    now = 6900
    e.on_message(ARB, "vote_reply", { term = 1, granted = true, voter = ARB })
    assert(e.role() == "leader" and e.is_leader())
    now = 9100
    assert(not e.is_leader(), "the vote was given at the time of the request: 3000 ms after 6000 is over, 3000 after the answer would not be")
  end,

  test_a_leader_without_acknowledgements_becomes_a_follower_at_its_next_tick = function()
    local now, saved = 0, nil
    local e = election.new({ id = A, voters = { A, B, ARB }, masters = { A, B }, now_ms = function() return now end,
      store = { load = function() return saved end, save = function(term, vote) saved = { term = term, voted_for = vote }; return true end } })
    now = 6000
    e.tick(); e.on_message(ARB, "pre_vote_reply", { term = 0, granted = true, voter = ARB }); e.tick()
    e.on_message(ARB, "vote_reply", { term = 1, granted = true, voter = ARB })
    assert(e.role() == "leader")
    now = 10000
    e.tick()
    assert(e.role() == "follower" and e.leader() == nil, "no majority for a whole lease: not a leader any more")
  end,

  test_a_candidate_that_finds_no_majority_asks_again_before_it_raises_the_term_again = function()
    local now, saved = 0, nil
    local e = election.new({ id = A, voters = { A, B, ARB }, masters = { A, B }, now_ms = function() return now end,
      store = { load = function() return saved end, save = function(term, vote) saved = { term = term, voted_for = vote }; return true end } })
    now = 6000
    e.tick(); e.on_message(ARB, "pre_vote_reply", { term = 0, granted = true, voter = ARB }); e.tick()
    assert(e.role() == "candidate" and e.term() == 1)
    now = 20000
    e.tick()
    assert(e.role() == "follower" and e.term() == 1, "back to the pre-vote with the same term")
  end,

  test_a_beat_of_an_old_term_is_answered_with_the_current_term_so_the_old_leader_steps_down = function()
    local w = election_world.new({})
    local arbiter = w.members[ARB].election
    arbiter.on_message(B, "vote_request", { term = 9, candidate = B, last_commit = 0 })
    local reply = arbiter.on_message(A, "lead_beat", { term = 3, leader = A, n = 1, commit = 0 })
    assert(reply[1].kind == "lead_ack" and reply[1].payload.ok == false and reply[1].payload.term == 9)
    -- the old leader learns it from that answer
    local old = w.members[A].election
    old.on_message(ARB, "lead_ack", { term = 9, ok = false, voter = ARB, n = 1 })
    assert(old.term() == 9 and old.role() == "follower")
  end,

  test_only_a_master_can_be_a_candidate_in_a_vote_request = function()
    local w = election_world.new({})
    assert(#w.members[A].election.on_message(ARB, "vote_request", { term = 5, candidate = ARB, last_commit = 0 }) == 0)
    assert(w.members[A].election.term() == 0)
  end,

  test_an_acknowledgement_of_a_beat_that_was_never_sent_does_not_renew_the_lease = function()
    local now, saved = 0, nil
    local e = election.new({ id = A, voters = { A, B, ARB }, masters = { A, B }, now_ms = function() return now end,
      store = { load = function() return saved end, save = function(term, vote) saved = { term = term, voted_for = vote }; return true end } })
    now = 6000
    e.tick(); e.on_message(ARB, "pre_vote_reply", { term = 0, granted = true, voter = ARB }); e.tick()
    e.on_message(ARB, "vote_reply", { term = 1, granted = true, voter = ARB })
    now = 8000
    e.on_message(B, "lead_ack", { term = 1, ok = true, voter = B, n = 999 })
    now = 9500
    assert(not e.is_leader(), "an ack for a beat number that was never sent counts for nothing")
  end,

  test_a_higher_term_in_a_pre_vote_answer_is_taken_over = function()
    local now = 0
    local e = election.new({ id = A, voters = { A, B, ARB }, masters = { A, B }, now_ms = function() return now end })
    now = 6000
    e.tick()
    e.on_message(ARB, "pre_vote_reply", { term = 9, granted = false, voter = ARB })
    assert(e.term() == 9 and e.role() == "follower")
  end,

  test_a_second_candidate_in_the_current_term_gets_no_vote_while_a_live_leader_is_followed = function()
    local w = election_world.new({})
    local arbiter = w.members[ARB].election
    -- the arbiter learns the term from the leader's beat, it has not voted in it
    arbiter.on_message(A, "lead_beat", { term = 4, leader = A, n = 1, commit = 0 })
    assert(arbiter.term() == 4 and arbiter.leader() == A)
    local reply = arbiter.on_message(B, "vote_request", { term = 4, candidate = B, last_commit = 0 })
    assert(reply[1].payload.granted == false, "two leaders in one term must not be possible")
  end,

  test_an_acknowledgement_from_a_stranger_is_not_a_vote_of_the_majority = function()
    local now, saved = 0, nil
    local e = election.new({ id = A, voters = { A, B, ARB }, masters = { A, B }, now_ms = function() return now end,
      store = { load = function() return saved end, save = function(term, vote) saved = { term = term, voted_for = vote }; return true end } })
    now = 6000
    e.tick(); e.on_message(ARB, "pre_vote_reply", { term = 0, granted = true, voter = ARB }); e.tick()
    e.on_message(ARB, "vote_reply", { term = 1, granted = true, voter = ARB })
    now = 7000
    local beats = e.tick()
    assert(beats[1].kind == "lead_beat")
    now = 9500
    e.on_message("EVIL-1", "lead_ack", { term = 1, ok = true, voter = "EVIL-1", n = beats[1].payload.n })
    assert(not e.is_leader(), "a computer that is not one of the three cannot keep a leader valid")
  end,
}
