--[[
Purpose: Switch node entrypoint.
Public API: none (script).
]]

local create_switches = require("src.adapter.create_switches")
local common_node = require("src.nodes.common_node")
local bootstrap = require("src.nodes.bootstrap")

local context = bootstrap.create_context({...}, "switch")
local adapter = create_switches.new(context.peripherals)

local node = common_node.new({
  id = context.id,
  role = context.role,
  config = context.config,
  modem = context.modem,
  logger = context.logger,
  handlers = {
    on_cmd = function(payload)
      if not payload or not payload.position then
        return false, "missing payload.position"
      end
      return adapter.setPosition(context.id, payload.position)
    end
  }
})

node.run()
