--[[
Purpose: Reliable messaging with ack/retry/dedup and heartbeat helpers.
Public API: new(modem, channel, node_id, logger, time_mod).
]]

local util = require("src.shared.util")
local time = require("src.shared.time")

local net = {}

local function now_ms(time_mod)
  return (time_mod and time_mod.now_ms or time.now_ms)()
end

function net.new(modem, channel, node_id, logger, time_mod)
  local self = {
    modem = modem,
    channel = channel,
    node_id = node_id,
    logger = logger,
    pending = {},
    dedup = {},
    dedup_ttl = 30000,
    retry_min = 200,
    retry_max = 5000
  }

  local function send_raw(msg)
    if msg.dst == "broadcast" then
      self.modem:broadcast(self.channel, msg)
    else
      self.modem:send(self.channel, msg.dst, msg)
    end
  end

  function self.send(msg_type, dst, payload)
    local msg = {
      v = 1,
      type = msg_type,
      id = util.gen_id("msg"),
      src = self.node_id,
      dst = dst,
      ts = now_ms(time_mod),
      payload = payload or {}
    }
    send_raw(msg)
    return msg
  end

  function self.send_reliable(msg_type, dst, payload)
    local msg = self.send(msg_type, dst, payload)
    self.pending[msg.id] = {
      msg = msg,
      retry = 0,
      next_ts = now_ms(time_mod) + self.retry_min
    }
    return msg
  end

  function self.ack_for(msg)
    local ack = self.send("ack", msg.src, { ack_id = msg.id })
    return ack
  end

  function self.receive(msg)
    if self.dedup[msg.id] then
      return "duplicate"
    end
    self.dedup[msg.id] = now_ms(time_mod)
    if msg.type == "ack" and msg.payload and msg.payload.ack_id then
      self.pending[msg.payload.ack_id] = nil
      return "ack"
    end
    return "ok"
  end

  function self.tick()
    local now = now_ms(time_mod)
    for id, entry in pairs(self.pending) do
      if now >= entry.next_ts then
        entry.retry = entry.retry + 1
        local backoff = math.min(self.retry_max, self.retry_min * (2 ^ (entry.retry - 1)))
        entry.next_ts = now + backoff
        send_raw(entry.msg)
        if self.logger then
          self.logger.warn("net retry", { id = id, retry = entry.retry })
        end
      end
    end
    for id, ts in pairs(self.dedup) do
      if now - ts > self.dedup_ttl then
        self.dedup[id] = nil
      end
    end
  end

  function self.heartbeat(dst, payload)
    return self.send("heartbeat", dst, payload)
  end

  return self
end

return net
