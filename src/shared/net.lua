--[[
Purpose: Reliable messaging with ack/retry/dedup and heartbeat helpers.
Public API: new(modem, channel, node_id, logger, time_mod).
Message ids are "<node>.<boot nonce>.<n>": every computer counts from 1 after a boot, so bare numbers collide between nodes and
between two boots of one node. Duplicates are recognised by sender and id.
]]

local time = require("src.shared.time")

local net = {}

-- differs between boots of the same node: real milliseconds plus a random part (several nets in one test process too)
local function boot_nonce()
  local epoch = os.epoch and os.epoch("utc") or ((os.time and os.time() or 0) * 1000)
  local jitter = math.random and math.random(0, 65535) or 0
  return string.format("%x%04x", epoch % 4294967296, jitter)
end

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
    retry_max = 5000,
    max_retries = 5
  }
  local id_prefix = tostring(node_id) .. "." .. boot_nonce()
  local sequence = 0
  local sequence_sent = 0
  local function next_id()
    sequence = sequence + 1
    return id_prefix .. "." .. sequence
  end

  local function send_raw(msg)
    if msg.dst == "broadcast" then
      return self.modem:broadcast(self.channel, msg)
    end
    return self.modem:send(self.channel, msg.dst, msg)
  end

  function self.send(msg_type, dst, payload)
    local msg = { v = 1, type = msg_type, id = next_id(), src = self.node_id, dst = dst, ts = now_ms(time_mod), payload = payload or {} }
    local ok, err = send_raw(msg)
    if ok == false then return nil, err end
    return msg
  end

  function self.send_reliable(msg_type, dst, payload)
    local msg, err = self.send(msg_type, dst, payload)
    if not msg then return nil, err end
    sequence_sent = sequence_sent + 1
    self.pending[msg.id] = { msg = msg, retry = 0, next_ts = now_ms(time_mod) + self.retry_min, seq = sequence_sent }
    return msg
  end

  function self.ack_for(msg) return self.send("ack", msg.src, { ack_id = msg.id }) end

  function self.receive(msg)
    if type(msg) ~= "table" then return "invalid" end
    if msg.v ~= 1 or type(msg.id) ~= "string" or type(msg.src) ~= "string" or type(msg.dst) ~= "string" or type(msg.type) ~= "string" then
      return "invalid"
    end
    if msg.dst ~= self.node_id and msg.dst ~= "broadcast" then return "not_for_me" end
    local key = msg.src .. "/" .. msg.id
    if self.dedup[key] then return "duplicate" end
    self.dedup[key] = now_ms(time_mod)
    if msg.type == "ack" and msg.payload and msg.payload.ack_id then
      self.pending[msg.payload.ack_id] = nil
      return "ack"
    end
    return "ok"
  end

  function self.tick()
    local now = now_ms(time_mod)
    -- oldest message first: retries go out in the order the messages were sent, whatever pairs() would say
    local due = {}
    for id, entry in pairs(self.pending) do
      if now >= entry.next_ts then due[#due + 1] = id end
    end
    table.sort(due, function(a, b) return self.pending[a].seq < self.pending[b].seq end)
    for _, id in ipairs(due) do
      local entry = self.pending[id]
      if entry then
        if entry.retry >= self.max_retries then
          self.pending[id] = nil
          if self.logger then self.logger.error("net max retries exceeded", { id = id, type = entry.msg.type, dst = entry.msg.dst }) end
          -- Fire on_drop callback so callers can react (e.g. mark node down)
          if self.on_drop then pcall(self.on_drop, entry.msg) end
        else
          entry.retry = entry.retry + 1
          local backoff = math.min(self.retry_max, self.retry_min * (2 ^ (entry.retry - 1)))
          entry.next_ts = now + backoff
          send_raw(entry.msg)
          if self.logger then self.logger.warn("net retry", { id = id, retry = entry.retry }) end
        end
      end
    end
    for id, ts in pairs(self.dedup) do if now - ts > self.dedup_ttl then self.dedup[id] = nil end end
  end

  function self.heartbeat(dst, payload) return self.send("heartbeat", dst, payload) end
  return self
end

return net
