--[[
Purpose: Fleet node: one of a fixed pair that holds the virtual trains, the timetables, the orders and the cargo ledger, and asks the masters for routes (Gesamtkonzept Kap. 8, 9, 10).
Public API: new_runtime(args_or_context) -> node (run(), start(), engine, replica, flush()). Entry: scripts/start_fleet.lua.
Notes: the first node of the pair in the plan is the active one, the second keeps a durable copy of the state and does nothing else; there is no takeover (a failing partner locks the new automatic
  activity of the pair, Kap. 8.1). Every change of the fleet state is written to the journal of the active node and sent to the partner (src/master/replica.lua with a fixed leader); a message
  that makes a decision binding (a route request, a schedule call) leaves only when the partner has the state it depends on. The fleet engine (src/fleet/engine.lua) decides, this node carries.
  Messages: to the master an event {type = "fleet_route" | "fleet_hold" | "fleet_reconstruct" | "fleet_release" | "fleet_complete"}; to the station node a cmd apply_schedule (its applied ack is the
  answer); from the master and the stations an event {type = "fleet_event", ev = {...}} (the events of the engine); between the partners an event {type = "fleet_pair", version, checksum}.
  Config (plan): cfg.fleet = { pairs = { { id, nodes = {a, b}, trains = {ids} } }, train_profiles = {...}, lines = {...}, platforms = { station = {...} }, stations = { station = node id } }.
]]

local config_module = require("src.shared.config")
local log = require("src.shared.log")
local shared_args = require("src.shared.args")
local common_node = require("src.nodes.common_node")
local cc_modem = require("src.adapter.cc_modem")
local bootstrap = require("src.nodes.bootstrap")
local json = require("src.shared.json")
local checksum = require("src.shared.checksum")
local canon = require("src.shared.canon")
local time = require("src.shared.time")
local journal_module = require("src.shared.journal")
local replica_module = require("src.master.replica")
local engine_module = require("src.fleet.engine")
local profile_module = require("src.fleet.profile")
local timetable_module = require("src.fleet.timetable")
local pairs_module = require("src.fleet.pairs")

local fleet_node = {}

local FREE_FRESH_S = 10

local function build_context(args_or_context)
  if args_or_context.config and args_or_context.logger and args_or_context.modem then return args_or_context end
  local cfg = config_module.load(args_or_context.config or "configs/templates/network.example.json")
  return { id = args_or_context.id, role = "fleet", config = cfg, logger = log.new("INFO", 200), modem = cc_modem.for_node(cfg, args_or_context.id) }
end

