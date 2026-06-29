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
local overview_panel = require("src.master.ui.panels.overview")
local diagnostics_panel = require("src.master.ui.panels.diagnostics")
local trains_panel = require("src.master.ui.panels.trains")
local stations_panel = require("src.master.ui.panels.stations")
local depots_panel = require("src.master.ui.panels.depots")
local ota_status_panel = require("src.master.ui.panels.ota_status")
local service_plans_panel = require("src.master.ui.panels.service_plans")
local peripherals = require("src.adapter.peripherals")
local hardware_config = require("src.adapter.hardware_config")
local create_signals = require("src.adapter.create_signals")
local create_switches = require("src.adapter.create_switches")
local cc_modem = require("src.adapter.cc_modem")
local net = require("src.shared.net")
local ota_manager = require("src.master.ota_manager")

local app = {}

local function fallback_monitor()
  return { clear = function() end, setCursorPos = function() end, write = function() end }
end

function app.new(args)
  local parsed = args or {}
  local cfg = config.load(parsed.config or "configs/templates/network.example.json")
  local logger = log.new("INFO", 200)
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
  local modem = cc_modem.new({ channel = cfg.channel })
  local ok, err = modem:open(cfg.channel)
  if ok == false then
    logger.error("master modem open failed", { error = err })
    error("master modem open failed: " .. tostring(err))
  end

  local disp = dispatcher.new(cfg, {
    signals = create_signals.new(peri, { hardware = hw }),
    switches = create_switches.new(peri, { hardware = hw })
  })

  local network = net.new(modem, cfg.channel, parsed.id or cfg.master_id, logger)
  -- When a reliable message exceeds max retries, log and mark the destination node as potentially down
  network.on_drop = function(msg)
    logger.error("net message dropped after max retries", { type = msg.type, dst = msg.dst, id = msg.id })
    if reg and reg.mark_down and msg.dst then reg.mark_down(msg.dst) end
  end
  local monitor = peri.wrap("monitor") or fallback_monitor()
  local ui = ui_core.new(monitor, {
    overview  = overview_panel.new(disp, reg),
    trains    = trains_panel.new(train_registry),
    stations  = stations_panel.new(station_registry),
    depots    = depots_panel.new(depot_registry),
    fahrplan  = service_plans_panel.new(service_plan_registry, train_registry),
    diag      = diagnostics_panel.new(logger, disp),
    ota       = ota_status_panel.new(reg, audits)
  })
  ui.set_panel("overview")

  local context = {
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
    maintenance = maintenance
  }
  context.route_integration = route_integration.new(context)
  context.manual_control = manual_control.new(context)
  context.ota = ota_manager.new(network, reg, logger)

  local instance = { context = context }
  instance.runtime = runtime_factory.new(context)
  function instance.run() instance.runtime.run() end
  return instance
end

return app
