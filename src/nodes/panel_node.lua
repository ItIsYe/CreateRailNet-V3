--[[
Purpose: External panel node for remote display/touch UI.
Public API: new_runtime(context_or_args), render_status(monitor, state).
]]

local config = require("src.shared.config")
local log = require("src.shared.log")
local shared_args = require("src.shared.args")
local peripherals = require("src.adapter.peripherals")
local hardware_config = require("src.adapter.hardware_config")
local cc_modem = require("src.adapter.cc_modem")
local common_node = require("src.nodes.common_node")
local bootstrap = require("src.nodes.bootstrap")
local panel_state = require("src.domain.panel_state")
local renderer = require("src.nodes.panel_renderer")

local panel_node = {}

local function build_context(args_or_context)
  if args_or_context.config and args_or_context.logger and args_or_context.peripherals and args_or_context.modem then
    return args_or_context
  end

  local cfg = config.load(args_or_context.config or "configs/templates/network.example.json")
  return {
    id = args_or_context.id,
    role = "panel",
    config = cfg,
    logger = log.new("INFO", 200),
    peripherals = peripherals.new(),
    hardware = hardware_config.new(cfg),
    modem = cc_modem.new({ channel = cfg.channel })
  }
end

local function find_panel_config(cfg, node_id)
  for _, node in ipairs(cfg.nodes or {}) do
    if node.id == node_id then return node end
  end
  return { id = node_id, role = "panel" }
end

function panel_node.render_status(monitor, state)
  renderer.render(monitor, state)
end

function panel_node.new_runtime(args_or_context)
  local context = build_context(args_or_context)
  local panel_cfg = find_panel_config(context.config, context.id)
  local monitor_name = panel_cfg.monitor or "monitor"
  local monitor = context.peripherals.wrap(monitor_name)
  local state_model = panel_state.new(context.config, context.id)

  local node = common_node.new({
    id = context.id,
    role = context.role,
    config = context.config,
    modem = context.modem,
    logger = context.logger,
    handlers = {
      on_cmd = function(payload)
        local cmd = payload and payload.cmd
        if cmd == "panel_update" then
          state_model.update(payload)
        elseif cmd == "set_page" then
          state_model.set_page(payload.page)
        elseif cmd == "next_page" then
          state_model.next_page()
        elseif cmd == "previous_page" then
          state_model.previous_page()
        else
          return false, "unknown panel cmd: " .. tostring(cmd)
        end
        panel_node.render_status(monitor, state_model.snapshot())
        return true
      end
    }
  })

  node.register = function()
    return node.net.send("register", context.config.master_id, {
      role = "panel",
      panel_id = context.id,
      display_name = panel_cfg.display_name or context.id,
      page = state_model.snapshot().page
    })
  end

  node.heartbeat = function()
    return node.net.heartbeat(context.config.master_id, {
      role = "panel",
      panel_id = context.id,
      display_name = panel_cfg.display_name or context.id,
      page = state_model.snapshot().page
    })
  end

  local function request_snapshot()
    node.net.send("event", context.config.master_id, {
      type = "panel_request_snapshot",
      panel_id = context.id,
      page = state_model.snapshot().page
    })
  end

  local old_start = node.start
  node.start = function()
    old_start()
    panel_node.render_status(monitor, state_model.snapshot())
    request_snapshot()
    node.panel_timer = os.startTimer(panel_cfg.refresh_seconds or 2)
  end

  node.handlers.on_event = function(event)
    if event[1] == "timer" and event[2] == node.panel_timer then
      request_snapshot()
      panel_node.render_status(monitor, state_model.snapshot())
      node.panel_timer = os.startTimer(panel_cfg.refresh_seconds or 2)
    elseif event[1] == "monitor_touch" then
      local x = event[3]
      local y = event[4]
      if y <= 3 then
        if x <= 10 then
          state_model.previous_page()
        else
          state_model.next_page()
        end
        request_snapshot()
        panel_node.render_status(monitor, state_model.snapshot())
      end
    end
  end

  return node
end

local args = shared_args.parse({...}, { config = {}, id = {} })
if args.id then
  panel_node.new_runtime(bootstrap.create_context({...}, "panel")).run()
end

return panel_node
