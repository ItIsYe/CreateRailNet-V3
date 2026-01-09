--[[
Purpose: Common node runtime for register/heartbeat/command handling.
Public API: new(opts) -> node with start().
]]

local net = require("src.shared.net")
local log = require("src.shared.log")
local time = require("src.shared.time")

local common_node = {}

function common_node.new(opts)
  local node = {}
  node.id = opts.id
  node.role = opts.role
  node.config = opts.config
  node.modem = opts.modem
  node.logger = opts.logger or log.new("INFO", 200)
  node.handlers = opts.handlers or {}
  node.net = net.new(node.modem, node.config.channel, node.id, node.logger, time)

  function node.register()
    node.net.send("register", node.config.master_id, { role = node.role })
  end

  function node.heartbeat()
    node.net.heartbeat(node.config.master_id, { role = node.role })
  end

  function node.handle_message(msg)
    local status = node.net.receive(msg)
    if status == "ok" and msg.type == "cmd" and node.handlers.on_cmd then
      node.handlers.on_cmd(msg.payload)
      node.net.ack_for(msg)
    end
  end

  function node.start()
    node.register()
    node.heartbeat()
  end

  return node
end

return common_node
