--[[
Purpose: Master node entrypoint.
Public API: none (script).
]]

local config = require("src.shared.config")
local log = require("src.shared.log")
local registry = require("src.shared.registry")
local dispatcher = require("src.master.dispatcher")
local ui_core = require("src.master.ui.ui_core")
local overview_panel = require("src.master.ui.panels.overview")
local diagnostics_panel = require("src.master.ui.panels.diagnostics")
local peripherals = require("src.adapter.peripherals")
local create_signals = require("src.adapter.create_signals")
local create_switches = require("src.adapter.create_switches")

local function parse_args(argv)
  local args = {}
  for i = 1, #argv do
    if argv[i] == "--config" then
      args.config = argv[i + 1]
    elseif argv[i] == "--id" then
      args.id = argv[i + 1]
    end
  end
  return args
end

local args = parse_args({...})
local cfg = config.load(args.config or "configs/templates/network.example.json")
local logger = log.new("INFO", 200)
local reg = registry.new()
local adapters = {
  signals = create_signals.new(peripherals.new()),
  switches = create_switches.new(peripherals.new())
}
local disp = dispatcher.new(cfg, adapters)

local peripheral_api = peripherals.new()
local monitor = peripheral_api.wrap("monitor")
local configured_scale = cfg.ui and cfg.ui.monitor_scale or 1
local scale_ok, normalized_scale, scale_err = peripheral_api.set_monitor_scale(monitor, configured_scale)
if not scale_ok then
  logger.error("monitor scale apply failed", { requested = configured_scale, normalized = normalized_scale, err = tostring(scale_err) })
end

local ui = ui_core.new(monitor, {
  overview = overview_panel.new(disp, reg),
  diagnostics = diagnostics_panel.new(logger, disp)
}, { logger = logger })
ui.set_panel("overview")
if configured_scale ~= normalized_scale then
  logger.info("monitor scale normalized", { requested = configured_scale, applied = normalized_scale })
end

logger.info("master started", { id = args.id or cfg.master_id })
ui.draw()

-- Event loop (placeholder). In CC, use os.pullEvent.
while false do
  ui.draw()
end
