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
local cc_modem = require("src.adapter.cc_modem")
local net = require("src.shared.net")

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

local function fallback_monitor()
  return {
    clear = function() end,
    setCursorPos = function() end,
    write = function() end
  }
end

local args = parse_args({...})
local cfg = config.load(args.config or "configs/templates/network.example.json")
local logger = log.new("INFO", 200)
local reg = registry.new()

local peri = peripherals.new()
local modem = cc_modem.new({ channel = cfg.channel })
modem:open(cfg.channel)

local disp = dispatcher.new(cfg, {
  signals = create_signals.new(peri),
  switches = create_switches.new(peri)
})

local network = net.new(modem, cfg.channel, args.id or cfg.master_id, logger)

local monitor = peri.wrap("monitor") or fallback_monitor()
local ui = ui_core.new(monitor, {
  overview = overview_panel.new(disp, reg),
  diagnostics = diagnostics_panel.new(logger, disp)
})
ui.set_panel("overview")
ui.draw()

local heartbeat_timeout_s = 6
local timeout_timer = os.startTimer(1)
local ui_timer = os.startTimer(0.2)

while true do
  local event = { os.pullEvent() }

  if event[1] == "modem_message" then
    local msg = event[5]
    local status = network.receive(msg)

    if status == "ok" then
      if msg.type == "register" then
        reg.register(msg.src, msg.payload and msg.payload.role, nil)
        network.ack_for(msg)
        ui.mark_dirty()
      elseif msg.type == "heartbeat" then
        reg.heartbeat(msg.src)
        ui.mark_dirty()
      elseif msg.type == "event" and msg.payload and msg.payload.type == "sensor" then
        disp.on_sensor_event_by_sensor(msg.payload.sensor_id, msg.payload.action)
        network.ack_for(msg)
        ui.mark_dirty()
      elseif msg.type == "cmd" or msg.type == "ack" or msg.type == "err" then
        ui.mark_dirty()
      end
    end
  elseif event[1] == "monitor_touch" then
    ui.handle_touch(event[3], event[4])
  elseif event[1] == "timer" and event[2] == timeout_timer then
    local now = os.clock()
    for node_id, node_state in pairs(reg.all()) do
      if now - node_state.last_seen > heartbeat_timeout_s then
        reg.mark_down(node_id)
        disp.timeout_node(node_id)
        ui.mark_dirty()
      end
    end
    timeout_timer = os.startTimer(1)
  elseif event[1] == "timer" and event[2] == ui_timer then
    ui.draw()
    ui_timer = os.startTimer(0.2)
  end

  network.tick()
end
