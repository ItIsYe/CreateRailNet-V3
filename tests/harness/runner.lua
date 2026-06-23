--[[
Purpose: Test runner for CreateRailNet-V3.
Public API: none (script).
]]

pcall(dofile, "tests/harness/cc_bootstrap.lua")

local tests = {
  "tests/test_config.lua",
  "tests/test_config_loader.lua",
  "tests/test_net.lua",
  "tests/test_dispatcher.lua",
  "tests/test_nodes.lua",
  "tests/test_args.lua",
  "tests/test_topology.lua",
  "tests/test_adapter_methods.lua",
  "tests/test_redstone_adapters.lua",
  "tests/test_create_hardware_adapters.lua",
  "tests/test_trains.lua",
  "tests/test_stations.lua",
  "tests/test_depots.lua",
  "tests/test_panel.lua",
  "tests/test_dispatcher_multitrain.lua",
  "tests/test_dispatcher_recovery.lua",
  "tests/test_route_integration.lua",
  "tests/test_route_resolver.lua",
  "tests/test_service_plans.lua",
  "tests/test_create_train_schedule.lua",
  "tests/test_create_station_schedule_tool.lua",
  "tests/test_dwell_manual_control.lua",
  "tests/test_depot_node.lua",
  "tests/test_station_node.lua",
  "tests/test_train_node.lua",
  "tests/test_eventbus.lua",
  "tests/test_signal_logic.lua",
  "tests/test_v316_v318.lua",
  "tests/test_tools_v322_v326.lua",
  "tests/test_tools.lua",
  "tests/test_diagnostics_v328_v332.lua",
  "tests/test_audit_maintenance_v333_v338.lua",
  "tests/test_smoke_load.lua",
  "tests/test_stability_regressions.lua",
  "tests/test_ingame_inspection_tools.lua",
  "tests/test_sensor_occupancy_flow.lua",
  "tests/test_master_state_store.lua",
  "tests/test_recovery_safe_mode.lua",
  "tests/test_setup_wizard.lua",
  "tests/test_sim_basic_flow.lua",
  "tests/test_sim_multitrain_conflict.lua",
  "tests/test_runtime_manifest.lua",
  "tests/test_runtime_packager.lua"
}

local total = 0
local passed = 0
local failed = 0

local function sorted_names(t)
  local names = {}
  for name in pairs(t or {}) do table.insert(names, name) end
  table.sort(names)
  return names
end

for _, path in ipairs(tests) do
  local ok, mod = pcall(dofile, path)
  if not ok then total = total + 1; failed = failed + 1; print("FAIL load " .. path .. ": " .. tostring(mod))
  elseif type(mod) ~= "table" then total = total + 1; failed = failed + 1; print("FAIL load " .. path .. ": test file must return table")
  else
    for _, name in ipairs(sorted_names(mod)) do
      local fn = mod[name]
      total = total + 1
      if type(fn) ~= "function" then failed = failed + 1; print("FAIL " .. path .. "." .. name .. ": test is not function")
      else
        local ok_test, err = pcall(fn)
        if ok_test then passed = passed + 1; print("PASS " .. name) else failed = failed + 1; print("FAIL " .. name .. ": " .. tostring(err)) end
      end
    end
  end
end

print(string.format("%d/%d PASS (%d failed)", passed, total, failed))
if failed ~= 0 or passed ~= total then error("tests failed") end
