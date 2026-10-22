--[[
Purpose: The state machine of a requested reservation: PROPOSED to RELEASED_PROVEN, with FAULT and UNCERTAIN as conservative side states (Gesamtkonzept Kap. 5.2, S-02, S-05, S-06).
Public API: returns table of tests.
]]

local phase = require("src.domain.reservation_phase")

local function walk(record, list)
  for _, to in ipairs(list) do
    local ok, err = phase.advance(record, to)
    assert(ok, to .. ": " .. tostring(err))
  end
end

return {
  test_the_normal_way_goes_through_every_state_in_order = function()
    local r = phase.new()
    assert(r.phase == "PROPOSED")
    walk(r, { "VALIDATED", "PREPARED_BOTH_DURABLE", "COMMITTED_BOTH_DURABLE", "ACTUATION_ELIGIBLE", "ACTUATED", "IN_PROGRESS", "CLEARANCE_PENDING", "RELEASED_PROVEN" })
    assert(r.phase == "RELEASED_PROVEN" and phase.is_final(r.phase))
  end,

  test_no_state_may_be_skipped_and_none_goes_back = function()
    local r = phase.new()
    local ok, err = phase.advance(r, "COMMITTED_BOTH_DURABLE")
    assert(not ok and err:find("PROPOSED", 1, true) and r.phase == "PROPOSED", tostring(err))
    walk(r, { "VALIDATED", "PREPARED_BOTH_DURABLE" })
    assert(not phase.advance(r, "VALIDATED") and r.phase == "PREPARED_BOTH_DURABLE")
    assert(not phase.advance(r, "ACTUATION_ELIGIBLE"), "the commit comes first")
    assert(not phase.advance(r, "NONSENSE"))
  end,

  test_nothing_is_actuated_before_both_masters_hold_the_commit = function()
    for _, name in ipairs({ "PROPOSED", "VALIDATED", "PREPARED_BOTH_DURABLE", "COMMITTED_BOTH_DURABLE", "FAULT", "UNCERTAIN", "CLEARANCE_PENDING", "RELEASED_PROVEN" }) do
      assert(phase.may_actuate(name) == false, name)
    end
    for _, name in ipairs({ "ACTUATION_ELIGIBLE", "ACTUATED", "IN_PROGRESS" }) do assert(phase.may_actuate(name) == true, name) end
  end,

  test_a_state_that_was_prepared_but_not_proven_is_uncertain_not_forgotten = function()
    local r = phase.new()
    walk(r, { "VALIDATED", "PREPARED_BOTH_DURABLE", "UNCERTAIN" })
    assert(not phase.may_actuate(r.phase))
    assert(not phase.advance(r, "ACTUATION_ELIGIBLE"), "an uncertain reservation is never simply released for actuation")
    assert(not phase.advance(r, "RELEASED_PROVEN"), "and never simply released")
    assert(phase.advance(r, "CLEARANCE_PENDING"), "it goes the way of every reservation: the clearance has to be proven")
    assert(phase.advance(r, "RELEASED_PROVEN"))
  end,

  test_a_fault_leads_only_to_the_proof_of_clearance = function()
    local r = phase.new()
    walk(r, { "VALIDATED", "FAULT" })
    assert(not phase.advance(r, "ACTUATED") and not phase.advance(r, "RELEASED_PROVEN"))
    assert(phase.advance(r, "CLEARANCE_PENDING") and phase.advance(r, "RELEASED_PROVEN"))
  end,

  test_a_final_state_is_final_and_a_fault_is_possible_from_every_open_state = function()
    local done = phase.new()
    walk(done, { "VALIDATED", "FAULT", "CLEARANCE_PENDING", "RELEASED_PROVEN" })
    for _, to in ipairs({ "FAULT", "UNCERTAIN", "VALIDATED", "PROPOSED" }) do assert(not phase.advance(done, to), to) end
    for _, name in ipairs({ "PROPOSED", "VALIDATED", "PREPARED_BOTH_DURABLE", "COMMITTED_BOTH_DURABLE", "ACTUATION_ELIGIBLE", "ACTUATED", "IN_PROGRESS", "CLEARANCE_PENDING" }) do
      assert(phase.can(name, "FAULT") and phase.can(name, "UNCERTAIN") or name == "PROPOSED" or name == "CLEARANCE_PENDING", name)
    end
  end,

  test_the_table_of_allowed_steps_is_exactly_this_one = function()
    local allowed = {
      PROPOSED = { "VALIDATED", "FAULT", "UNCERTAIN" },
      VALIDATED = { "PREPARED_BOTH_DURABLE", "FAULT", "UNCERTAIN" },
      PREPARED_BOTH_DURABLE = { "COMMITTED_BOTH_DURABLE", "FAULT", "UNCERTAIN" },
      COMMITTED_BOTH_DURABLE = { "ACTUATION_ELIGIBLE", "FAULT", "UNCERTAIN" },
      ACTUATION_ELIGIBLE = { "ACTUATED", "FAULT", "UNCERTAIN" },
      ACTUATED = { "IN_PROGRESS", "CLEARANCE_PENDING", "FAULT", "UNCERTAIN" },
      IN_PROGRESS = { "CLEARANCE_PENDING", "FAULT", "UNCERTAIN" },
      CLEARANCE_PENDING = { "RELEASED_PROVEN" },
      FAULT = { "CLEARANCE_PENDING" },
      UNCERTAIN = { "CLEARANCE_PENDING" },
      RELEASED_PROVEN = {}
    }
    for from, list in pairs(allowed) do
      local ok = {}
      for _, to in ipairs(list) do ok[to] = true end
      for to in pairs(allowed) do
        assert(phase.can(from, to) == (ok[to] == true), from .. " -> " .. to)
      end
    end
  end,

  test_a_short_route_may_go_from_actuated_straight_to_the_clearance = function()
    local r = phase.new()
    walk(r, { "VALIDATED", "PREPARED_BOTH_DURABLE", "COMMITTED_BOTH_DURABLE", "ACTUATION_ELIGIBLE", "ACTUATED", "CLEARANCE_PENDING" })
    assert(r.phase == "CLEARANCE_PENDING")
  end,

  test_the_record_keeps_a_short_history_for_the_diagnosis = function()
    local r = phase.new()
    walk(r, { "VALIDATED", "FAULT" })
    assert(#r.history == 3 and r.history[1] == "PROPOSED" and r.history[3] == "FAULT")
    for i = 1, 20 do phase.advance(r, "CLEARANCE_PENDING"); r.phase = "FAULT" end
    assert(#r.history <= 8, "the history is bounded")
  end,

  test_a_record_from_a_snapshot_with_an_unknown_state_becomes_uncertain = function()
    local r = phase.restore({ phase = "WHATEVER" })
    assert(r.phase == "UNCERTAIN")
    assert(phase.restore(nil).phase == "UNCERTAIN")
    assert(phase.restore({ phase = "ACTUATED" }).phase == "UNCERTAIN", "a restored reservation that may have been actuated is reconstructed, not trusted")
    assert(phase.restore({ phase = "PREPARED_BOTH_DURABLE" }).phase == "UNCERTAIN")
    assert(phase.restore({ phase = "COMMITTED_BOTH_DURABLE" }).phase == "COMMITTED_BOTH_DURABLE", "a committed one is the state both masters hold")
    assert(phase.restore({ phase = "RELEASED_PROVEN" }).phase == "RELEASED_PROVEN")
  end
}
