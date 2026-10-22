--[[
Purpose: The three permission levels of a panel (view, operate, admin) and the check at the receiving master: a hidden button is no protection, a critical action needs the confirmation (Gesamtkonzept Kap. 11.4).
Public API: returns table of tests.
]]

local permissions = require("src.panel.permissions")

local function cfg(level)
  return { nodes = { { id = "PANEL-1", role = "panel", permission = level }, { id = "SEN-1", role = "sensor" } } }
end

return {
  test_the_level_comes_from_the_plan_and_defaults_to_operate_and_an_unknown_word_is_view = function()
    assert(permissions.level_of(cfg("admin"), "PANEL-1") == "admin")
    assert(permissions.level_of(cfg(nil), "PANEL-1") == "operate", "a panel of an older plan keeps working")
    assert(permissions.level_of(cfg("god"), "PANEL-1") == "view", "an unknown word is the lowest level")
    assert(permissions.level_of(cfg("admin"), "SEN-1") == "view" and permissions.level_of(cfg("admin"), "NOBODY") == "view", "only a panel of the plan has a level")
  end,

  test_view_reads_operate_asks_and_locks_admin_manages = function()
    local view, operate, admin = cfg("view"), cfg("operate"), cfg("admin")
    local function ok(c, action, payload) return (permissions.check(c, "PANEL-1", action, payload or { confirm = true })) end
    assert(ok(view, "trace_dump") == true and ok(view, "request_route") == false and ok(view, "emergency_stop") == false and ok(view, "enter_maintenance") == false)
    assert(ok(operate, "request_route") and ok(operate, "hold_train") and ok(operate, "emergency_stop") and ok(operate, "authorize_train") and ok(operate, "ack_alert") and ok(operate, "cargo_order"))
    assert(not ok(operate, "enter_maintenance") and not ok(operate, "clear_fault") and not ok(operate, "set_signal") and not ok(operate, "ota_push") and not ok(operate, "confirm_recovery") and not ok(operate, "release_train"))
    for _, action in ipairs({ "enter_maintenance", "exit_maintenance", "clear_fault", "set_signal", "set_switch", "ota_push", "confirm_recovery", "release_operation", "release_train", "request_route" }) do
      assert(ok(admin, action), action)
    end
  end,

  test_a_denial_names_the_action_and_the_needed_level = function()
    local ok, reason = permissions.check(cfg("operate"), "PANEL-1", "clear_fault", { confirm = true })
    assert(ok == false and reason:find("clear_fault", 1, true) and reason:find("admin", 1, true) and reason:find("operate", 1, true), tostring(reason))
  end,

  test_an_unknown_action_is_denied_for_everybody = function()
    local ok, reason = permissions.check(cfg("admin"), "PANEL-1", "launch_missiles", { confirm = true })
    assert(ok == false and reason:find("unknown action", 1, true))
    assert(not permissions.check(cfg("admin"), "PANEL-1", nil, {}))
  end,

  test_a_critical_action_needs_the_confirmation_in_the_message = function()
    local c = cfg("admin")
    for _, action in ipairs({ "release_train", "clear_fault", "enter_maintenance", "exit_maintenance", "set_signal", "set_switch", "ota_push", "confirm_recovery", "release_operation" }) do
      local ok, reason = permissions.check(c, "PANEL-1", action, {})
      assert(ok == false and reason:find("confirm", 1, true), action .. ": " .. tostring(reason))
      assert(permissions.check(c, "PANEL-1", action, { confirm = true }) == true, action)
      assert(permissions.check(c, "PANEL-1", action, { confirm = "yes" }) == false, "only the boolean true confirms")
    end
    assert(permissions.check(cfg("operate"), "PANEL-1", "emergency_stop", {}) == true, "an emergency stop must not wait for a second click")
    assert(permissions.check(cfg("operate"), "PANEL-1", "request_route", {}) == true)
  end,

  test_the_ui_offers_only_what_the_level_allows_but_the_check_does_not_depend_on_it = function()
    local list = permissions.actions_for("view")
    local set = {}
    for _, a in ipairs(list) do set[a] = true end
    assert(set.trace_dump and not set.request_route)
    local operate = {}
    for _, a in ipairs(permissions.actions_for("operate")) do operate[a] = true end
    assert(operate.request_route and not operate.clear_fault)
    local admin = {}
    for _, a in ipairs(permissions.actions_for("admin")) do admin[a] = true end
    assert(admin.clear_fault and admin.request_route and admin.trace_dump)
    assert(permissions.is_critical("clear_fault") and not permissions.is_critical("request_route"))
  end,

  test_the_master_refuses_a_manual_control_of_a_panel_below_the_needed_level_and_says_so = function()
    local cluster_world = require("tests.harness.cluster_world")
    local w = cluster_world.new({})
    local ok, err = pcall(function()
      w.run(20000)
      local a = w.masters[cluster_world.A]
      local cfg = a.cfg
      cfg.nodes[#cfg.nodes + 1] = { id = "PANEL-V", role = "panel", permission = "view" }
      cfg.nodes[#cfg.nodes + 1] = { id = "PANEL-O", role = "panel" }
      a.registry.register("PANEL-V", "panel"); a.registry.register("PANEL-O", "panel")
      local calls = {}
      local original = a.runtime.manual_control
      a.runtime.manual_control = { handle = function(payload, src) calls[#calls + 1] = { payload.action, src }; return true end }
      local function send(src, payload)
        payload.type = "manual_control"
        a.runtime.handle_event({ "modem_message", "x", 1, 1, { v = 1, id = "m" .. tostring(#calls) .. src .. tostring(payload.action), src = src, dst = cluster_world.A, type = "event", payload = payload, ts = 0 } })
      end
      send("PANEL-V", { action = "request_route", train_id = "T", route_id = "R1" })
      send("PANEL-O", { action = "clear_fault", block_id = "B1" })
      send("PANEL-O", { action = "request_route", train_id = "T", route_id = "R1" })
      assert(#calls == 1 and calls[1][1] == "request_route" and calls[1][2] == "PANEL-O", "only the request of the operate panel got through: " .. #calls)
      local denied = 0
      for _, entry in ipairs(a.audits) do if entry.kind == "panel_denied" then denied = denied + 1 end end
      assert(denied == 2, "both refusals are in the audit: " .. denied)
      a.runtime.manual_control = original
    end)
    w.close()
    if not ok then error(err, 0) end
  end
  ,test_the_plan_check_accepts_the_three_levels_and_refuses_other_words = function()
    local validate = require("src.shared.validate")
    local function errors_of(level)
      local c = { v = 1, channel = 1, master_id = "M", nodes = { { id = "M", role = "master" }, { id = "P", role = "panel", permission = level } } }
      local _, errs = validate.validate_config(c)
      return table.concat(errs or {}, "\n")
    end
    for _, level in ipairs({ "view", "operate", "admin" }) do assert(not errors_of(level):find("permission", 1, true), level) end
    assert(errors_of("root"):find("permission", 1, true))
  end
}
