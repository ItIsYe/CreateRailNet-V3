--[[
Purpose: Smoke tests for module loading and example config validation.
Public API: returns table of tests.
]]

pcall(dofile, "tests/harness/cc_bootstrap.lua")

local function require_ok(name)
  local ok, mod = pcall(require, name)
  assert(ok, "require failed for " .. name .. ": " .. tostring(mod))
  assert(mod ~= nil, "module returned nil: " .. name)
end

local modules = {
  "src.shared.args",
  "src.shared.config",
  "src.shared.json",
  "src.shared.log",
  "src.shared.net",
  "src.shared.registry",
  "src.shared.validate",
  "src.shared.error_codes",
  "src.domain.audit_log",
  "src.domain.blocks",
  "src.domain.depots",
  "src.domain.diagnostics",
  "src.domain.maintenance",
  "src.domain.panel_state",
  "src.domain.route_queue",
  "src.domain.route_resolver",
  "src.domain.service_plans",
  "src.domain.signal_logic",
  "src.domain.stations",
  "src.domain.switch_locks",
  "src.domain.topology",
  "src.domain.trains",
  "src.adapter.cc_modem",
  "src.adapter.create_sensors",
  "src.adapter.create_signals",
  "src.adapter.create_switches",
  "src.adapter.create_train_schedule",
  "src.adapter.hardware_config",
  "src.adapter.methods",
  "src.adapter.peripherals",
  "src.master.app",
  "src.master.dispatcher",
  "src.master.manual_control",
  "src.master.route_integration",
  "src.master.runtime",
  "src.nodes.common_node",
  "src.nodes.depot_node",
  "src.nodes.panel_node",
  "src.nodes.panel_renderer",
  "src.nodes.sensor_node",
  "src.nodes.signal_node",
  "src.nodes.station_node",
  "src.nodes.switch_node",
  "src.nodes.train_node",
  "src.sim.fake_clock",
  "src.sim.fake_network",
  "src.sim.scenario_runner",
  "src.tools.check_config",
  "src.tools.create_method_finder",
  "src.tools.create_station_schedule_test",
  "src.tools.diagnose_config",
  "src.tools.hardware_binding_report",
  "src.tools.health_report",
  "src.tools.peripheral_inspector",
  "src.tools.redstone_side_report",
  "src.tools.setup_wizard",
  "src.tools.system_check"
}

return {
  test_all_core_modules_require = function()
    for _, name in ipairs(modules) do require_ok(name) end
  end,

  test_full_example_config_loads = function()
    local config = require("src.shared.config")
    local cfg = config.load("configs/templates/network.full.example.json")
    assert(cfg.master_id == "MASTER-1")
    assert(#cfg.nodes > 0)
  end,

  test_service_plan_example_config_loads = function()
    local config = require("src.shared.config")
    local cfg = config.load("configs/templates/network.service_plan.example.json")
    assert(cfg.service_plans)
    assert(#cfg.service_plans > 0)
  end
}
