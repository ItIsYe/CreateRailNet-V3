--[[
Purpose: When a node may be updated and what stays locked: operator confirmation, release of critical nodes, no active journey, order for masters, arbiter and fleet partners, locks over a restart, rollback without old reservations (Pruefplan I-01, I-04 to I-08, I-10, I-12).
Public API: returns table of tests.
]]

local update_control = require("src.master.update_control")
local manual_control = require("src.master.manual_control")
local memfs = require("tests.harness.memfs")

local CONFIG = { nodes = {
  { id = "MASTER-A", role = "master" }, { id = "MASTER-B", role = "master" }, { id = "ARB-1", role = "arbiter" },
  { id = "SIG-1", role = "signal" }, { id = "PANEL-1", role = "panel" },
  { id = "FLEET-1", role = "fleet" }, { id = "FLEET-2", role = "fleet" }, { id = "FLEET-3", role = "fleet" }
} }

local function new(extra)
  local w = { fs = memfs.new(), locked = {}, busy = {}, ha = { leads = true, both_masters_healthy = true }, state = "NORMAL", partner_alive = true }
  local pairs_view = {
    pair_of = function(id) if id == "FLEET-1" or id == "FLEET-2" then return "P1" end end,
    partner_of = function(id) if id == "FLEET-1" then return "FLEET-2" elseif id == "FLEET-2" then return "FLEET-1" end end,
    status = function() return { alive = w.partner_alive } end
  }
  local opts = {
    fs = w.fs, config = CONFIG, now = function() return 10 end, fleet_pairs = pairs_view,
    busy = function(id) return w.busy[id] == true end, ha = function() return w.ha end, op_state = function() return w.state end,
    on_lock = function(id) w.locked[#w.locked + 1] = id end
  }
  for k, v in pairs(extra or {}) do opts[k] = v end
  w.control = update_control.new(opts)
  w.control.load()
  function w.ready(id, confirm)
    assert(w.control.prepare(id, { release = "v2", rollback_to = "v1" }))
    assert(w.control.release_node(id, "PANEL-1", "lokal ROT, Strecke frei"))
    return w.control.check(id, { confirm = confirm ~= false })
  end
  return w
end

local function reasons_text(list) return table.concat(list or {}, " | ") end

return {
  test_a_prepared_update_is_not_activated_without_the_operator = function()
    local w = new()
    assert(w.control.prepare("PANEL-1", { release = "v2", rollback_to = "v1" }))
    local ok, reasons = w.control.check("PANEL-1", {})
    assert(not ok and reasons_text(reasons):find("Betreiberbestaetigung", 1, true))
    assert(w.control.check("PANEL-1", { confirm = true }) == true, "a panel needs only the confirmation")
  end,

  test_nothing_is_activated_that_was_not_prepared = function()
    local w = new()
    local ok, reasons = w.control.check("SIG-1", { confirm = true })
    assert(not ok and reasons_text(reasons):find("vorbereitet", 1, true))
  end,

  test_a_critical_node_needs_the_safe_state_release_too = function()
    local w = new()
    assert(w.control.prepare("SIG-1", { release = "v2", rollback_to = "v1" }))
    local ok, reasons = w.control.check("SIG-1", { confirm = true })
    assert(not ok and reasons_text(reasons):find("Freigabe", 1, true))
    assert(not w.control.release_node("SIG-1", "", "x") and not w.control.release_node("SIG-1", "P", ""), "operator and evidence are needed")
    assert(w.control.release_node("SIG-1", "PANEL-1", "lokal ROT"))
    assert(w.control.check("SIG-1", { confirm = true }) == true)
  end,

  test_an_active_journey_that_depends_on_the_node_prevents_the_restart = function()
    local w = new()
    w.busy["SIG-1"] = true
    local ok, reasons = w.ready("SIG-1")
    assert(not ok and reasons_text(reasons):find("Fahrt", 1, true))
    w.busy["SIG-1"] = false
    assert(w.control.check("SIG-1", { confirm = true }) == true)
  end,

  test_critical_nodes_are_not_updated_in_recovery_or_fault_lock = function()
    local w = new()
    w.state = "RECOVERY"
    assert(not w.ready("SIG-1"))
    w.state = "FAULT_LOCKED"
    assert(not w.control.check("SIG-1", { confirm = true }))
    w.state = "MAINTENANCE"
    assert(w.control.check("SIG-1", { confirm = true }) == true)
  end,

  test_a_master_is_updated_as_standby_by_the_leader_never_the_leader_itself = function()
    local w = new()
    w.ha = { leads = false }
    local ok, reasons = w.ready("MASTER-B")
    assert(not ok and reasons_text(reasons):find("fuehrende Master", 1, true))
    w.ha = { leads = true }
    assert(w.control.check("MASTER-B", { confirm = true }) == true)
  end,

  test_the_arbiter_is_only_updated_with_two_healthy_masters = function()
    local w = new()
    w.ha = { leads = true, both_masters_healthy = false }
    local ok, reasons = w.ready("ARB-1")
    assert(not ok and reasons_text(reasons):find("Schiedsrichter", 1, true))
    w.ha = { leads = true, both_masters_healthy = true }
    assert(w.control.check("ARB-1", { confirm = true }) == true)
  end,

  test_a_fleet_partner_is_updated_one_at_a_time_and_other_pairs_stay_out = function()
    local w = new()
    assert(w.ready("FLEET-1"))
    assert(w.control.begin("FLEET-1", "PANEL-1"))
    assert(w.control.prepare("FLEET-2", { release = "v2", rollback_to = "v1" }))
    assert(w.control.release_node("FLEET-2", "PANEL-1", "ruht"))
    local ok, reasons = w.control.check("FLEET-2", { confirm = true })
    assert(not ok and reasons_text(reasons):find("FLEET-1", 1, true), "the partner is in the update")
    assert(w.control.finish("FLEET-1", "confirmed"))
    assert(w.control.check("FLEET-2", { confirm = true }) == true)
    w.partner_alive = false
    local ok2, reasons2 = w.control.check("FLEET-2", { confirm = true })
    assert(not ok2 and reasons_text(reasons2):find("erreichbar", 1, true))
    assert(w.ready("FLEET-3") ~= nil)
  end,

  test_a_partner_in_the_trial_boot_still_blocks_the_other_one = function()
    local w = new()
    assert(w.ready("FLEET-1")); assert(w.control.begin("FLEET-1", "PANEL-1")); assert(w.control.finish("FLEET-1", "trial"))
    assert(w.control.prepare("FLEET-2", { release = "v2", rollback_to = "v1" }))
    assert(w.control.release_node("FLEET-2", "PANEL-1", "ruht"))
    assert(not w.control.check("FLEET-2", { confirm = true }), "the partner has not confirmed its new code yet")
  end,

  test_a_failed_activation_locks_the_node_and_the_lock_needs_a_proof = function()
    local w = new()
    assert(w.ready("SIG-1")); assert(w.control.begin("SIG-1", "PANEL-1"))
    assert(w.control.finish("SIG-1", "failed"))
    assert(w.control.is_locked("SIG-1") and w.locked[1] == "SIG-1")
    assert(not w.control.prepare("SIG-1", { release = "v3", rollback_to = "v1" }), "a locked node is not prepared again")
    assert(not w.control.unlock("SIG-1", "PANEL-1") and not w.control.unlock("SIG-1", "PANEL-1", { kind = "click" }))
    assert(w.control.unlock("SIG-1", "PANEL-1", { kind = "self_test", source = "SIG-1" }))
    assert(not w.control.is_locked("SIG-1"))
  end,

  test_a_rollback_never_restores_old_reservations_it_locks_and_tells_the_dispatcher = function()
    local w = new()
    assert(w.ready("SIG-1")); assert(w.control.begin("SIG-1", "PANEL-1"))
    assert(w.control.finish("SIG-1", "rolled_back"))
    local locks = w.control.locks()
    assert(#locks == 1 and locks[1].reason:find("nicht wiederhergestellt", 1, true))
    assert(w.locked[1] == "SIG-1", "on_lock is how the dispatcher learns that the blocks of the node are unknown")
  end,

  test_a_confirmed_update_ends_without_a_lock = function()
    local w = new()
    assert(w.ready("SIG-1")); assert(w.control.begin("SIG-1", "PANEL-1"))
    assert(w.control.finish("SIG-1", "trial"))
    assert(w.control.state_of("SIG-1").state == "TRIAL")
    assert(w.control.finish("SIG-1", "confirmed"))
    assert(not w.control.is_locked("SIG-1") and #w.control.locks() == 0)
    assert(not w.control.finish("SIG-1", "confirmed"), "nothing is running any more")
  end,

  test_a_restart_in_the_middle_of_the_slot_change_gives_a_lock = function()
    local w = new()
    assert(w.ready("SIG-1")); assert(w.control.begin("SIG-1", "PANEL-1"))
    local again = new({ fs = w.fs })
    assert(again.control.is_locked("SIG-1"), "the slot is unknown after the restart")
    assert(select(2, again.control.is_locked("SIG-1")):find("Neustart", 1, true))
    assert(again.locked[1] == "SIG-1")
  end,

  test_locks_outlive_a_restart = function()
    local w = new()
    assert(w.ready("SIG-1")); assert(w.control.begin("SIG-1", "PANEL-1")); assert(w.control.finish("SIG-1", "failed"))
    local again = new({ fs = w.fs })
    assert(again.control.is_locked("SIG-1"))
  end,

  test_a_damaged_plan_file_locks_every_critical_node_but_not_the_panel = function()
    local fs = memfs.new()
    fs.set("state/update_plan.json", "{{{")
    local w = new({ fs = fs })
    assert(w.control.is_locked("SIG-1") and w.control.is_locked("MASTER-B") and w.control.is_locked("ARB-1"))
    assert(not w.control.is_locked("PANEL-1"))
  end,

  test_manual_control_prepares_refuses_and_only_then_sends = function()
    local w = new()
    local pushed = {}
    local ctx = { network = { send = function() end }, update_control = w.control, ota = { push_runtime = function(o) pushed[#pushed + 1] = o; return { ["SIG-1"] = { ok = true } } end } }
    local mc = manual_control.new(ctx)
    local ok, message = mc.handle({ action = "ota_push", node_id = "SIG-1", version = "v2", operator = "ED" }, "PANEL-1")
    assert(ok == false and message:find("Betreiberbestaetigung", 1, true) and #pushed == 0, tostring(message))
    local ok2, message2 = mc.handle({ action = "ota_push", node_id = "SIG-1", version = "v2", confirm = true, operator = "ED" }, "PANEL-1")
    assert(ok2 == false and message2:find("Freigabe", 1, true) and #pushed == 0)
    assert(mc.handle({ action = "update_release", node_id = "SIG-1", operator = "ED", evidence = "lokal ROT" }, "PANEL-1") == true)
    local ok3 = mc.handle({ action = "ota_push", node_id = "SIG-1", version = "v2", confirm = true, operator = "ED" }, "PANEL-1")
    assert(ok3 == true and #pushed == 1 and w.control.state_of("SIG-1").state == "ACTIVATING")
    local ok4, message4 = mc.handle({ action = "ota_push", version = "v2", confirm = true }, "PANEL-1")
    assert(ok4 == false and message4:find("target node", 1, true), "no blind broadcast with the update control")
  end,

  test_a_maintenance_lock_does_not_block_the_update_actions = function()
    local w = new()
    local maintenance = require("src.domain.maintenance").new()
    maintenance.enable("Wartung", "ED")
    local ctx = { network = { send = function() end }, update_control = w.control, maintenance = maintenance, ota = { push_runtime = function() return { ["PANEL-1"] = { ok = true } } end } }
    local mc = manual_control.new(ctx)
    assert(mc.handle({ action = "ota_push", node_id = "PANEL-1", confirm = true, operator = "ED" }, "PANEL-1") == true)
  end
  ,test_the_config_check_knows_the_two_state_files = function()
    local validate = require("src.shared.validate")
    local function text(extra)
      local c = { v = 1, channel = 1, master_id = "M", nodes = { { id = "M", role = "master" } } }
      for k, v in pairs(extra) do c[k] = v end
      local _, errs = validate.validate_config(c)
      return table.concat(errs or {}, "\n")
    end
    assert(not text({ maintenance_file = "state/m.json", update_plan_file = "state/u.json" }):find("_file", 1, true))
    assert(text({ maintenance_file = "" }):find("maintenance_file", 1, true))
    assert(text({ update_plan_file = 5 }):find("update_plan_file", 1, true))
  end
}
