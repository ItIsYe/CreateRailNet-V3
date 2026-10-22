--[[
Purpose: Deadlock detection over the wait-for graph of the route queue (Gesamtkonzept Kap. 4.4, test C-12).
Public API: returns table of tests.
]]

local deadlock = require("src.domain.deadlock")

local function key(cycle) return table.concat(cycle, ">") end

return {
  test_two_trains_that_wait_for_each_other_are_a_cycle = function()
    local cycles = deadlock.find_cycles({ { train_id = "T2", blocked_by = { "T1" } }, { train_id = "T1", blocked_by = { "T2" } } })
    assert(#cycles == 1 and key(cycles[1]) == "T1>T2", key(cycles[1] or {}))
  end,

  test_a_chain_without_a_loop_is_no_deadlock = function()
    assert(#deadlock.find_cycles({ { train_id = "T1", blocked_by = { "T2" } }, { train_id = "T2", blocked_by = { "T3" } } }) == 0)
    assert(#deadlock.find_cycles({}) == 0 and #deadlock.find_cycles(nil) == 0)
  end,

  test_a_blocker_that_does_not_wait_itself_cannot_close_a_loop = function()
    -- T3 stands on a block and asks for nothing
    assert(#deadlock.find_cycles({ { train_id = "T1", blocked_by = { "T3" } }, { train_id = "T2", blocked_by = { "T3", "T1" } } }) == 0)
  end,

  test_a_loop_of_three_and_a_second_independent_loop_are_both_found_once_and_in_a_fixed_order = function()
    local items = {
      { train_id = "C", blocked_by = { "A" } }, { train_id = "A", blocked_by = { "B" } }, { train_id = "B", blocked_by = { "C" } },
      { train_id = "Y", blocked_by = { "X" } }, { train_id = "X", blocked_by = { "Y" } }
    }
    local cycles = deadlock.find_cycles(items)
    assert(#cycles == 2 and key(cycles[1]) == "A>B>C" and key(cycles[2]) == "X>Y", key(cycles[1] or {}) .. " | " .. key(cycles[2] or {}))
  end,

  test_a_train_that_waits_for_itself_through_a_block_it_holds_is_a_cycle_of_one = function()
    local cycles = deadlock.find_cycles({ { train_id = "T1", blocked_by = { "T1" } } })
    assert(#cycles == 1 and key(cycles[1]) == "T1")
  end,

  test_a_very_long_queue_is_cut_off_and_the_cut_is_reported = function()
    local items = {}
    for i = 1, 400 do items[#items + 1] = { train_id = "T" .. i, blocked_by = { "T" .. (i % 400 + 1) } } end
    local cycles, truncated = deadlock.find_cycles(items)
    assert(truncated == true and type(cycles) == "table")
  end
}
