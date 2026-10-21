--[[
Purpose: Master A, master B, the arbiter and two node simulators with real runtimes, dispatchers, nets, elections, replicas and barriers on a simulated network; the hardware (signals, switches) is a recording fake.
Public API: new(opts) -> world with masters[id] = { id, runtime, dispatcher, network, ha, replica, barrier, hw, fs, alive }, arbiter, nodes[id] = { net, inbox, send_event(payload), heartbeat() }, link,
  step(ms, n), run(ms), crash(id), restart(id), isolate(id) / heal_all(), leader() -> id | nil, request(train_id, route_id) (the train asks the masters), calls(id, kind) -> hardware calls of that master, close().
  opts: seed, drop, delay_max_ms, hold_after_ack (nil)
Notes: time is the virtual clock of the link (os.clock is replaced until close()). The topology is small and fixed: blocks B1 (switch SW-1), B2, B3; routes R1 (B1, B2) and R2 (B2, B3).
  hw.calls on a master lists { kind = "signal" | "switch", id, value } in the order the real adapters were called (after the commit barrier); hw.drop = true makes the fake swallow calls (a crash before actuation).
]]

local net = require("src.shared.net")
local time = require("src.shared.time")
local dispatcher_module = require("src.master.dispatcher")
local runtime_factory = require("src.master.runtime")
local registry_factory = require("src.shared.registry")
local alerts_module = require("src.domain.alerts")
local trains_module = require("src.domain.trains")
local stations_module = require("src.domain.stations")
local depots_module = require("src.domain.depots")
local service_plans_module = require("src.domain.service_plans")
local route_resolver = require("src.domain.route_resolver")
local route_integration = require("src.master.route_integration")
local ha_wiring = require("src.master.ha_wiring")
local election_store = require("src.shared.election_store")
local journal_module = require("src.shared.journal")
local arbiter_node = require("src.nodes.arbiter_node")
local memfs = require("tests.harness.memfs")
local prng = require("tests.harness.prng")
local lossy_link = require("tests.harness.lossy_link")

local world_mod = {}

local A, B, ARB = "MASTER-A", "MASTER-B", "ARBITER-1"
world_mod.A, world_mod.B, world_mod.ARB = A, B, ARB

local quiet = { info = function() end, warn = function() end, error = function() end, debug = function() end }

local function plan()
  return {
    v = 1, channel = 1, master_id = A, masters = { A, B }, arbiter = ARB, heartbeat_timeout_s = 600, sensor_guard_min_occupy_ms = 0,
    blocks = {
      { id = "B1", entry_signal = "SE1", exit_signal = "SX1", sensors = { "SEN-1" }, switches = { { id = "SW-1", position = "DIVERGING" } } },
      { id = "B2", entry_signal = "SE2", exit_signal = "SX2", sensors = { "SEN-2" }, switches = {} },
      { id = "B3", entry_signal = "SE3", exit_signal = "SX3", sensors = { "SEN-3" }, switches = {} },
    },
    routes = {
      { id = "R1", from = "ST-A", to = "ST-B", blocks = { "B1", "B2" }, priority = 5 },
      { id = "R2", from = "ST-B", to = "ST-C", blocks = { "B2", "B3" }, priority = 5 },
    },
    nodes = {
      { id = A, role = "master" }, { id = B, role = "master" }, { id = ARB, role = "arbiter" },
      { id = "SEN-1", role = "sensor" }, { id = "SEN-2", role = "sensor" }, { id = "SEN-3", role = "sensor" },
      { id = "TRAIN-1", role = "train", train_id = "TRAIN-1" }, { id = "TRAIN-2", role = "train", train_id = "TRAIN-2" },
    }
  }
end

