--[[
Purpose: Master application factory that wires config, adapters, dispatcher, UI, and network.
Public API: new(args) -> app with run() and context.
]]

local config = require("src.shared.config")
local log = require("src.shared.log")
local registry = require("src.shared.registry")
local trains = require("src.domain.trains")
local stations = require("src.domain.stations")
local depots = require("src.domain.depots")
local route_resolver = require("src.domain.route_resolver")
local service_plans = require("src.domain.service_plans")
local audit_log = require("src.domain.audit_log")
local maintenance_mode = require("src.domain.maintenance")
local dispatcher = require("src.master.dispatcher")
local route_integration = require("src.master.route_integration")
local manual_control = require("src.master.manual_control")
local runtime_factory = require("src.master.runtime")
local ui_core = require("src.master.ui.ui_core")
local status_panel = require("src.master.ui.panels.status")
local alerts_panel = require("src.master.ui.panels.alerts")
local alerts_module = require("src.domain.alerts")
local logs_panel = require("src.master.ui.panels.logs")
local log_collector = require("src.domain.log_collector")
local trace_recorder = require("src.domain.trace_recorder")
local overview_panel = require("src.master.ui.panels.overview")
local diagnostics_panel = require("src.master.ui.panels.diagnostics")
local trains_panel = require("src.master.ui.panels.trains")
local stations_panel = require("src.master.ui.panels.stations")
local depots_panel = require("src.master.ui.panels.depots")
local ota_status_panel = require("src.master.ui.panels.ota_status")
local service_plans_panel = require("src.master.ui.panels.service_plans")
local cargo_panel = require("src.master.ui.panels.cargo")
local gleisbild_panel = require("src.master.ui.panels.gleisbild")
local peripherals = require("src.adapter.peripherals")
local monitors = require("src.adapter.monitors")
local pairing_module = require("src.master.pairing")
local plan_service_module = require("src.master.plan_service")
local restart_module = require("src.master.restart")
local setup_panel = require("src.master.ui.panels.setup")
local hardware_config = require("src.adapter.hardware_config")
local create_signals = require("src.adapter.create_signals")
local create_switches = require("src.adapter.create_switches")
local cc_modem = require("src.adapter.cc_modem")
local net = require("src.shared.net")
local auth_setup = require("src.shared.auth_setup")
local ha_module = require("src.shared.ha")
local election_store = require("src.shared.election_store")
local ota_manager = require("src.master.ota_manager")
local cargo_module = require("src.domain.cargo")
local startup_guard = require("src.shared.startup_guard")

local app = {}

local function fallback_monitor()
  return { clear = function() end, setCursorPos = function() end, write = function() end }
end

