--[[
Purpose: Signal node entrypoint.
Public API: none (script).
]]

local create_signals = require("src.adapter.create_signals")
local common_node = require("src.nodes.common_node")
local bootstrap = require("src.nodes.bootstrap")

local context = bootstrap.create_context({...}, "signal")
local adapter = create_signals.new(context.peripherals, { hardware = context.hardware })

local node = common_node.new({
  id = context.id,
  role = context.role,
  config = context.config,
  modem = context.modem,
  logger = context.logger,
  handlers = {
    on_cmd = function(payload)
      if not payload or not payload.aspect then
        return false, "missing payload.aspect"
      end
      return adapter.setAspect(context.id, payload.aspect)
    end
  }
})

node.run()