function world_mod.new(opts)
  opts = opts or {}
  local rng = prng.new(opts.seed or 1)
  local link = lossy_link.new(rng, { drop = opts.drop, delay_max_ms = opts.delay_max_ms })
  local w = { link = link, masters = {}, nodes = {}, files = {}, blocked = {}, rng = rng }

  -- a computer that is isolated neither hears nor is heard
  local function modem_for(id)
    local inner = link.modem(id)
    return {
      id = id, open = inner.open,
      send = function(self, channel, dst, msg) if w.blocked[id] or w.blocked[dst] then return true end return inner.send(self, channel, dst, msg) end,
      broadcast = function(self, channel, msg) if w.blocked[id] then return true end return inner.broadcast(self, channel, msg) end
    }
  end

  local function fs_of(name) w.files[name] = w.files[name] or memfs.new(); return w.files[name] end

  -- one master ---------------------------------------------------------------------------------------------------------
  local function build_master(m)
    local cfg = plan()
    m.cfg = cfg
    m.hw = { calls = {}, drop = false }
    local function record(kind) return function(id, value) if not m.hw.drop then m.hw.calls[#m.hw.calls + 1] = { kind = kind, id = id, value = value } end return true end end
    local base_signals = { setAspect = record("signal"), getState = function() return true, "RED" end }
    local base_switches = { setPosition = record("switch") }
    local prep = ha_wiring.prepare(cfg, m.id, { now_ms = time.now_ms, logger = quiet })
    m.dispatcher = dispatcher_module.new(cfg, { signals = prep.signals(base_signals), switches = prep.switches(base_switches) })
    m.network = net.new(modem_for(m.id), 1, m.id, quiet, time)
    local wired = ha_wiring.finish(prep, {
      network = m.network, dispatcher = m.dispatcher, logger = quiet, now_ms = time.now_ms,
      election_store = election_store.new(nil, { fs = fs_of(m.id .. ":election") }),
      journal = journal_module.new("state/master_journal.log", { fs = fs_of(m.id .. ":journal"), max_entries = 1000, max_bytes = 300000 })
    })
    m.ha, m.replica, m.barrier, m.journal = wired.ha, wired.replica, wired.barrier, wired.journal
    m.registry = registry_factory.new()
    m.alerts = alerts_module.new()
    m.audits = {}
    m.timers, m.timer_id = {}, 0
    local context = {
      config = cfg, registry = m.registry, dispatcher = m.dispatcher, network = m.network, alerts = m.alerts, ha = m.ha, replica = m.replica, barrier = m.barrier,
      ui = { mark_dirty = function() end, draw = function() end, handle_touch = function() end },
      audit_log = { record = function(kind, data) m.audits[#m.audits + 1] = { kind = kind, data = data } end },
      train_registry = trains_module.new(cfg), station_registry = stations_module.new(cfg), depot_registry = depots_module.new(cfg),
      service_plan_registry = service_plans_module.new(cfg), route_resolver = route_resolver.new(cfg.routes),
      maintenance = { is_enabled = function() return false end }, logger = quiet,
      manual_control = { handle = function() return true end },
      clock = function() return link.now() / 1000 end,
      start_timer = function(seconds) m.timer_id = m.timer_id + 1; m.timers[#m.timers + 1] = { id = m.timer_id, due = link.now() + seconds * 1000 }; return m.timer_id end,
      auto_restore_state = false, auto_save_state = false
    }
    context.route_integration = route_integration.new(context)
    m.runtime = runtime_factory.new(context)
    m.alive = true
    link.set_receiver(m.id, function(msg)
      if m.alive and not w.blocked[m.id] then m.runtime.handle_event({ "modem_message", "x", 1, 1, msg }) end
    end)
    m.runtime.start()
  end

  for _, id in ipairs({ A, B }) do
    local m = { id = id }
    w.masters[id] = m
    build_master(m)
  end

  -- the arbiter -----------------------------------------------------------------------------------------------------------
  local function build_arbiter()
    w.arbiter = arbiter_node.new_runtime({
      id = ARB, config = plan(), logger = quiet, modem = modem_for(ARB),
      election_fs = fs_of(ARB .. ":election"), fence_fs = fs_of(ARB .. ":fence"), topology_fs = fs_of(ARB .. ":topology")
    })
    link.set_receiver(ARB, function(msg) if w.arbiter_alive ~= false and not w.blocked[ARB] then w.arbiter.handle_event({ "modem_message", "x", 1, 1, msg }) end end)
  end
  build_arbiter()

  -- node simulators: events to both masters, commands recorded and answered -------------------------------------------------------
  local function build_node(id, role)
    local node = { id = id, inbox = {} }
    node.net = net.new(modem_for(id), 1, id, quiet, time, { mirrors = { [A] = { B } } })
    link.set_receiver(id, function(msg)
      local status = node.net.receive(msg)
      if status == "ok" and msg.type == "cmd" then
        node.inbox[#node.inbox + 1] = msg
        node.net.ack_for(msg, true)
      end
    end)
    function node.send_event(payload) return node.net.send_reliable("event", A, payload) end
    function node.heartbeat() return node.net.heartbeat(A, { role = role, train_id = (role == "train") and id or nil }) end
    function node.commands(name)
      local out = {}
      for _, msg in ipairs(node.inbox) do if msg.payload.cmd == name then out[#out + 1] = msg end end
      return out
    end
    w.nodes[id] = node
  end
  build_node("TRAIN-1", "train"); build_node("TRAIN-2", "train")
  for _, id in ipairs({ "SEN-1", "SEN-2", "SEN-3" }) do build_node(id, "sensor") end

  -- time ----------------------------------------------------------------------------------------------------------------------
  local next_heartbeat = 0
  function w.step(ms, count)
    for _ = 1, count or 1 do
      link.advance(ms)
      local now = link.now()
      if now >= next_heartbeat then
        next_heartbeat = now + 2000
        for _, node in pairs(w.nodes) do node.heartbeat() end
      end
      for _, id in ipairs({ A, B }) do
        local m = w.masters[id]
        if m.alive then
          local due = {}
          local rest = {}
          for _, timer in ipairs(m.timers) do if timer.due <= now then due[#due + 1] = timer else rest[#rest + 1] = timer end end
          m.timers = rest
          table.sort(due, function(a, b) return a.due < b.due end)
          for _, timer in ipairs(due) do m.runtime.handle_event({ "timer", timer.id }) end
          m.network.tick()
        end
      end
      if w.arbiter_alive ~= false then
        if w.arbiter.ha then w.arbiter.ha.tick() end
        w.arbiter.net.tick()
      end
      for _, node in pairs(w.nodes) do node.net.tick() end
    end
  end
  function w.run(ms) w.step(50, math.ceil(ms / 50)) end

  function w.leader()
    local out
    for _, id in ipairs({ A, B }) do if w.masters[id].alive and w.masters[id].ha.is_leader() then out = out and (out .. "," .. id) or id end end
    return out
  end

  function w.crash(id)
    if id == ARB then w.arbiter_alive = false else w.masters[id].alive = false end
  end
  function w.restart(id)
    if id == ARB then build_arbiter(); w.arbiter_alive = true; return end
    local m = w.masters[id]
    build_master(m)
  end
  function w.isolate(id) w.blocked[id] = true end
  function w.heal_all() w.blocked = {} end

  function w.request(train_id, route_id)
    return w.nodes[train_id].send_event({ type = "request_departure", train_id = train_id, route_id = route_id })
  end
  function w.signal_calls(id, signal_id)
    local out = {}
    for _, call in ipairs(w.masters[id].hw.calls) do if call.kind == "signal" and (not signal_id or call.id == signal_id) then out[#out + 1] = call.value end end
    return out
  end
  function w.close() link.close() end
  return w
end

return world_mod
