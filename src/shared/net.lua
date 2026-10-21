--[[
Purpose: Reliable messaging with ack/retry/dedup and heartbeat helpers.
Public API: new(modem, channel, node_id, logger, time_mod), validate(msg) -> ok, reason, PROTOCOL_VERSION, PROTOCOL_REVISION.
  net instance: send, send_reliable, ack_for(msg, applied), receive, tick, heartbeat, peer_revision(node_id), on_drop, on_ack.
Envelope: v is the major version and must match; pv is the revision (additive changes only, older nodes send none and count as 1).
Receivers reject malformed envelopes (wrong types, oversize ids, unknown message types) instead of guessing.
An ack says "delivered"; ack_for(msg, true) adds applied = true: the receiver also did what the message asked.
Gate, hold and stamp (high availability): net.new(..., { gate = fn(type, dst, payload) -> ok | "hold", reason, hold = fn(key, run, meta), stamp = fn(type, dst, payload), mirrors = { [primary] = { other ids } } }).
A gate that answers "hold" gives the command to hold(key, run, meta) (the commit barrier, src/master/barrier.lua), which carries it out later through the same net.
A message the gate refuses is not sent (send returns nil, reason) and a pending message it refuses at retry time is dropped without on_drop; stamp adds fields to the payload before it is signed.
Mirrors: a register / heartbeat / event sent to a primary id goes to the other ids as well, each as a message of its own (a node reports to both masters).
Authentication (revision 5, optional per computer): net.new(..., { auth = auth }) signs every message and checks every message it receives (src/shared/auth.lua):
a message that fails is not "ok" ("auth_failed", reason as second result); "challenge" / "auth" are the session handshake after a restart. After receive,
msg.authenticated is true only for a message whose MAC was valid (it is always overwritten, whatever the sender wrote).
Message ids are "<node>.<boot nonce>.<n>": every computer counts from 1 after a boot, so bare numbers collide between nodes and
between two boots of one node. Duplicates are recognised by sender and id.
]]

local time = require("src.shared.time")

local net = {}

net.PROTOCOL_VERSION = 1
net.PROTOCOL_REVISION = 5

local MAX_ID_LENGTH = 160
local MAX_NODE_LENGTH = 64
local MAX_PEERS = 1024
local VALID_TYPES = { register = true, heartbeat = true, cmd = true, event = true, ack = true, err = true, auth = true }

function net.validate(msg)
  if type(msg) ~= "table" then return false, "not a table" end
  if msg.v ~= net.PROTOCOL_VERSION then return false, "protocol version " .. tostring(msg.v) end
  if type(msg.id) ~= "string" or msg.id == "" or #msg.id > MAX_ID_LENGTH then return false, "bad id" end
  if type(msg.src) ~= "string" or msg.src == "" or #msg.src > MAX_NODE_LENGTH then return false, "bad src" end
  if type(msg.dst) ~= "string" or msg.dst == "" or #msg.dst > MAX_NODE_LENGTH then return false, "bad dst" end
  if not VALID_TYPES[msg.type] then return false, "unknown type " .. tostring(msg.type) end
  if msg.payload ~= nil and type(msg.payload) ~= "table" then return false, "payload is not a table" end
  if msg.ts ~= nil and type(msg.ts) ~= "number" then return false, "bad ts" end
  if msg.pv ~= nil and type(msg.pv) ~= "number" then return false, "bad pv" end
  if msg.at ~= nil and type(msg.at) ~= "string" then return false, "bad at" end
  if msg.ss ~= nil and type(msg.ss) ~= "string" then return false, "bad ss" end
  if msg.ch ~= nil and type(msg.ch) ~= "string" then return false, "bad ch" end
  if msg.sq ~= nil and type(msg.sq) ~= "number" then return false, "bad sq" end
  if msg.ke ~= nil and type(msg.ke) ~= "number" then return false, "bad ke" end
  return true
end

-- differs between boots of the same node: real milliseconds plus a random part, the processor time in microseconds and a count of the nets made in this
-- process (several nets of one node id in one second must not meet: the master drops the second message as a duplicate)
local nets_made = 0
local function boot_nonce()
  nets_made = nets_made + 1
  local epoch = os.epoch and os.epoch("utc") or ((os.time and os.time() or 0) * 1000)
  local jitter = math.random and math.random(0, 65535) or 0
  local ticks = math.floor((os.clock and os.clock() or 0) * 1000000) % 4294967296
  return string.format("%xk%04xk%xk%x", epoch % 4294967296, jitter, ticks, nets_made)