local function fleet_ids(cfg)
  local out = {}
  for _, node in ipairs(cfg.nodes or {}) do if node.role == "fleet" then out[#out + 1] = node.id end end
  return out
end

function fleet_node.new_runtime(args_or_context)
  local context = build_context(args_or_context)
  local cfg = context.config
  local fleet_cfg = cfg.fleet or {}
  local my_pair
  for _, pair in ipairs(fleet_cfg.pairs or {}) do
    for _, id in ipairs(pair.nodes or {}) do if id == context.id then my_pair = pair end end
  end
  local partner
  if my_pair then for _, id in ipairs(my_pair.nodes) do if id ~= context.id then partner = id end end end
  local active = my_pair ~= nil and my_pair.nodes[1] == context.id
  local clock_s = context.clock or function() return time.now_ms() / 1000 end

  local node
  local admin    -- the commands of the operator that the master forwards (below, once the engine exists)
  node = common_node.new({
    id = context.id, role = "fleet", config = cfg, modem = context.modem, logger = context.logger, clock = context.clock, start_timer = context.start_timer,
    tick_grace = context.tick_grace, journal_fs = context.journal_fs, fence_fs = context.fence_fs, topology_fs = context.topology_fs,
    handlers = {
      on_quiesce = function() return true end,
      on_cmd = function(payload, msg)
        if payload.cmd == "repl" and node.replica then node.replica.handle(msg) return true end
        if payload.cmd == "fleet_admin" and admin then return admin(payload, msg) end
        return false, "a fleet node takes no command: " .. tostring(payload.cmd)
      end
    }
  })
  node.fleet_pair = my_pair
  if not my_pair then
    node.logger.error("this fleet node is in no pair of the plan: it does nothing", { id = context.id })
    return node
  end

  -- the parts of the engine -------------------------------------------------------------------------------------------------
  local profiles = profile_module.new({ now = clock_s })
  local timetable = timetable_module.new({
    time = context.game_time or { real = function() return os.time and os.time() or 0 end, ingame = function() return (os.day and os.day("ingame")) or 0, (os.time and os.time("ingame")) or 0 end },
    tz_offset_min = fleet_cfg.tz_offset_min
  })
  local pair_set = pairs_module.new({ nodes = fleet_ids(cfg), pairs = fleet_cfg.pairs, now = clock_s, timeout_s = fleet_cfg.pair_timeout_s })
  local free_blocks = {}   -- block -> time it was reported proven free
  node.pair_set = pair_set
  node.engine = engine_module.new({
    id = context.id, pair_id = my_pair.id, profiles = profiles, timetable = timetable, pairs = pair_set, now = clock_s, ids_prefix = my_pair.id,
    platforms = fleet_cfg.platforms,
    is_free = function(block) local at = free_blocks[block]; return at ~= nil and (clock_s() - at) <= FREE_FRESH_S end,
    route_timeout_s = fleet_cfg.route_timeout_s, apply_timeout_s = fleet_cfg.apply_timeout_s, depart_timeout_s = fleet_cfg.depart_timeout_s
  })
  local engine = node.engine

  -- durable pair state --------------------------------------------------------------------------------------------------------
  local journal = journal_module.new(fleet_cfg.journal_file or "state/fleet_journal.log", { fs = context.journal_fs, max_entries = 600, max_bytes = 150000 })
  local journal_state, journal_info = journal.open()
  if journal_state == "corrupt" or journal_state == "failed" then
    node.logger.error("fleet journal unusable: no automatic activity", { status = journal_state, reason = journal_info and journal_info.reason })
  end
  node.replica = replica_module.new({
    id = context.id, peer = partner, network = node.net, journal = journal, logger = node.logger, now_ms = function() return clock_s() * 1000 end,
    ha = { is_leader = function() return active end, term = function() return 1 end },
    snapshot_fn = function() return engine.snapshot() end
  })
  local replica = node.replica

  local function seed_from_plan()
    local approval = { operator = "plan", confirmed = true }
    for _, spec in ipairs(fleet_cfg.train_profiles or {}) do
      if not profiles.get(spec.immutable_id) then profiles.register(spec, approval) end
    end
    for _, pair in ipairs(fleet_cfg.pairs or {}) do
      for _, train_id in ipairs(pair.trains or {}) do pair_set.assign_train(train_id, pair.id, approval) end
    end
  end

  local function publish_lines()
    local confirmations = {}
    for _, id in ipairs(my_pair.nodes) do confirmations[id] = true end
    for _, line in ipairs(fleet_cfg.lines or {}) do
      if not timetable.published(line.id) then
        local version = timetable.add_draft(line)
        if version then timetable.publish(line.id, version, confirmations, my_pair.nodes) end
      end
    end
  end

  if active then
    local committed = replica.promote()
    if next(committed) ~= nil then engine.restore(committed) end
    seed_from_plan()
  end

  -- messages that wait for the partner --------------------------------------------------------------------------------------------
  local pending = {}      -- { idx, message }
  local inflight = {}     -- net message id -> { trip_id, command_id } for the schedule calls

  local function send_out(message)
    local master = cfg.master_id
    local kind = message.type
    if kind == "apply_schedule" then
      local station_node = (fleet_cfg.stations or {})[message.station]
      if not station_node then return false end
      local sent = node.net.send_reliable("cmd", station_node, {
        cmd = "apply_schedule", trip_id = message.trip_id, leg_id = message.leg_id, command_id = message.command_id, train_id = message.train_id,
        destination = message.destination, platform = message.platform, route_id = message.route_id, schedule_version = message.schedule_version
      })
      if not sent then return false end
      inflight[sent.id] = { trip_id = message.trip_id, command_id = message.command_id }
      return true
    end
    local payload = {}
    for k, v in pairs(message) do payload[k] = v end
    payload.type = ({ route_request = "fleet_route", hold_at_waiting_point = "fleet_hold", reconstruct_request = "fleet_reconstruct", release_reservation = "fleet_release", trip_complete = "fleet_complete" })[kind] or kind
    payload.fleet_pair = my_pair.id
    return node.net.send_reliable("event", master, payload) ~= nil
  end

  function node.flush()
    if not active then return end
    local messages = engine.take_outbox()
    local idx = replica.capture()
    for _, message in ipairs(messages) do pending[#pending + 1] = { idx = idx or math.huge, message = message } end
    while pending[1] do
      local head = pending[1]
      if not replica.confirmed(head.idx) then break end
      if not send_out(head.message) then break end
      table.remove(pending, 1)
    end
  end

  -- answers of the stations to the schedule call
  local previous_ack, previous_err, previous_drop = node.net.on_ack, node.net.on_err, node.net.on_drop
  node.net.on_ack = function(payload, original)
    if previous_ack then previous_ack(payload, original) end
    local call = original and inflight[original.id]
    if call and payload.applied == true then
      inflight[original.id] = nil
      engine.event({ type = "schedule_applied", trip_id = call.trip_id, command_id = call.command_id, ok = true })
      node.flush()
    end
  end
  node.net.on_err = function(payload, original, source)
    if previous_err then previous_err(payload, original, source) end
    local call = original and inflight[original.id]
    if call then
      inflight[original.id] = nil
      engine.event({ type = "schedule_applied", trip_id = call.trip_id, command_id = call.command_id, ok = false, reason = tostring(payload.error) })
      node.flush()
    end
  end
  node.net.on_drop = function(msg)
    if previous_drop then previous_drop(msg) end
    local call = inflight[msg.id]
    if call then
      inflight[msg.id] = nil
      engine.event({ type = "schedule_applied", trip_id = call.trip_id, command_id = call.command_id, ok = false, reason = "no answer from " .. tostring(msg.dst) })
      node.flush()
    end
  end

  -- what the world says ------------------------------------------------------------------------------------------------------------
  local function from_world(src)
    if src == cfg.master_id then return true end
    for _, id in ipairs(cfg.masters or {}) do if id == src then return true end end
    for _, station_node in pairs(fleet_cfg.stations or {}) do if station_node == src then return true end end
    for _, id in ipairs(fleet_cfg.event_sources or {}) do if id == src then return true end end
    return false
  end

  local base_handle = node.handle_message
  node.handle_message = function(msg)
    local status = base_handle(msg)
    if status ~= "ok" or msg.type ~= "event" or type(msg.payload) ~= "table" then return status end
    local payload = msg.payload
    if payload.type == "fleet_pair" and msg.src == partner then
      pair_set.heartbeat(partner, { version = payload.version, checksum = payload.checksum })
    elseif payload.type == "fleet_event" and active and from_world(msg.src) and type(payload.ev) == "table" then
      engine.event(payload.ev)
      node.flush()
    elseif payload.type == "fleet_blocks" and from_world(msg.src) and type(payload.free) == "table" then
      free_blocks = {}
      for _, block in ipairs(payload.free) do free_blocks[block] = clock_s() end
    end
    return status
  end

  -- what the operator may change from the panel (the master forwards it, Kap. 9, 11.5, H-12): a draft of a line, its publication, the cancel of a trip. Every answer goes back to the master as an event.
  local publishing = {}   -- { request_id, line_id, version, idx }: a draft that waits until the partner holds the state it is in
  local function answer(request_id, ok, extra)
    local payload = { type = "fleet_admin_result", request_id = request_id, pair_id = my_pair.id, ok = ok == true }
    for k, v in pairs(extra or {}) do payload[k] = v end
    node.net.send_reliable("event", cfg.master_id, payload)
  end

  admin = function(payload, msg)
    local from_master = msg.src == cfg.master_id
    for _, id in ipairs(cfg.masters or {}) do if id == msg.src then from_master = true end end
    if not from_master then return false, "only the master forwards operator commands" end
    local request_id = payload.request_id
    if not active then answer(request_id, false, { reason = "this node is the standby of the pair" }); return true end
    if journal_state == "corrupt" or journal_state == "failed" or not replica.writable() then answer(request_id, false, { reason = "the fleet journal is not writable" }); return true end
    local op = payload.op
    if op == "timetable_draft" then
      local version, problems = timetable.add_draft(payload.line)
      if not version then answer(request_id, false, { reason = "draft refused", problems = problems }); return true end
      node.flush()
      answer(request_id, true, { op = op, line_id = payload.line.id, version = version })
    elseif op == "timetable_publish" then
      local healthy, why = pair_set.auto_allowed(my_pair.id)
      if not healthy then answer(request_id, false, { reason = "the pair is not healthy, nothing is published: " .. tostring(why) }); return true end
      local published = timetable.published(tostring(payload.line_id))
      local current = published and published.version or nil
      if payload.base_version ~= current then
        answer(request_id, false, { reason = "conflict: the line is at version " .. tostring(current) .. ", the draft was made on " .. tostring(payload.base_version), conflict = true, current = current })
        return true
      end
      if not timetable.get(tostring(payload.line_id), payload.version) then answer(request_id, false, { reason = "no such draft" }); return true end
      local idx = replica.capture()
      publishing[#publishing + 1] = { request_id = request_id, line_id = payload.line_id, version = payload.version, idx = idx or math.huge, base = current }
    elseif op == "trip_cancel" then
      local ok, err = engine.cancel(payload.trip_id, payload.who or "operator")
      node.flush()
      answer(request_id, ok, { op = op, reason = err })
    else
      answer(request_id, false, { reason = "unknown operation " .. tostring(op) })
    end
    return true
  end

  local function finish_publications()
    local still = {}
    for _, p in ipairs(publishing) do
      if p.idx ~= math.huge and replica.confirmed(p.idx) then
        local confirmations = {}
        for _, id in ipairs(my_pair.nodes) do confirmations[id] = true end
        local current = timetable.published(tostring(p.line_id))
        if (current and current.version or nil) ~= p.base then
          answer(p.request_id, false, { reason = "conflict: the line changed while the draft waited", conflict = true })
        else
          local ok, err = timetable.publish(tostring(p.line_id), p.version, confirmations, my_pair.nodes)
          if ok then node.flush() end
          answer(p.request_id, ok, { op = "timetable_publish", line_id = p.line_id, version = p.version, reason = err })
        end
      elseif p.idx == math.huge then
        answer(p.request_id, false, { reason = "the fleet journal could not take the draft" })
      else
        still[#still + 1] = p
      end
    end
    publishing = still
  end

  -- the periodic work -----------------------------------------------------------------------------------------------------------
  local cached = { idx = -1, sum = "0" }
  local function state_sum()
    local idx = replica.committed_idx()
    if cached.idx ~= idx then
      -- canonical text: the same state gives the same checksum whatever order the tables list their keys in
      local text = canon.encode(replica.committed_state()) or json.encode(replica.committed_state())
      cached = { idx = idx, sum = checksum.hex(checksum.adler32(text)) }
    end
    return idx, cached.sum
  end

  local applied_idx = replica.committed_idx()
  node.ticker.every("fleet", 1, function()
    local idx, sum = state_sum()
    pair_set.heartbeat(context.id, { version = idx, checksum = sum })
    node.net.send("event", partner, { type = "fleet_pair", version = idx, checksum = sum })
    if active then
      if journal_state == "corrupt" or journal_state == "failed" or not replica.writable() then return end
      publish_lines()
      engine.tick()
      node.flush()
    elseif replica.committed_idx() ~= applied_idx then
      applied_idx = replica.committed_idx()
      engine.restore(replica.committed_state())
    end
  end)
  node.ticker.every("replica", 0.5, function() replica.tick(); if active then finish_publications() end end)
  -- the active node tells the master what the panels show (lines, trips, cargo)
  node.ticker.every("fleet_status", fleet_cfg.status_every_s or 5, function()
    if active then node.net.send("event", cfg.master_id, { type = "fleet_status", pair_id = my_pair.id, report = engine.report(), healthy = pair_set.auto_allowed(my_pair.id) }) end
  end)
  return node
end

local args = shared_args.parse({...}, { config = {}, id = {} })
if args.id then
  fleet_node.new_runtime(bootstrap.create_context({...}, "fleet")).run()
end

return fleet_node
