--[[
Purpose: Signal node entrypoint and runtime factory.
Public API: new_runtime(args_or_context).
]]

local create_signals = require("src.adapter.create_signals")
local common_node = require("src.nodes.common_node")
local bootstrap = require("src.nodes.bootstrap")

local signal_node = {}

local function build_context(args_or_context)
  if args_or_context.config and args_or_context.logger and args_or_context.peripherals and args_or_context.modem then return args_or_context end
  return bootstrap.create_context({ "--id", args_or_context.id, "--config", args_or_context.config }, "signal")
end

function signal_node.new_runtime(args_or_context)
  local context = build_context(args_or_context)
  local adapter = create_signals.new(context.peripherals, { hardware = context.hardware })
  return common_node.new({
    id = context.id,
    role = context.role,
    config = context.config,
    modem = context.modem,
    logger = context.logger,
    handlers = {
      on_cmd = function(payload)
        if not payload or not payload.aspect then return false, "missing payload.aspect" end
        return adapter.setAspect(context.id, payload.aspect)
      end
    }
  })
end

local raw = {...}
if raw and raw[1] == "--run" then signal_node.new_runtime(bootstrap.create_context(raw, "signal")).run() end

return signal_node
