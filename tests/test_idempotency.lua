--[[
Purpose: Commands are carried out exactly once, also across a restart; an unclear outcome is never repeated blindly (Gesamtkonzept Kap. 7.3, 12.2, tests C-03, E-08).
Public API: returns table of tests.
]]

pcall(dofile, "tests/harness/cc_bootstrap.lua")

local journal = require("src.shared.journal")
local idempotency = require("src.shared.idempotency")
local memfs = require("tests.harness.memfs")

local function setup(fs, clock)
  local j = journal.new("state/idem.log", { fs = fs })
  j.open()
  local ledger = idempotency.new({ journal = j, now = function() return clock.t end })
  return j, ledger
end

return {
  test_a_command_is_new_once_then_done_with_its_outcome = function()
    local clock = { t = 100 }
    local _, ledger = setup(memfs.new(), clock)
    assert(ledger.begin("cmd.1") == "new")
    assert(ledger.begin("cmd.1") == "started", "a retry while it runs must wait")
    assert(ledger.finish("cmd.1", "applied"))
    local state, outcome = ledger.begin("cmd.1")
    assert(state == "done" and outcome == "applied")
    assert(ledger.status("cmd.1") == "done")
    assert(ledger.status("cmd.2") == "unknown")
    assert(ledger.finish("cmd.1", "other"), "finishing twice changes nothing")
    assert(select(2, ledger.begin("cmd.1")) == "applied")
  end,

  test_bad_ids_and_unknown_finishes_are_refused = function()
    local _, ledger = setup(memfs.new(), { t = 0 })
    assert(ledger.begin("") == nil and ledger.begin(nil) == nil and ledger.begin(string.rep("x", 200)) == nil)
    assert(ledger.finish("never-begun", "x") == nil)
  end,

  test_after_a_restart_a_begin_without_finish_is_uncertain_and_a_finished_one_stays_done = function()
    local fs, clock = memfs.new(), { t = 100 }
    local j, ledger = setup(fs, clock)
    ledger.begin("depart.T1.R1"); ledger.finish("depart.T1.R1", "ok")
    ledger.begin("depart.T2.R1") -- the master dies here
    local j2 = journal.new("state/idem.log", { fs = fs })
    j2.open()
    local again = idempotency.new({ journal = j2, now = function() return clock.t end })
    again.recover(j2.recovered().entries)
    assert(again.status("depart.T1.R1") == "done" and select(2, again.status("depart.T1.R1")) == "ok")
    assert(again.status("depart.T2.R1") == "uncertain")
    assert(again.begin("depart.T2.R1") == "uncertain", "never repeated blindly")
    -- the caller looked at the world and settles it
    assert(again.finish("depart.T2.R1", "left"))
    assert(again.begin("depart.T2.R1") == "done")
  end,

  test_no_durable_record_means_no_action = function()
    local fs, clock = memfs.new(), { t = 0 }
    local j, ledger = setup(fs, clock)
    fs.capacity = fs.used()
    local state, err = ledger.begin("cmd.x")
    assert(state == nil and err, "begin must fail when the step cannot be written")
    assert(ledger.status("cmd.x") == "unknown", "and nothing is remembered that was not written")
    fs.capacity = nil
    j.reopen()
    assert(ledger.begin("cmd.x") == "new")
  end,

  test_a_snapshot_carries_the_ledger_and_unfinished_begins_become_uncertain = function()
    local fs, clock = memfs.new(), { t = 10 }
    local j, ledger = setup(fs, clock)
    ledger.begin("a"); ledger.finish("a", 1)
    ledger.begin("b")
    assert(j.snapshot({ ledger = ledger.to_state() }))
    ledger.begin("c"); ledger.finish("c", 3)
    local j2 = journal.new("state/idem.log", { fs = fs })
    j2.open()
    local again = idempotency.new({ journal = j2, now = function() return clock.t end })
    again.load_state(j2.recovered().state.ledger)
    again.recover(j2.recovered().entries)
    assert(again.status("a") == "done" and again.status("b") == "uncertain" and again.status("c") == "done")
  end,

  test_finished_entries_expire_and_the_table_stays_bounded_but_open_ones_never_go = function()
    local fs, clock = memfs.new(), { t = 0 }
    local j = journal.new("state/idem.log", { fs = fs })
    j.open()
    local ledger = idempotency.new({ journal = j, now = function() return clock.t end, ttl_s = 100, max = 20 })
    ledger.begin("open.1")
    for i = 1, 100 do
      clock.t = clock.t + 1
      assert(ledger.begin("c." .. i) == "new")
      ledger.finish("c." .. i, i)
    end
    local count = 0
    for id in pairs(ledger.to_state()) do count = count + 1 end
    assert(count <= 21, "bounded by max (plus the open one), got " .. count)
    assert(ledger.status("open.1") == "started")
    assert(ledger.status("c.100") == "done" and ledger.status("c.1") == "unknown", "the oldest finished ones went first")
    clock.t = clock.t + 1000
    ledger.begin("late")
    assert(ledger.status("c.100") == "unknown", "old finished entries expire")
    assert(ledger.status("open.1") == "started")
  end,

  test_without_a_journal_the_ledger_still_works_in_memory = function()
    local ledger = idempotency.new({ now = function() return 0 end })
    assert(ledger.begin("x") == "new" and ledger.finish("x", true) and ledger.begin("x") == "done")
  end
}
