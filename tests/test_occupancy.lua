--[[
Purpose: The proof level of every block: FREE_PROVEN, OCCUPIED_PROVEN, UNKNOWN and what may change it (Gesamtkonzept Kap. 3 S-03, S-07, S-10, 4.1; tests B-07, B-09).
Public API: returns table of tests.
]]

local occupancy = require("src.domain.occupancy")

local function new() return occupancy.new({ blocks = { "B1", "B2", "B3" } }) end

return {
  test_every_block_starts_unknown_and_unknown_is_not_free = function()
    local o = new()
    local r = o.get("B1")
    assert(r.state == "UNKNOWN" and r.source == nil)
    local free, why = o.is_free("B1")
    assert(free == false and why:find("UNKNOWN", 1, true), tostring(why))
  end,

  test_a_tail_sensor_an_observer_or_a_station_can_prove_a_block_free = function()
    for i, source in ipairs({ "tail_sensor", "sensor_level", "observer", "station" }) do
      local o = new()
      local ok, err = o.observe("B1", "FREE_PROVEN", source, { at = 1000 + i })
      assert(ok, tostring(err))
      assert(o.is_free("B1") == true and o.get("B1").source == source and o.get("B1").at == 1000 + i)
    end
  end,

  test_the_substitutes_the_concept_forbids_never_prove_a_block_free = function()
    for _, source in ipairs({ "signal_red", "no_train_at_station", "timeout", "schedule_accepted", "planned_position", "cc_silent", "observer_missing", "restart", "link_loss", "operator", "" }) do
      local o = new()
      local ok, err = o.observe("B1", "FREE_PROVEN", source, { at = 10 })
      assert(not ok and err:find("not a proof", 1, true), source .. ": " .. tostring(err))
      assert(o.get("B1").state == "UNKNOWN" and o.is_free("B1") == false)
    end
    local o = new()
    assert(not o.observe("B1", "FREE_PROVEN", nil, { at = 1 }))
    assert(not o.observe("B1", "SOMETHING", "tail_sensor", { at = 1 }))
    assert(not o.observe("NOPE", "FREE_PROVEN", "tail_sensor", { at = 1 }))
  end,

  test_what_is_suspected_but_not_proven_makes_a_block_unknown_never_free = function()
    local o = new()
    o.observe("B1", "FREE_PROVEN", "tail_sensor", { at = 10 })
    o.suspect("B1", "link_loss")
    assert(o.get("B1").state == "UNKNOWN" and o.get("B1").reason == "link_loss" and o.is_free("B1") == false)
    o.observe("B2", "OCCUPIED_PROVEN", "enter_sensor", { at = 10, train_id = "T1" })
    o.suspect("B2", "cc_silent")
    assert(o.get("B2").state == "UNKNOWN" and o.get("B2").last == "OCCUPIED_PROVEN", "the last known state stays visible, it is no longer a proof")
  end,

  test_a_restart_or_a_change_of_leadership_forgets_every_proof = function()
    local o = new()
    o.observe("B1", "FREE_PROVEN", "tail_sensor", { at = 10 })
    o.observe("B2", "OCCUPIED_PROVEN", "enter_sensor", { at = 10, train_id = "T1" })
    local n = o.invalidate_all("restart")
    assert(n == 2, "two blocks had a proof")
    for _, id in ipairs({ "B1", "B2", "B3" }) do assert(o.get(id).state == "UNKNOWN" and o.is_free(id) == false) end
    assert(o.get("B1").last == "FREE_PROVEN" and o.get("B2").last == "OCCUPIED_PROVEN")
  end,

  test_only_the_named_blocks_are_invalidated_after_a_topology_change = function()
    local o = new()
    for _, id in ipairs({ "B1", "B2", "B3" }) do o.observe(id, "FREE_PROVEN", "observer", { at = 10 }) end
    o.invalidate({ "B2" }, "topology")
    assert(o.is_free("B1") == true and o.is_free("B2") == false and o.is_free("B3") == true, "independent areas keep working (B-09)")
  end,

  test_evidence_older_than_the_current_record_is_ignored = function()
    local o = new()
    o.observe("B1", "OCCUPIED_PROVEN", "enter_sensor", { at = 100, train_id = "T1" })
    local ok, err = o.observe("B1", "FREE_PROVEN", "tail_sensor", { at = 50 })
    assert(not ok and err:find("older", 1, true), tostring(err))
    assert(o.get("B1").state == "OCCUPIED_PROVEN")
    assert(o.observe("B1", "FREE_PROVEN", "tail_sensor", { at = 100 }), "the same moment counts: the later call wins")
    assert(o.is_free("B1") == true)
  end,

  test_a_maintenance_or_fault_flag_blocks_and_clearing_it_proves_nothing = function()
    local o = new()
    o.observe("B1", "FREE_PROVEN", "tail_sensor", { at = 10 })
    o.set_flag("B1", "maintenance", true)
    local free, why = o.is_free("B1")
    assert(free == false and why:find("maintenance", 1, true), tostring(why))
    o.set_flag("B1", "maintenance", false)
    assert(o.is_free("B1") == false, "after the maintenance the old proof is gone (S-10)")
    assert(o.get("B1").state == "UNKNOWN")
    o.observe("B1", "FREE_PROVEN", "tail_sensor", { at = 20 })
    assert(o.is_free("B1") == true)
    o.set_flag("B1", "fault", true)
    assert(o.is_free("B1") == false)
    assert(not o.set_flag("NOPE", "fault", true))
  end,

  test_a_proof_given_while_a_flag_was_set_does_not_survive_the_end_of_the_flag = function()
    local o = new()
    o.set_flag("B1", "maintenance", true)
    assert(o.observe("B1", "FREE_PROVEN", "tail_sensor", { at = 10 }), "evidence is recorded, the flag still blocks")
    assert(o.is_free("B1") == false)
    o.set_flag("B1", "maintenance", false)
    assert(o.get("B1").state == "UNKNOWN" and o.is_free("B1") == false, "the track may have changed during the maintenance")
  end,

  test_a_snapshot_restores_as_unknown_with_the_last_state_visible = function()
    local o = new()
    o.observe("B1", "FREE_PROVEN", "tail_sensor", { at = 10 })
    o.observe("B2", "OCCUPIED_PROVEN", "enter_sensor", { at = 10, train_id = "T1" })
    o.set_flag("B3", "maintenance", true)
    local snap = o.snapshot()
    local copy = occupancy.new({ blocks = { "B1", "B2", "B3" } })
    copy.restore(snap)
    assert(copy.get("B1").state == "UNKNOWN" and copy.get("B1").last == "FREE_PROVEN")
    assert(copy.get("B2").state == "UNKNOWN" and copy.get("B2").last == "OCCUPIED_PROVEN" and copy.get("B2").train_id == "T1")
    assert(copy.get("B3").flags.maintenance == true, "a maintenance flag survives, it only an operator removes")
    assert(copy.is_free("B1") == false)
  end,

  test_the_summary_counts_each_level = function()
    local o = new()
    o.observe("B1", "FREE_PROVEN", "tail_sensor", { at = 1 })
    o.observe("B2", "OCCUPIED_PROVEN", "enter_sensor", { at = 1 })
    local s = o.summary()
    assert(s.FREE_PROVEN == 1 and s.OCCUPIED_PROVEN == 1 and s.UNKNOWN == 1)
  end
}
