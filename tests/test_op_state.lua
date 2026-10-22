--[[
Purpose: The operating states of Kap. 18 and what each one allows, and the maintenance lock that outlives a restart (Pruefplan I-10).
Public API: returns table of tests.
]]

local op_state = require("src.domain.op_state")
local maintenance = require("src.domain.maintenance")
local memfs = require("tests.harness.memfs")

return {
  test_a_checked_network_with_both_masters_is_normal_and_allows_journeys = function()
    local state = op_state.derive({ setup_done = true, both_masters = true, commit_clear = true })
    assert(state == "NORMAL" and op_state.allows_new_departure(state))
  end,

  test_each_trigger_of_the_table_gives_its_state_and_no_new_journey = function()
    local cases = {
      { { setup_done = false }, "INITIAL_SETUP" },
      { { test_mode = true }, "TEST_MODE" },
      { { both_masters = false }, "DEGRADED_GLOBAL" },
      { { commit_clear = false }, "DEGRADED_GLOBAL" },
      { { recovery = true }, "RECOVERY" },
      { { maintenance = true }, "MAINTENANCE" },
      { { fault_locked = "Invariante" }, "FAULT_LOCKED" }
    }
    for _, case in ipairs(cases) do
      local state = op_state.derive(case[1])
      assert(state == case[2], tostring(state) .. " instead of " .. case[2])
      assert(not op_state.allows_new_departure(state, true), case[2] .. " must not allow a journey")
    end
  end,

  test_the_strictest_state_wins = function()
    assert(op_state.derive({ fault_locked = true, recovery = true, maintenance = true, both_masters = false }) == "FAULT_LOCKED")
    assert(op_state.derive({ recovery = true, maintenance = true }) == "RECOVERY")
    assert(op_state.derive({ maintenance = true, both_masters = false, test_mode = true }) == "MAINTENANCE")
    assert(op_state.derive({ both_masters = false, local_faults = { "A1" } }) == "DEGRADED_GLOBAL")
    assert(op_state.derive({ setup_done = false, recovery = true }) == "INITIAL_SETUP")
  end,

  test_a_local_defect_closes_only_areas_that_are_not_proven_independent = function()
    local state, why = op_state.derive({ local_faults = { "B7", "B8" } })
    assert(state == "DEGRADED_LOCAL" and why:find("B7", 1, true))
    assert(op_state.allows_new_departure(state, true) == true)
    assert(op_state.allows_new_departure(state, false) == false and op_state.allows_new_departure(state) == false)
    assert(op_state.allows_new_departure(state, true, false) == false, "global conditions are lost")
  end,

  test_every_state_has_a_german_text = function()
    for _, name in ipairs(op_state.STATES) do assert(op_state.describe(name) ~= name, name) end
  end,

  test_a_maintenance_lock_is_still_there_after_a_restart = function()
    local fs = memfs.new()
    local first = maintenance.new({ fs = fs, path = "state/maintenance.json" })
    assert(first.load() == "empty")
    assert(first.enable("Update SIG-1", "PANEL-1"))
    local second = maintenance.new({ fs = fs, path = "state/maintenance.json" })
    assert(second.load() == "loaded" and second.is_locked() and second.status().reason == "Update SIG-1" and second.status().changed_by == "PANEL-1")
    assert(second.disable("PANEL-1"))
    local third = maintenance.new({ fs = fs, path = "state/maintenance.json" })
    assert(third.load() == "loaded" and not third.is_locked())
  end,

  test_an_unreadable_lock_file_keeps_the_lock_on = function()
    local fs = memfs.new()
    fs.set("state/maintenance.json", "{ not json")
    local m = maintenance.new({ fs = fs, path = "state/maintenance.json" })
    assert(m.load() == "corrupt" and m.is_locked())
  end,

  test_a_lock_file_that_cannot_be_opened_keeps_the_lock_on = function()
    local fs = memfs.new()
    local first = maintenance.new({ fs = fs, path = "state/maintenance.json" })
    first.enable("x", "P")
    -- every copy exists but none can be opened
    local broken = { exists = function() return true end, open = function() return nil end, isDir = fs.isDir, list = fs.list, delete = fs.delete, move = fs.move, makeDir = fs.makeDir }
    local m = maintenance.new({ fs = broken, path = "state/maintenance.json" })
    local result = m.load()
    assert(result == "corrupt" and m.is_locked() and m.status().reason == "Sperrdatei nicht lesbar")
  end,

  test_a_lock_that_cannot_be_written_still_holds_and_says_so = function()
    local fs = memfs.new()
    local m = maintenance.new({ fs = fs, path = "state/maintenance.json" })
    fs.fail.open = "state/maintenance.json.tmp"
    local ok = m.enable("x", "P")
    assert(ok == false and m.is_locked(), "in memory the lock holds, the caller is told it is not durable")
  end,

  test_without_a_path_the_old_memory_only_behaviour_stays = function()
    local m = maintenance.new()
    assert(m.load() == "memory" and m.enable("r", "a") == true and m.is_locked() and m.disable("a") == true and not m.is_locked())
  end
}
