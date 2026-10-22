--[[
Purpose: Replacing a computer: old key revoked, new key checked against the screen, every signal bound again by a person, a passed test before the node is trusted again (Pruefplan I-11).
Public API: returns table of tests.
]]

local replacement = require("src.master.replacement")
local keystore = require("src.shared.keystore")
local keyring = require("src.shared.keyring")

local MASTER_KEY = string.rep("1f", 32)
local PLAN = { nodes = {
  { id = "MASTER-A", role = "master" }, { id = "SIG-1", role = "signal", signals = { "S-A", "S-B" } }, { id = "SIG-9", role = "signal" }, { id = "SEN-1", role = "sensor" }
} }

local function new()
  local w = { held = {}, released = {} }
  w.trust = { rev = 1, nodes = {} }
  keystore.issue(w.trust, MASTER_KEY, "SIG-1", "signal", 1)
  w.wizard = replacement.new({ trust = w.trust, master_key = MASTER_KEY, plan = PLAN, now = function() return 5 end,
    on_hold = function(id) w.held[#w.held + 1] = id end, on_release = function(id) w.released[#w.released + 1] = id end })
  -- what the master would show for the key it is about to hand over
  function w.fingerprint_for(id)
    local epoch = (w.trust.nodes[id] and w.trust.nodes[id].epoch or 0) + 1
    return keyring.fingerprint(keyring.derive_node_key(MASTER_KEY, id, epoch))
  end
  return w
end

return {
  test_the_old_computer_loses_its_key_and_is_held_at_once = function()
    local w = new()
    assert(w.wizard.begin("SIG-1", "ED"))
    assert(w.trust.nodes["SIG-1"].status == "revoked" and w.held[1] == "SIG-1")
    assert(w.wizard.state_of("SIG-1").state == "WAIT_NEW_COMPUTER")
  end,

  test_a_master_and_an_unknown_computer_are_not_replaced_here = function()
    local w = new()
    local ok, err = w.wizard.begin("MASTER-A", "ED")
    assert(ok == nil and err:find("master update", 1, true))
    assert(w.wizard.begin("NOPE", "ED") == nil and w.wizard.begin("SIG-1", "") == nil)
  end,

  test_the_new_computer_gets_a_new_key_and_only_a_matching_fingerprint_lets_it_on = function()
    local w = new()
    local old_key = keyring.derive_node_key(MASTER_KEY, "SIG-1", 1)
    w.wizard.begin("SIG-1", "ED")
    local record, fingerprint = w.wizard.adopt("SIG-1", "ED")
    assert(record and record.epoch == 2 and record.key ~= old_key, "a new identity, not the old key again")
    assert(fingerprint == keyring.fingerprint(record.key) and w.wizard.state_of("SIG-1").state == "WAIT_KEY_CHECK")
    local ok, err = w.wizard.confirm_key("SIG-1", "ED", false)
    assert(ok == nil and err:find("fingerprint", 1, true))
    assert(w.trust.nodes["SIG-1"].status == "revoked", "a wrong fingerprint leaves the id revoked")
    assert(w.wizard.state_of("SIG-1").state == "WAIT_NEW_COMPUTER" and w.wizard.state_of("SIG-1").fingerprint == nil)
    local again = w.wizard.adopt("SIG-1", "ED")
    assert(again.epoch == 3 and again.key ~= record.key)
    assert(w.wizard.confirm_key("SIG-1", "", true) == nil and w.wizard.confirm_key("SIG-1", "ED", "yes") == nil, "only a person's true match counts")
    assert(w.wizard.confirm_key("SIG-1", "ED", true) == true and w.wizard.state_of("SIG-1").state == "WAIT_BINDINGS")
  end,

  test_a_new_id_must_be_in_the_plan_and_not_hold_an_active_key = function()
    local w = new()
    w.wizard.begin("SIG-1", "ED")
    assert(w.wizard.adopt("SIG-1", "ED", "SIG-77") == nil)
    keystore.issue(w.trust, MASTER_KEY, "SIG-9", "signal", 1)
    local record, err = w.wizard.adopt("SIG-1", "ED", "SIG-9")
    assert(record == nil and err:find("active key", 1, true))
    keystore.revoke(w.trust, "SIG-9")
    assert(w.wizard.adopt("SIG-1", "ED", "SIG-9"), "a revoked id may be taken")
    assert(w.wizard.state_of("SIG-1").new_id == "SIG-9")
  end,

  test_every_signal_of_the_old_computer_must_be_bound_again_by_a_person = function()
    local w = new()
    w.wizard.begin("SIG-1", "ED")
    assert(w.wizard.bindings_confirmed("SIG-1", { "S-A", "S-B" }, "ED") == nil, "not in this state yet")
    w.wizard.adopt("SIG-1", "ED"); w.wizard.confirm_key("SIG-1", "ED", true)
    local ok, err = w.wizard.bindings_confirmed("SIG-1", { "S-A" }, "ED")
    assert(ok == nil and err:find("S-B", 1, true) and w.wizard.state_of("SIG-1").missing[1] == "S-B")
    assert(w.wizard.bindings_confirmed("SIG-1", { "S-A", "S-B", "S-X" }, "ED") == true)
    assert(w.wizard.state_of("SIG-1").state == "WAIT_TEST")
  end,

  test_a_single_signal_computer_counts_its_own_id_as_the_signal = function()
    local w = new()
    keystore.issue(w.trust, MASTER_KEY, "SIG-9", "signal", 1)
    w.wizard.begin("SIG-9", "ED")
    w.wizard.adopt("SIG-9", "ED"); w.wizard.confirm_key("SIG-9", "ED", true)
    assert(w.wizard.bindings_confirmed("SIG-9", {}, "ED") == nil)
    assert(w.wizard.bindings_confirmed("SIG-9", { "SIG-9" }, "ED") == true)
  end,

  test_the_hold_ends_only_with_a_passed_test_that_names_its_source = function()
    local w = new()
    w.wizard.begin("SIG-1", "ED")
    w.wizard.adopt("SIG-1", "ED"); w.wizard.confirm_key("SIG-1", "ED", true)
    w.wizard.bindings_confirmed("SIG-1", { "S-A", "S-B" }, "ED")
    assert(w.wizard.finish("SIG-1", "ED", { ok = true }) == nil and w.wizard.finish("SIG-1", "ED", { ok = false, source = "x" }) == nil and w.wizard.finish("SIG-1", "ED") == nil)
    assert(#w.released == 0)
    assert(w.wizard.finish("SIG-1", "ED", { ok = true, source = "Funktionstest SIG-1 rot/gruen" }) == true)
    assert(w.released[1] == "SIG-1" and w.wizard.state_of("SIG-1").state == "DONE")
    assert(w.wizard.finish("SIG-1", "ED", { ok = true, source = "again" }) == nil, "done once")
  end,

  test_steps_out_of_order_are_refused = function()
    local w = new()
    assert(w.wizard.adopt("SIG-1", "ED") == nil and w.wizard.finish("SIG-1", "ED", { ok = true, source = "s" }) == nil)
  end
}
