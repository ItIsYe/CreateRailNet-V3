--[[
Purpose: A fleet pair (two real fleet nodes with journals), a stub master and a stub station on a simulated network, with a virtual clock; the test plays the master and the station.
Public API: new(opts) -> world with nodes[id] (the real fleet nodes), master (inbox of events, send_event(ev, to), send_admin(payload, to)), station (inbox of cmds, answer), link, step(ms, n), run(ms), crash(id), restart(id), close().
  opts: seed, drop, delay_max_ms, apply_timeout_s, start_epoch (seconds, default 07:58:00 UTC), no_lines, proof (occupancy_proof on in the dispatcher), real_master (a dispatcher and the fleet bridge in place of the stub master: w.dispatcher, w.bridge).
Notes: time is the link's virtual clock (os.clock is replaced until close()). The plan has one master, the pair FLEET-A (active) / FLEET-B, a station node STATION-N, one passenger line L1 NORD -> SUED at 08:00,
  two platforms in SUED and the train TRAIN-1 in the pair.
]]

local net = require("src.shared.net")
local fleet_node = require("src.nodes.fleet_node")
local memfs = require("tests.harness.memfs")
local prng = require("tests.harness.prng")
local lossy_link = require("tests.harness.lossy_link")

local world_mod = {}

local A, B, MASTER, STATION = "FLEET-A", "FLEET-B", "MASTER-1", "STATION-N"
world_mod.A, world_mod.B, world_mod.MASTER, world_mod.STATION = A, B, MASTER, STATION

local quiet = { info = function() end, warn = function() end, error = function() end, debug = function() end }

local function plan(opts)
  return {
    v = 1, channel = 1, master_id = MASTER,
    nodes = {
      { id = MASTER, role = "master" }, { id = A, role = "fleet", cmd_sources = { B } }, { id = B, role = "fleet", cmd_sources = { A } }, { id = STATION, role = "station" }
    },
    cmd_sources = { A, B },
    fleet = {
      pairs = { { id = "P1", nodes = { A, B }, trains = { "TRAIN-1" } } },
      train_profiles = { { immutable_id = "TRAIN-1", create_name_ref = "Sued 1", train_class = "PASSENGER", length = 6, permitted_directions = { "EAST", "WEST" } } },
      lines = opts.no_lines and {} or { { id = "L1", kind = "PASSENGER", time_base = "REAL", window = { from = "06:00", to = "22:00" }, departures = { "08:00" }, dwell_s = 30,
        stops = { { station = "NORD" }, { station = "SUED" } }, routes = { EAST = "R-NS" }, origin = "NORD", goal = "SUED", direction = "EAST" } },
      platforms = { SUED = { { id = "P1", block = "BP1", direction = "EAST", length = 8, confirmed = true, preferred = 1 }, { id = "P2", block = "BP2", direction = "EAST", length = 8, confirmed = true, preferred = 2 } } },
      stations = { NORD = STATION },
      depots = opts.depots,
      cargo_checkers = { "ED" },
      route_timeout_s = 120, apply_timeout_s = opts.apply_timeout_s or 30, depart_timeout_s = 120, pair_timeout_s = 15
    }
  }
end

