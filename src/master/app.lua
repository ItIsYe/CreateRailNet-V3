--[[
Purpose: Master application factory that wires config, adapters, dispatcher, UI, and network.
Public API: new(args) -> app with run() and context.
]]

local config = require("src.shared.config")
local log = require("src.shared.log")
local registry = require("src.shared.registry")
local dispatcher = require("src.master.dispatcher")
local runtime_factory = require("src.master.runtime")
local ui_core = require("src.master.ui.ui_core")
local overview_panel = require("src.master.ui.panels.overview")
local diagnostics_panel = require("src.master.ui.panels.diagnostics")
local peripherals = require("src.adapter.peripherals")
local hardware_config = require("src.adapter.hardware_config")
local create_signals = require("src.adapter.create_signals")
local create_switches = require("src.adapter.create_switches")
local cc_modem = require("src.adapter.cc_modem")
local net = require("src.shared.net")

local app = {}

local function fallback_monitor()
  return {
    clear = function() end,
    setCursorPos = function() end,
    write = function() end
  }
end

function app.new(args)
  local parsed = args or {}
  local cfg = config.load(parsed.config or "configs/templates/network.example.json")
  local logger = log.new("INFO", 200)
  local reg = registry.new()
  local peri = peripherals.new()
  local hw = hardware_config.new(cfg)
  local modem = cc_modem.new({ channel = cfg.channel })
  local ok, err = modem:open(cfg.channel)
  if ok == false then
    logger.error("master modem open failed", { error = err })
  end

  local disp = dispatcher.new(cfg, {
    signals = create_signals.new(peri, { hardware = hw }),
    switches = create_switches.new(peri, { hardware = hw })
  })

  local network = net.new(modem, cfg.channel, parsed.id or cfg.master_id, logger)
  local monitor = peri.wrap("monitor") or fallback_monitor()
  local ui = ui_core.new(monitor, {
    overview = overview_panel.new(disp, reg),
    diagnostics = diagnostics_panel.new(logger, disp)
  })
  ui.set_panel("overview")

  local context = {
    config = cfg,
    logger = logger,
    registry = reg,
    dispatcher = disp,
    network = network,
    ui = ui
  }

  local instance = { context = context }
  instance.runtime = runtime_factory.new(context)

  function instance.run()
    instance.runtime.run()
  end

  return instance
end

return app
