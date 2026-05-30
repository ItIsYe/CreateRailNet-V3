--[[
Purpose: Standalone Lua syntax checker for repository files.
Usage: lua scripts/check_syntax.lua or shell.run("scripts/check_syntax.lua") if lua is available.
Notes: This checks parse/load errors only. It does not execute modules.
]]

local files = {
  "startup.lua",
  "scripts/run_tests.lua",
  "scripts/start_master.lua",
  "scripts/start_train.lua",
  "scripts/start_panel.lua",
  "scripts/start_signal.lua",
  "scripts/start_sensor.lua",
  "scripts/start_switch.lua",
  "scripts/start_station.lua",
  "scripts/start_depot.lua",
  "src/shared/args.lua",
  "src/shared/config.lua",
  "src/shared/error_codes.lua",
  "src/shared/json.lua",
  "src/shared/log.lua",
  "src/shared/message_handlers.lua",
  "src/shared/net.lua",
  "src/shared/registry.lua",
  "src/shared/validate.lua",
  "src/domain/audit_log.lua",
  "src/domain/blocks.lua",
  "src/domain/depots.lua",
  "src/domain/diagnostics.lua",
  "src/domain/maintenance.lua",
  "src/domain/panel_state.lua",
  "src/domain/route_queue.lua",
  "src/domain/route_resolver.lua",
  "src/domain/service_plans.lua",
  "src/domain/signal_logic.lua",
  "src/domain/stations.lua",
  "src/domain/switch_locks.lua",
  "src/domain/topology.lua",
  "src/domain/trains.lua",
  "src/adapter/cc_modem.lua",
  "src/adapter/create_sensors.lua",
  "src/adapter/create_signals.lua",
  "src/adapter/create_switches.lua",
  "src/adapter/create_train_schedule.lua",
  "src/adapter/hardware_config.lua",
  "src/adapter/methods.lua",
  "src/adapter/peripherals.lua",
  "src/adapter/redstone.lua",
  "src/master/app.lua",
  "src/master/dispatcher.lua",
  "src/master/manual_control.lua",
  "src/master/route_integration.lua",
  "src/master/runtime.lua",
  "src/nodes/bootstrap.lua",
  "src/nodes/common_node.lua",
  "src/nodes/depot_node.lua",
  "src/nodes/panel_node.lua",
  "src/nodes/panel_renderer.lua",
  "src/nodes/sensor_node.lua",
  "src/nodes/signal_node.lua",
  "src/nodes/station_node.lua",
  "src/nodes/switch_node.lua",
  "src/nodes/train_node.lua",
  "src/tools/check_config.lua",
  "src/tools/create_method_finder.lua",
  "src/tools/create_station_schedule_test.lua",
  "src/tools/debug_event.lua",
  "src/tools/debug_events.lua",
  "src/tools/diagnose_config.lua",
  "src/tools/hardware_binding_report.lua",
  "src/tools/health_report.lua",
  "src/tools/peripheral_inspector.lua",
  "src/tools/redstone_side_report.lua",
  "src/tools/system_check.lua",
  "tests/harness/cc_bootstrap.lua",
  "tests/harness/runner.lua"
}

local total = 0
local failed = 0

local function file_exists(path)
  local fh = io and io.open and io.open(path, "r")
  if fh then fh:close(); return true end
  if fs and fs.exists then return fs.exists(path) end
  return false
end

for _, path in ipairs(files) do
  if file_exists(path) then
    total = total + 1
    local ok, err = loadfile(path)
    if ok then
      print("PASS syntax " .. path)
    else
      failed = failed + 1
      print("FAIL syntax " .. path .. ": " .. tostring(err))
    end
  else
    print("SKIP missing " .. path)
  end
end

print(string.format("syntax: %d checked, %d failed", total, failed))
if failed ~= 0 then error("syntax check failed") end
