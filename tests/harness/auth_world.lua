--[[
Purpose: Computers with real nets, keys and authentication on a simulated link, for the tests of the V3 trust layer and everything that rides on it.
Public API: new(opts) -> world with master(id, o), node(id, o), stranger(id), step(ms, n), settle(ms), restart(entity), capture(), link, trust, master_key, rng.
  opts: seed, drop, duplicate, delay_max_ms, masters (ids of all masters, default { "M" }; every computer is told the list at its start), mode ("off" | "monitor" | "enforce", default "enforce").
  entity: { id, net, auth, inbox (list of { msg, status, detail }), keyring, key_record, on_ok(msg) }; messages that arrive "ok" are answered with an applied ack unless
  entity.auto_ack = false. world.captured is a list of every message that was put on the link, as the sender wrote it (for replay and tamper tests).
Notes: time is the virtual clock of the link; every net and auth of the world reads it. restart(entity) makes a fresh net and auth for the same id and key
  (a computer that rebooted: new session, nothing remembered).
]]

local net = require("src.shared.net")
local auth = require("src.shared.auth")
local auth_setup = require("src.shared.auth_setup")
local keyring = require("src.shared.keyring")
local keystore = require("src.shared.keystore")
local sha256 = require("src.shared.sha256")
local prng = require("tests.harness.prng")
local lossy_link = require("tests.harness.lossy_link")

local world_mod = {}

local function quiet_logger()
  local function noop() end
  return { info = noop, warn = noop, error = noop, debug = noop }
end

function world_mod.new(opts)
  opts = opts or {}
  local rng = prng.new(opts.seed or 1)
  local link = lossy_link.new(rng, { drop = opts.drop, duplicate = opts.duplicate, delay_max_ms = opts.delay_max_ms, drop_acks = opts.drop_acks })
  local w = {
    link = link, rng = rng, entities = {}, captured = {},
    master_key = sha256.hex("master key of the test world"),
    trust = { rev = 0, nodes = {} },
    mode = opts.mode or "enforce",
    master_ids = opts.masters or { "M" }
  }
  local clock = { now_ms = function() return link.now() end }

  -- everything put on the link is also copied into w.captured
  local function recording_modem(id)
    local inner = link.modem(id)
    return {
      id = id,
      open = inner.open,
      send = function(self, channel, dst, msg)
        local copy = {}
        for k, v in pairs(msg) do copy[k] = v end
        w.captured[#w.captured + 1] = copy
        return inner.send(self, channel, dst, msg)
      end,
      broadcast = function(self, channel, msg)
        local copy = {}
        for k, v in pairs(msg) do copy[k] = v end
        w.captured[#w.captured + 1] = copy
        return inner.broadcast(self, channel, msg)
      end
    }
  end

  local function build_net(e)
    local ring
    if e.kind == "master" then
      ring = keyring.master({ id = e.id, master_key = w.master_key, trust = w.trust, masters = w.master_ids })
    else
      ring = keyring.node({ id = e.id, key = e.key_record and e.key_record.key, epoch = e.key_record and e.key_record.epoch, masters = w.master_ids })
    end
    e.keyring = ring
    e.auth = w.mode ~= "off" and auth.new({
      node_id = e.id, mode = w.mode, keyring = ring, now_ms = clock.now_ms,
      open_events = auth_setup.OPEN_EVENTS, open_cmds = auth_setup.OPEN_CMDS, entropy = function() return e.id .. tostring(#w.captured) end
    }) or nil
    e.net = net.new(recording_modem(e.id), 1, e.id, quiet_logger(), clock, { auth = e.auth })
  end

  local function attach(e)
    link.set_receiver(e.id, function(msg)
      local status, detail = e.net.receive(msg)
      e.inbox[#e.inbox + 1] = { msg = msg, status = status, detail = detail }
      if status == "ok" and e.auto_ack ~= false and (msg.type == "event" or msg.type == "cmd" or msg.type == "register") then e.net.ack_for(msg, true) end
      if status == "ok" and e.on_ok then e.on_ok(msg) end
    end)
  end

  local function new_entity(id, kind)
    local e = { id = id, kind = kind, inbox = {} }
    w.entities[id] = e
    return e
  end

  function w.master(id)
    local known = false
    for _, listed in ipairs(w.master_ids) do if listed == id then known = true end end
    assert(known, "master " .. id .. " is not in opts.masters")
    local e = new_entity(id, "master")
    build_net(e)
    attach(e)
    return e
  end

  -- a computer with a key issued by the masters (or none, with o.no_key)
  function w.node(id, o)
    o = o or {}
    local e = new_entity(id, "node")
    if not o.no_key then e.key_record = keystore.issue(w.trust, w.master_key, id, o.role or "signal", 0) end
    build_net(e)
    attach(e)
    return e
  end

  -- an attacker: its own name, a key it made up (or none), no entry in the trust list
  function w.stranger(id, key)
    local e = new_entity(id, "node")
    e.key_record = key and { id = id, key = key, epoch = 1 } or nil
    build_net(e)
    attach(e)
    return e
  end

  function w.restart(e)
    build_net(e)
    attach(e)
    e.inbox = {}
  end

  function w.step(ms, count)
    for _ = 1, count or 1 do
      link.advance(ms)
      for _, e in pairs(w.entities) do e.net.tick() end
    end
  end

  function w.settle(ms) w.step(50, math.ceil((ms or 3000) / 50)) end

  function w.statuses(e)
    local counts = {}
    for _, item in ipairs(e.inbox) do counts[item.status] = (counts[item.status] or 0) + 1 end
    return counts
  end

  function w.close() link.close() end
  return w
end

return world_mod
