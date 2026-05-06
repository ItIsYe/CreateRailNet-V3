--[[
Purpose: Common node runtime for register/heartbeat/command handling.
Public API: new(opts) -> node with start(), run(), handle_event(event), handle_message(msg).
]]

local net = require("src.shared.net")
local log = require("src.shared.log")
local time = require("src.shared.time")

local common_node = {}

function common_node.new(opts)
  local node = {
    id = opts.id,
    role = opts.role,
    config = opts.config,
    modem = opts.modem,
    logger = opts.logger or log.new("INFO", 200),
    handlers = opts.handlers or {},
    pull_event = opts.pull_event or os.pullEvent,
    heartbeat_ms = opts.heartbeat_ms or 2000
  }

  node.net = net.new(node.modem, node.config.channel, node.id, node.logger, time)

  function node.register()
    return node.net.send("register", node.config.master_id, { role = node.role })
  end

  function node.heartbeat()
    return node.net.heartbeat(node.config.master_id, { role = node.role })
  end

  function node.handle_message(msg)
    local status = node.net.receive(msg)
    if status ~= "ok" or msg.type ~= "cmd" then
      return status
    end

    local ok, err = true, nil
    if node.handlers.on_cmd then
      ok, err = node.handlers.on_cmd(msg.payload or {}, msg)
    end

    if ok == false then
      node.net.send("err", msg.src, { ref_id = msg.id, error = tostring(err) })
    else
      node.net.ack_for(msg)
    end

    return status
  end

  function node.handle_event(event)
    if event[1] == "timer" and event[2] == node.hb_timer then
      node.heartbeat()
      node.hb_timer = os.startTimer(node.heartbeat_ms / 1000)
    elseif event[1] == "modem_message" then
      node.handle_message(event[5])
    end

    if node.handlers.on_event then
      node.handlers.on_event(event)
    end

    node.net.tick()
  end

  function node.start()
    if node.modem and node.modem.open then
      local ok, err = node.modem:open(node.config.channel)
      if ok == false then
        node.logger.error("node modem open failed", { error = err })
      end
    end

    node.register()
    node.heartbeat()
    node.hb_timer = os.startTimer(node.heartbeat_ms / 1000)
  end

  function node.run()
    node.start()
    while true do
      node.handle_event({ node.pull_event() })
    end
  end

  return node
end

return common_node
