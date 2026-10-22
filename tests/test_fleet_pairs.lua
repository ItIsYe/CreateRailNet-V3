--[[
Purpose: Fixed redundancy pairs of the fleet nodes: no dynamic re-pairing, an odd node stays reserve, a partner failure locks only its pair, a version contradiction locks the pair, exclusive responsibility for trains (Gesamtkonzept Kap. 8.1; tests D-03, D-04, D-05).
Public API: returns table of tests.
]]

local fleet_pairs = require("src.fleet.pairs")

local approval = { operator = "tim", confirmed = true }

local function build(nodes, declared)
  return fleet_pairs.new({ nodes = nodes, pairs = declared, now = function() return 0 end })
end

return {
  test_the_pairs_come_from_the_configuration_and_an_odd_node_stays_reserve = function()
    local fp, problems = build({ "F1", "F2", "F3", "F4", "F5" }, { { id = "P1", nodes = { "F1", "F2" } }, { id = "P2", nodes = { "F3", "F4" } } })
    assert(#problems == 0)
    assert(fp.pair_of("F1").id == "P1" and fp.pair_of("F4").id == "P2" and fp.partner_of("F2") == "F1")
    assert(fp.pair_of("F5") == nil and fp.reserve()[1] == "F5" and #fp.reserve() == 1)
    assert(#fp.list() == 2)
  end,

  test_a_bad_pairing_is_a_problem_and_makes_no_pair = function()
    local fp, problems = build({ "F1", "F2", "F3" }, { { id = "P1", nodes = { "F1", "F2" } }, { id = "P2", nodes = { "F2", "F3" } } })
    assert(#problems >= 1 and table.concat(problems, ";"):find("F2", 1, true))
    assert(#fp.list() == 1 and fp.pair_of("F3") == nil, "F2 belongs to P1 only")
    local _, p2 = build({ "F1" }, { { id = "P1", nodes = { "F1", "F9" } } })
    assert(table.concat(p2, ";"):find("F9", 1, true))
    local _, p3 = build({ "F1", "F2", "F3" }, { { id = "P1", nodes = { "F1", "F2", "F3" } } })
    assert(table.concat(p3, ";"):find("two", 1, true))
    local _, p4 = build({ "F1", "F2" }, { { id = "P1", nodes = { "F1", "F2" } }, { id = "P1", nodes = { "F1", "F2" } } })
    assert(table.concat(p4, ";"):find("P1", 1, true))
  end,

  test_without_a_complete_healthy_pair_there_is_no_automatic_activity = function()
    local fp = build({ "F1" }, {})
    local ok, why = fp.auto_allowed("NOPE")
    assert(not ok and why:find("unknown pair", 1, true))
    assert(#fp.list() == 0 and fp.any_auto() == false)
    local two = build({ "F1", "F2" }, { { id = "P1", nodes = { "F1", "F2" } } })
    assert(not two.auto_allowed("P1"), "nobody reported yet: a partner that was never seen is not alive")
    two.heartbeat("F1", { version = 3, checksum = "a" }); two.heartbeat("F2", { version = 3, checksum = "a" })
    assert(two.auto_allowed("P1") == true and two.any_auto() == true)
  end,

  test_a_silent_partner_locks_its_pair_and_only_its_pair = function()
    local t = 0
    local fp = fleet_pairs.new({ nodes = { "F1", "F2", "F3", "F4" }, pairs = { { id = "P1", nodes = { "F1", "F2" } }, { id = "P2", nodes = { "F3", "F4" } } }, now = function() return t end, timeout_s = 10 })
    for _, n in ipairs({ "F1", "F2", "F3", "F4" }) do fp.heartbeat(n, { version = 1, checksum = "x" }) end
    assert(fp.auto_allowed("P1") and fp.auto_allowed("P2"))
    t = 15
    fp.heartbeat("F1", { version = 1, checksum = "x" }); fp.heartbeat("F3", { version = 1, checksum = "x" }); fp.heartbeat("F4", { version = 1, checksum = "x" })
    local ok, why = fp.auto_allowed("P1")
    assert(not ok and why:find("F2", 1, true), tostring(why))
    assert(fp.auto_allowed("P2") == true, "the healthy pair goes on")
    t = 16
    fp.heartbeat("F2", { version = 1, checksum = "x" })
    assert(fp.auto_allowed("P1") == true, "the partner is back and in step")
  end,

  test_different_versions_mean_the_partner_has_to_catch_up_before_anything_new_is_binding = function()
    local fp = build({ "F1", "F2" }, { { id = "P1", nodes = { "F1", "F2" } } })
    fp.heartbeat("F1", { version = 5, checksum = "a" }); fp.heartbeat("F2", { version = 4, checksum = "b" })
    local ok, why = fp.auto_allowed("P1")
    assert(not ok and why:find("catch", 1, true), tostring(why))
    fp.heartbeat("F2", { version = 5, checksum = "a" })
    assert(fp.auto_allowed("P1") == true)
  end,

  test_the_same_version_with_other_content_locks_the_pair_until_it_is_reconstructed = function()
    local fp = build({ "F1", "F2" }, { { id = "P1", nodes = { "F1", "F2" } } })
    fp.heartbeat("F1", { version = 5, checksum = "a" }); fp.heartbeat("F2", { version = 5, checksum = "DIFFERENT" })
    local ok, why = fp.auto_allowed("P1")
    assert(not ok and why:find("contradict", 1, true), tostring(why))
    assert(fp.status("P1").locked == true)
    fp.heartbeat("F2", { version = 5, checksum = "a" })
    assert(not fp.auto_allowed("P1"), "an agreement alone does not unlock: somebody has to reconstruct")
    assert(not fp.unlock("P1", nil))
    assert(fp.unlock("P1", approval) and fp.auto_allowed("P1") == true)
  end,

  test_nodes_are_never_re_paired_without_an_authorised_guided_step = function()
    local fp = build({ "F1", "F2", "F3" }, { { id = "P1", nodes = { "F1", "F2" } } })
    local ok, err = fp.reassign("P1", { "F1", "F3" }, nil)
    assert(not ok and err:find("operator", 1, true), tostring(err))
    assert(fp.partner_of("F1") == "F2")
    assert(fp.reassign("P1", { "F1", "F3" }, approval))
    assert(fp.partner_of("F1") == "F3" and fp.reserve()[1] == "F2")
    assert(fp.status("P1").locked == true, "after a new pairing the pair is locked until its data is reconstructed")
    local bad, why = fp.reassign("P1", { "F1", "F9" }, approval)
    assert(not bad and why:find("F9", 1, true))
  end,

  test_a_train_belongs_to_one_pair_and_an_order_to_the_pair_of_its_train = function()
    local fp = build({ "F1", "F2", "F3", "F4" }, { { id = "P1", nodes = { "F1", "F2" } }, { id = "P2", nodes = { "F3", "F4" } } })
    assert(fp.assign_train("TRAIN-1", "P1", approval))
    local ok, err = fp.assign_train("TRAIN-1", "P2", approval)
    assert(not ok and err:find("P1", 1, true), tostring(err))
    assert(fp.assign_train("TRAIN-1", "P1", approval) == true, "the same assignment again changes nothing")
    assert(not fp.assign_train("TRAIN-2", "P1", nil))
    assert(not fp.assign_train("TRAIN-2", "P9", approval))
    assert(fp.owner_of_train("TRAIN-1") == "P1" and fp.owner_of_train("TRAIN-2") == nil)
    assert(fp.release_train("TRAIN-1", approval) and fp.owner_of_train("TRAIN-1") == nil)
    assert(fp.assign_train("TRAIN-1", "P2", approval))
  end,

  test_snapshot_and_restore_keep_the_assignments_and_the_locks = function()
    local fp = build({ "F1", "F2" }, { { id = "P1", nodes = { "F1", "F2" } } })
    fp.assign_train("TRAIN-1", "P1", approval)
    fp.heartbeat("F1", { version = 5, checksum = "a" }); fp.heartbeat("F2", { version = 5, checksum = "b" })
    fp.auto_allowed("P1")
    local copy = build({ "F1", "F2" }, { { id = "P1", nodes = { "F1", "F2" } } })
    copy.restore(fp.snapshot())
    assert(copy.owner_of_train("TRAIN-1") == "P1" and copy.status("P1").locked == true)
  end
}