function app.new(args)
  local parsed = args or {}
  local cfg = config.load(parsed.config or "configs/templates/network.example.json")
  local logger = log.new("INFO", 200)
  startup_guard.ensure({ logger = logger, enabled = cfg.startup_autoupgrade ~= false })
  local reg = registry.new()
  local train_registry = trains.new(cfg)
  local station_registry = stations.new(cfg)
  local depot_registry = depots.new(cfg)
  local service_plan_registry = service_plans.new(cfg)
  local resolver = route_resolver.new(cfg.routes or {})
  local audits = audit_log.new(300)
  local maintenance = maintenance_mode.new()
  local peri = peripherals.new()
  local hw = hardware_config.new(cfg)
  local modem = cc_modem.for_node(cfg, parsed.id or cfg.master_id)
  local ok, err = modem:open(cfg.channel)
  if ok == false then
    logger.error("master modem open failed", { error = err })
    error("master modem open failed: " .. tostring(err))
  end

  local disp = dispatcher.new(cfg, {
    signals = create_signals.new(peri, { hardware = hw }),
    switches = create_switches.new(peri, { hardware = hw })
  })

  -- the last dispatcher calls are kept for replay offline (traces/*.json, scripts/replay_trace.lua)
  local trace = trace_recorder.new({ capacity = cfg.trace_capacity or 500 })
  trace.attach(disp)

  local network = net.new(modem, cfg.channel, parsed.id or cfg.master_id, logger, nil,
    { auth = auth_setup.build(cfg, parsed.id or cfg.master_id, { master = true, logger = logger }) })
  -- two masters (config.masters) and an arbiter: the election decides who commands; a master that is not the leader sends no command (gate) and the others stamp theirs
  local ha
  if ha_module.is_ha(cfg) then
    ha = ha_module.new({
      id = parsed.id or cfg.master_id, config = cfg, network = network, now_ms = require("src.shared.time").now_ms, logger = logger,
      store = election_store.new(cfg.election_state_file),
      lease_ms = cfg.election_lease_ms, beat_ms = cfg.election_beat_ms
    })
    network.gate, network.stamp = ha.gate, ha.stamp
  end
  -- When a reliable message exceeds max retries, log and mark the destination node as potentially down
  network.on_drop = function(msg)
    logger.error("net message dropped after max retries", { type = msg.type, dst = msg.dst, id = msg.id })
    if reg and reg.mark_down and msg.dst then reg.mark_down(msg.dst) end
  end
  local monitor_found, monitor_note = monitors.resolve(peri, hw.value(parsed.id or cfg.master_id, "monitor") or cfg.monitor, hw.value(parsed.id or cfg.master_id, "monitor_scale") or cfg.monitor_scale)
  if monitor_note then logger.warn("master monitor", { note = monitor_note, using = monitor_found and "first monitor found" or "none (no display)" }) end
  local monitor = monitor_found or fallback_monitor()
  -- filled in below; the status page reads them through functions because it is built before them
  local context, instance
  local alerts = alerts_module.new()
  local logs = log_collector.new()
  -- computers that announce themselves but are not in the plan wait for the operator; accepting writes into this plan file
  local pairing = pairing_module.new({
    config = cfg, plan_path = parsed.config or "configs/templates/network.example.json", fs = _G.fs,
    audit = function(kind, data) audits.record(kind, data) end,
  })
  local ui = ui_core.new(monitor, {
    alerts    = alerts_panel.new(alerts, nil),
    setup     = setup_panel.new({
      config = cfg, registry = reg, pairing = pairing,
      decide = function(action, id, operator)
        if instance and instance.runtime then return instance.runtime.pair_decide(action, id, operator) end
        return false, "Der Master startet noch."
      end,
      -- the button "MASTER NEU STARTEN" appears after a computer was accepted
      restart_needed = function() return instance and instance.runtime and instance.runtime.restart_needed == true end,
      restart = function(operator)
        if instance and instance.runtime then return instance.runtime.restart_master(operator) end
        return false, "Der Master startet noch."
      end,
      busy_blocks = function() return instance and instance.runtime and instance.runtime.busy_blocks() or 0 end,
      release = function() return instance and instance.runtime and instance.runtime.release or nil end,
      release_now = function(operator)
        if instance and instance.runtime then return instance.runtime.release_operation(operator) end
        return false, "Der Master startet noch."
      end,
    }),
    status    = status_panel.new({
      alerts = alerts,
      registry = reg,
      dispatcher = disp,
      maintenance = maintenance,
      ota = function() return context and context.ota end,
      recovery = function() return instance and instance.runtime and instance.runtime.recovery end
    }),
    overview  = overview_panel.new(disp, reg, nil),
    gleisbild = gleisbild_panel.new(disp, reg, nil),
    trains    = trains_panel.new(train_registry, nil),
    stations  = stations_panel.new(station_registry, nil, network, function() return parsed.id or cfg.master_id end),
    depots    = depots_panel.new(depot_registry, nil, network),
    fahrplan  = service_plans_panel.new(service_plan_registry, train_registry),
    cargo     = cargo_panel.new(nil, nil),
    diag      = diagnostics_panel.new(logger, disp),
    logs      = logs_panel.new(logs),
    ota       = ota_status_panel.new(reg, audits)
  }, { logger = logger })
  -- Wire manual_control into interactive panels once context is built (below)
  ui.set_panel("status")

  context = {
    ha = ha,
    config = cfg,
    logger = logger,
    registry = reg,
    train_registry = train_registry,
    station_registry = station_registry,
    depot_registry = depot_registry,
    service_plan_registry = service_plan_registry,
    route_resolver = resolver,
    dispatcher = disp,
    network = network,
    ui = ui,
    audit_log = audits,
    maintenance = maintenance,
    alerts = alerts,
    logs = logs,
    trace = trace
  }
  context.route_integration = route_integration.new(context)
  context.manual_control = manual_control.new(context)
  context.ota = ota_manager.new(network, reg, logger)
  context.pairing = pairing
  -- the controlled restart (setup page): signals to RED like on a stop, then the reboot
  context.restart = restart_module.build({ dispatcher = disp, red = cfg.signal_red_on_stop ~= false, logger = logger, reboot = function() if os.reboot then os.reboot() end end })
  -- station and depot computers fetch their plan from here (setup wizard); the file is read when they ask
  context.plan_service = plan_service_module.new({ plan_path = parsed.config or "configs/templates/network.example.json", fs = _G.fs })
  context.cargo = cargo_module.new(cfg)

  -- Rewire interactive panels with manual_control and full context
  local mc = context.manual_control
  if ui.panels.alerts then ui.panels.alerts = alerts_panel.new(alerts, mc) end
  if ui.panels.overview then ui.panels.overview = overview_panel.new(disp, reg, mc) end
  if ui.panels.gleisbild then ui.panels.gleisbild = gleisbild_panel.new(disp, reg, disp.interlocking) end
  if ui.panels.trains then ui.panels.trains = trains_panel.new(train_registry, mc) end
  if ui.panels.stations then ui.panels.stations = stations_panel.new(station_registry, mc, network, function() return parsed.id or cfg.master_id end) end
  if ui.panels.depots then ui.panels.depots = depots_panel.new(depot_registry, mc, network) end
  if ui.panels.cargo then ui.panels.cargo = cargo_panel.new(context.cargo, mc) end
  -- Rebuild page order after rewiring
  if ui.rebuild_order then ui.rebuild_order() end

  instance = { context = context }
  instance.runtime = runtime_factory.new(context)
  function instance.run()
    local ok_run, run_err = pcall(instance.runtime.run)
    -- the master stops (Ctrl+T or a crash): every signal to RED, trains stop in front of them instead of running unobserved
    if cfg.signal_red_on_stop ~= false then
      local ok_red, failed = pcall(disp.shutdown_red)
      if not ok_red then logger.warn("signals to RED on stop failed", { error = tostring(failed) })
      elseif failed > 0 then logger.warn("signals to RED on stop: some did not answer", { failed = failed }) end
    end
    if not ok_run then error(run_err, 0) end
  end
  return instance
end

return app