end

local function now_ms(time_mod)
  return (time_mod and time_mod.now_ms or time.now_ms)()
end

function net.new(modem, channel, node_id, logger, time_mod, opts)
  local self = {
    auth = opts and opts.auth,
    gate = opts and opts.gate,
    hold = opts and opts.hold,
    stamp = opts and opts.stamp,
    modem = modem,
    channel = channel,
    node_id = node_id,
    logger = logger,
    pending = {},
    dedup = {},
    peers = {},
    dedup_ttl = 30000,
    retry_min = 200,
    retry_max = 5000,
    max_retries = 5
  }
  local id_prefix = tostring(node_id) .. "." .. boot_nonce()
  local sequence = 0
  local sequence_sent = 0
  local peer_count = 0
  -- tick() runs after every event; with hundreds of nodes that is hundreds of calls a second, so it only walks the tables when
  -- something can be due: the earliest retry time is tracked, the dedup table is pruned once a second
  local min_due = math.huge
  local last_prune = nil
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

  local track
  local function send_one(msg_type, dst, payload, reliable, bypass)
    if self.gate then
      local allowed, why = self.gate(msg_type, dst, payload or {})
      if not allowed then return nil, why or "refused by the gate" end
      if allowed == "hold" and not bypass and self.hold then
        -- movement-giving commands wait until both masters have the state they depend on; the key lets a newer command of the same kind replace an older one
        local key = "cmd:" .. tostring(dst) .. ":" .. tostring((payload or {}).cmd) .. ":" .. tostring((payload or {}).train_id or (payload or {}).signal_id or (payload or {}).switch_id or "")
        self.hold(key, function()
          local sent = send_one(msg_type, dst, payload, reliable, true)
          if sent and reliable then track(sent) end
        end, { payload = payload })
        return { id = "held", held = true }
      end
    end
    if self.stamp then self.stamp(msg_type, dst, payload or {}) end
    local msg = { v = net.PROTOCOL_VERSION, pv = net.PROTOCOL_REVISION, type = msg_type, id = next_id(), src = self.node_id, dst = dst, ts = now_ms(time_mod), payload = payload or {} }
    if self.auth then self.auth.sign(msg) end
    local ok, err = send_raw(msg)
    if ok == false then return nil, err end
    return msg
  end

  local MIRRORED_TYPES = { register = true, heartbeat = true, event = true }

  function self.send(msg_type, dst, payload)
    local msg, err = send_one(msg_type, dst, payload, false)
    local others = opts and opts.mirrors and MIRRORED_TYPES[msg_type] and opts.mirrors[dst]
    if others then
      for _, other in ipairs(others) do
        -- a copy of the payload: stamping or signing one message must not change the other
        local copy = {}
        for k, v in pairs(payload or {}) do copy[k] = v end
        send_one(msg_type, other, copy, false)
      end
    end
    return msg, err
  end

  function track(msg)
    sequence_sent = sequence_sent + 1
    local entry = { msg = msg, retry = 0, next_ts = now_ms(time_mod) + self.retry_min, seq = sequence_sent }
    self.pending[msg.id] = entry
    if entry.next_ts < min_due then min_due = entry.next_ts end
  end

  function self.send_reliable(msg_type, dst, payload)
    local msg, err = send_one(msg_type, dst, payload, true)
    if msg and not msg.held then track(msg) end
    local others = opts and opts.mirrors and MIRRORED_TYPES[msg_type] and opts.mirrors[dst]
    if others then
      for _, other in ipairs(others) do
        local copy = {}
        for k, v in pairs(payload or {}) do copy[k] = v end
        local mirrored = send_one(msg_type, other, copy, true)
        if mirrored and not mirrored.held then track(mirrored) end
      end
    end
    if not msg then return nil, err end
    return msg
  end

  -- stops the retries of the pending messages the predicate names (their senders have decided the messages are void)
  function self.cancel_pending(predicate)
    local doomed = {}
    for id, entry in pairs(self.pending) do if predicate(entry.msg) then doomed[#doomed + 1] = id end end
    for _, id in ipairs(doomed) do self.pending[id] = nil end
    return #doomed
  end

  function self.ack_for(msg, applied) return self.send("ack", msg.src, { ack_id = msg.id, applied = applied and true or nil }) end

  -- the protocol revision a node announced in its messages (1 for nodes that send none), nil for strangers
  function self.peer_revision(node_id) return self.peers[node_id] end

  function self.receive(msg)
    if not net.validate(msg) then return "invalid" end
    if msg.dst ~= self.node_id and msg.dst ~= "broadcast" then return "not_for_me" end
    if self.auth and self.auth.mode ~= "off" then
      msg.authenticated = false
      local verdict, detail, extra = self.auth.verify(msg)
      if verdict == "challenge" then
        -- valid MAC, unknown session: hand out a nonce instead of processing; the sender repeats what it sent with it
        self.send("auth", msg.src, { kind = "challenge", for_ss = msg.ss, nonce = detail, ss = self.auth.session })
        return "challenge"
      elseif verdict == "duplicate" then
        msg.authenticated = true
        return "duplicate"
      elseif verdict == "challenge_accepted" then
        -- the other side now gets a challenge of ours too (its session is in the one it sent), so its answers are not lost either
        local nonce = self.auth.counter_challenge(msg.src, extra)
        if nonce then self.send("auth", msg.src, { kind = "challenge", for_ss = extra, nonce = nonce }) end
        local waiting = {}
        for id, entry in pairs(self.pending) do if entry.msg.dst == msg.src then waiting[#waiting + 1] = id end end
        table.sort(waiting, function(a, b) return self.pending[a].seq < self.pending[b].seq end)
        for _, id in ipairs(waiting) do
          local entry = self.pending[id]
          self.auth.resign(entry.msg)
          send_raw(entry.msg)
        end
        return "auth"
      elseif verdict == "reject" then
        return "auth_failed", detail
      end
      msg.authenticated = verdict == "ok"
    end
    local known = self.peers[msg.src] ~= nil
    if known or peer_count < MAX_PEERS then
      if not known then peer_count = peer_count + 1 end
      self.peers[msg.src] = msg.pv or 1
    end
    local key = msg.src .. "/" .. msg.id
    if self.dedup[key] then return "duplicate" end
    self.dedup[key] = now_ms(time_mod)
    if msg.type == "ack" and msg.payload and msg.payload.ack_id then
      local entry = self.pending[msg.payload.ack_id]
      self.pending[msg.payload.ack_id] = nil
      if self.on_ack then pcall(self.on_ack, msg.payload, entry and entry.msg) end
      return "ack"
    end
    return "ok"
  end

  local function retry_due(now)
    -- oldest message first: retries go out in the order the messages were sent, whatever pairs() would say
    local due = {}
    local earliest_waiting = math.huge
    for id, entry in pairs(self.pending) do
      if now >= entry.next_ts then
        due[#due + 1] = id
      elseif entry.next_ts < earliest_waiting then
        earliest_waiting = entry.next_ts
      end
    end
    table.sort(due, function(a, b) return self.pending[a].seq < self.pending[b].seq end)
    -- anything sent from inside the loop (a drop handler may send) lowers min_due again by itself
    min_due = math.huge
    for _, id in ipairs(due) do
      local entry = self.pending[id]
      if entry then
        if self.gate and not self.gate(entry.msg.type, entry.msg.dst, entry.msg.payload or {}) then
          -- a command queued while this computer was the leader is not sent on after it stopped being one
          self.pending[id] = nil
        elseif entry.retry >= self.max_retries then
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
          if entry.next_ts < earliest_waiting then earliest_waiting = entry.next_ts end
        end
      end
    end
    if earliest_waiting < min_due then min_due = earliest_waiting end
  end

  function self.tick()
    local now = now_ms(time_mod)
    if now >= min_due then retry_due(now) end
    if not last_prune or now - last_prune >= 1000 then
      last_prune = now
      for id, ts in pairs(self.dedup) do if now - ts > self.dedup_ttl then self.dedup[id] = nil end end
    end
  end

  function self.heartbeat(dst, payload) return self.send("heartbeat", dst, payload) end
  return self
end

return net
