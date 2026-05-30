--[[
Purpose: Switch node entrypoint and runtime factory.
Public API: new_runtime(args_or_context).
]]

local create_switches = require("src.adapter.create_switches")
local common_node = require("src.nodes.common_node")
local bootstrap = require("src.nodes.bootstrap")

local switch_node = {}

local function build_context(args_or_context)
  if args_or_context.config and args_or_context.logger and args_or_context.peripherals and args_or_context.modem then return args_or_context end
  return bootstrap.create_context({ "--id", args_or_context.id, "--config", args_or_context.config }, "switch")
end

function switch_node.new_runtime(args_or_context)
  local context = build_context(args_or_context)
  local adapter = create_switches.new(context.peripherals, { hardware = context.hardware })
  return common_node.new({
    id = context.id,
    role = context.role,
    config = context.config,
    modem = context.modem,
    logger = context.logger,
    handlers = {
      on_cmd = function(payload)
        if not payload or not payload.position then return false, "missing payload.position" end
        return adapter.setPosition(context.id, payload.position)
      end
    }
  })
end

local raw = {...}
if raw and raw[1] == "--run" then switch_node.new_runtime(bootstrap.create_context(raw, "switch")).run() end

return switch_node