function world_mod.new(opts)
  opts = opts or {}
  local rng = prng.new(opts.seed or 1)
  local link = lossy_link.new(rng, { drop = opts.drop, delay_max_ms = opts.delay_max_ms })
  local w = { link = link, nodes = {}, fs = {}, timers = {}, crashed = {}, master = { inbox = {} }, station = { inbox = {}, answer = true, applied = true }, epoch0 = opts.start_epoch or (7 * 3600 + 58 * 60) }
  local timer_id = 0

  local function build(id)
    w.timers[id] = {}
    w.fs[id] = w.fs[id] or { journal = memfs.new(), fence = memfs.new(), topology = memfs.new() }
    local node = fleet_node.new_runtime({
      id = id, role = "fleet", config = plan(opts), logger = quiet, modem = link.modem(id), journal_fs = w.fs[id].journal, fence_fs = w.fs[id].fence, topology_fs = w.fs[id].topology,
      clock = function() return link.now() / 1000 end,
      start_timer = function(seconds) timer_id = timer_id + 1; w.timers[id][#w.timers[id] + 1] = { id = timer_id, due = link.now() + seconds * 1000 }; return timer_id end,
      game_time = { real = function() return w.epoch0 + math.floor(link.now() / 1000) end, ingame = function() return 0, 0 end }
    })
    w.nodes[id] = node
    link.set_receiver(id, function(msg) if not w.crashed[id] then node.handle_message(msg) end end)
    node.start()
    return node
  end

  build(A); build(B)

  -- the stub master: records what the fleet tells it, the test answers (opts.real_master: a real dispatcher with the fleet bridge answers)
  w.master.net = net.new(link.modem(MASTER), 1, MASTER, quiet)
  if opts.real_master then
    local cfg = plan(opts)
    cfg.sensor_guard_min_occupy_ms = 0
    cfg.occupancy_proof = opts.proof and "on" or nil
    cfg.safe_stops = { { block = "BP1", length = 12, proven = true }, { block = "BP2", length = 12, proven = true } }
    cfg.blocks = {
      { id = "B1", entry_signal = "S1", exit_signal = "X1", sensors = { "SEN-1" } }, { id = "B2", entry_signal = "S2", exit_signal = "X2", sensors = { "SEN-2" } },
      { id = "BP1", entry_signal = "S3", exit_signal = "X3", sensors = { "SEN-3" } }, { id = "BP2", entry_signal = "S4", exit_signal = "X4", sensors = { "SEN-4" } }
    }
    cfg.routes = { { id = "R-NS", from = "NORD", to = "SUED", blocks = { "B1", "B2", "BP1" } } }
    cfg.nodes[#cfg.nodes + 1] = { id = "SEN-1", role = "sensor" }
    w.dispatcher = require("src.master.dispatcher").new(cfg, { signals = { setAspect = function() return true end }, switches = { setPosition = function() return true end } })
    w.bridge = require("src.master.fleet_bridge").new({ dispatcher = w.dispatcher, network = w.master.net, config = cfg, logger = quiet, now = function() return link.now() / 1000 end, train_length = function() return 6 end })
    link.set_receiver(MASTER, function(msg)
      local status = w.master.net.receive(msg)
      if status == "ok" and msg.type == "event" then
        w.master.inbox[#w.master.inbox + 1] = msg.payload
        w.bridge.handle(msg)
        w.master.net.ack_for(msg, true)
      end
    end)
  else
    link.set_receiver(MASTER, function(msg)
      local status = w.master.net.receive(msg)
      if status == "ok" and msg.type == "event" then w.master.inbox[#w.master.inbox + 1] = msg.payload end
    end)
  end
  function w.master.send_event(ev, to)
    for _, target in ipairs(to and { to } or { A, B }) do w.master.net.send_reliable("event", target, { type = "fleet_event", ev = ev }) end
  end
  -- an operator command that the master forwards (the panel's timetable editor): cmd fleet_admin to one node
  function w.master.send_admin(payload, to)
    local body = { cmd = "fleet_admin" }
    for k, v in pairs(payload) do body[k] = v end
    w.master.net.send_reliable("cmd", to or A, body)
  end
  function w.master.send_free(blocks)
    for _, target in ipairs({ A, B }) do w.master.net.send_reliable("event", target, { type = "fleet_blocks", free = blocks }) end
  end
  function w.master.last(kind)
    for i = #w.master.inbox, 1, -1 do if w.master.inbox[i].type == kind then return w.master.inbox[i] end end
  end
  function w.master.count(kind) local n = 0; for _, p in ipairs(w.master.inbox) do if p.type == kind then n = n + 1 end end return n end

  -- the stub station: acknowledges the schedule call as applied (or stays silent)
  w.station.net = net.new(link.modem(STATION), 1, STATION, quiet)
  link.set_receiver(STATION, function(msg)
    local status = w.station.net.receive(msg)
    if status == "ok" and msg.type == "cmd" and msg.payload.cmd == "apply_schedule" then
      w.station.inbox[#w.station.inbox + 1] = msg.payload
      if w.station.answer then w.station.net.ack_for(msg, w.station.applied) end
    end
  end)
  function w.station.count() return #w.station.inbox end

  function w.step(ms, count)
    for _ = 1, count or 1 do
      link.advance(ms)
      local now = link.now()
      for _, id in ipairs({ A, B }) do
        if not w.crashed[id] then
          local due, rest = {}, {}
          for _, timer in ipairs(w.timers[id]) do if timer.due <= now then due[#due + 1] = timer else rest[#rest + 1] = timer end end
          w.timers[id] = rest
          table.sort(due, function(x, y) return x.due < y.due end)
          for _, timer in ipairs(due) do w.nodes[id].handle_event({ "timer", timer.id }) end
        end
      end
      w.master.net.tick(); w.station.net.tick()
      if w.bridge then
        w.bridge.poll()
        if math.floor(now / 1000) % 2 == 0 and now % 1000 == 0 then w.bridge.report_blocks() end
      end
    end
  end
  function w.run(ms) w.step(100, math.ceil(ms / 100)) end
  function w.crash(id) w.crashed[id] = true end
  function w.restart(id) w.crashed[id] = false; build(id) end
  function w.close() link.close() end
  return w
end

return world_mod
