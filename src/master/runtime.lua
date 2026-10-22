--[[
Purpose: Master event runtime for modem, UI, timeout handling, audit, maintenance guard, persistent dispatcher recovery, and safe recovery mode.
Public API: new(context) -> runtime with handle_event(event), run(), save_recovery_state(), restore_recovery_state(), confirm_recovery().
  runtime.ticker drives the timeout / dwell / ui jobs; context.clock, context.start_timer and context.tick_grace are for tests.
]]

local time = require("src.shared.time")
local permissions = require("src.panel.permissions")
local op_state = require("src.domain.op_state")
local safety_graph = require("src.domain.safety_graph")
local ticker = require("src.shared.ticker")
local once_log = require("src.shared.once_log")
local status_model = require("src.domain.status_model")
local alert_rules = require("src.domain.alert_rules")

local message_handlers = require("src.shared.message_handlers")
local diagnostics = require("src.domain.diagnostics")
local errors = require("src.shared.error_codes")
local master_state_store = require("src.domain.master_state_store")

local master_runtime = {}

function master_runtime.new(context)
  local runtime = {
    registry = context.registry,
    train_registry = context.train_registry,
    station_registry = context.station_registry,
    depot_registry = context.depot_registry,
    service_plan_registry = context.service_plan_registry,
    route_integration = context.route_integration,
    manual_control = context.manual_control,
    dispatcher = context.dispatcher,
    network = context.network,
    ui = context.ui,
    logger = context.logger,
    config = context.config,
    audit_log = context.audit_log,
    maintenance = context.maintenance,
    ota = context.ota,
    update_control = context.update_control,
    replacement = context.replacement,
    signal_reports = {},
    fleet_reports = {}, fleet_results = {}, fleet_result_order = {},
    pairing = context.pairing,
    plan_service = context.plan_service,
    restart = context.restart,
    replica = context.replica, barrier = context.barrier, fleet_bridge = context.fleet_bridge,  -- dual commit with the other master (src/master/replica.lua, barrier.lua)
    ha = context.ha,          -- election with the other master and the arbiter (src/shared/ha.lua); nil in a plan with one master
    restart_needed = false,   -- a computer was accepted: what uses it applies after a restart
    -- config require_release: until the operator releases the operation no train starts a journey (a restart takes the release back)
    release = { required = type(context.config) == "table" and context.config.require_release == true, released = false },
    alerts = context.alerts,
    logs = context.logs,
    trace = context.trace,
    state_store = context.state_store or master_state_store.new((context.config and context.config.state_file) or nil),
    auto_restore_state = context.auto_restore_state ~= false,
    auto_save_state = context.auto_save_state ~= false,
    recovery = { restored = false, saved = false, required = false, confirmed = true, last_error = nil, last_save_reason = nil },
    pull_event = context.pull_event or os.pullEvent,
    heartbeat_timeout_s = context.heartbeat_timeout_s or (type((context.config or {}).heartbeat_timeout_s) == "number" and context.config.heartbeat_timeout_s > 0 and context.config.heartbeat_timeout_s) or 6,
    sensor_levels = {}  -- sensor_id -> { occupied, at }: what the detector shows right now, from heartbeats and events
  }
  -- with two masters only the leader of the newest term decides; the other one keeps the registry and the pairing, and does not touch the dispatcher
  function runtime.signal_report(node_id) return runtime.signal_reports[node_id] end
  function runtime.active() return runtime.ha == nil or runtime.ha.is_leader() end
  local ui_once = once_log.new(context.logger)
  local signal_once = once_log.new(context.logger)
  local event_once = once_log.new(context.logger)
  runtime.ticker = ticker.new({
    clock = context.clock,
    start_timer = context.start_timer,
    grace = context.tick_grace,
    on_error = function(name, err, count)
      if runtime.logger then runtime.logger.warn("tick job failed", { job = name, error = err, count = count }) end
    end
  })

  local handlers = {}

  local function audit(kind, data) if runtime.audit_log then runtime.audit_log.record(kind, data) end end

  -- ── who belongs to the network: the plan decides, not what a computer says about itself ────────────────────────────────
  -- A computer that is not in the plan (or whose id has another role there) may announce itself, nothing else: it is not registered, its
  -- events are not handled. The operator's acceptance writes it into the plan (pair_decide), from then on it is a node.
  local plan_roles, plan_size = {}, -1
  local function plan_role_of(id)
    local nodes = runtime.config and runtime.config.nodes
    if type(nodes) ~= "table" or type(id) ~= "string" then return nil end
    if #nodes ~= plan_size then
      plan_roles, plan_size = {}, #nodes
      for _, node in ipairs(nodes) do
        if type(node) == "table" and type(node.id) == "string" and type(node.role) == "string" then plan_roles[node.id] = node.role end
      end
    end
    return plan_roles[id]
  end
  runtime.plan_role = plan_role_of
  local unplanned_once = once_log.new(context.logger)

  -- ── pairing: computers that are not in the plan wait for the operator ───────────────────────────────────────────────
  local pair_sent = {}   -- node id -> the last state told to that node (a node is told again only when it changes)

  -- Tell the node where it stands (only nodes that announced protocol revision 3 or newer understand it).
  -- An unasked announcement is told only when the state changed (a node announces every few minutes and does not need the same answer
  -- again). A probe of the setup wizard is a question: it is answered every time, and the answer names the question (probe_id).
  -- echo: a probe may ask for a message of that many bytes back (the link test of scripts/setup.lua --linktest), at most MAX_ECHO_BYTES
  local MAX_ECHO_BYTES = 4000
  local function pair_reply(dst, state, detail, probe_id, echo)
    local network = runtime.network
    local revision = network.peer_revision and network.peer_revision(dst)
    if not revision or revision < 3 then return end
    if probe_id == nil and pair_sent[dst] == state then return end
    pair_sent[dst] = state
    local payload = { cmd = "pair_state", state = state, detail = detail, probe_id = probe_id }
    -- the masters and the arbiter: a computer with a short plan learns them here
    if type(runtime.config) == "table" and type(runtime.config.masters) == "table" and #runtime.config.masters >= 2 then
      payload.masters, payload.arbiter = runtime.config.masters, runtime.config.arbiter
    end
    if probe_id ~= nil and type(echo) == "number" and echo >= 1 and echo <= MAX_ECHO_BYTES then payload.pad = string.rep("x", math.floor(echo)) end
    if network.send_reliable then network.send_reliable("cmd", dst, payload) elseif network.send then network.send("cmd", dst, payload) end
  end

  -- an announcement (register, heartbeat of an unknown node, pair_announce, pair_probe); returns the state
  -- reply: false = say nothing, nil = tell the node when its state changed, a probe id = answer that question
  local function note_candidate(src, payload, reply, echo)
    if not runtime.pairing then return nil end
    local state, detail = runtime.pairing.announce(src, payload)
    if state == "pending" or state == "conflict" then
      if runtime.alerts then
        local text = state == "pending" and ("Neuer Computer wartet: " .. tostring(src) .. " (" .. tostring(payload and payload.role) .. ")")
          or ("Computer " .. tostring(src) .. " meldet die Rolle " .. tostring(payload and payload.role) .. ", im Plan steht " .. tostring(detail))
        runtime.alerts.raise("pair:" .. tostring(src), "YELLOW", text, nil, { ttl_s = 3600 })
      end
    elseif state == "known" and runtime.alerts and runtime.alerts.clear then
      runtime.alerts.clear("pair:" .. tostring(src))
    end
    if reply ~= false and state then pair_reply(src, state, detail, reply, echo) end
    return state, detail
  end

  -- the operator decides about a waiting computer (master UI): "accept" writes its entry into the plan, "reject" ignores it for a while
  function runtime.pair_decide(action, id, operator)
    if not runtime.pairing then return false, "Pairing ist nicht verfuegbar." end
    local ok, message
    if action == "accept" then ok, message = runtime.pairing.accept(id, operator)
    elseif action == "reject" then ok, message = runtime.pairing.reject(id, operator)
    else return false, "Unbekannte Aktion: " .. tostring(action) end
    if ok then
      if runtime.alerts and runtime.alerts.clear then runtime.alerts.clear("pair:" .. tostring(id)) end
      pair_sent[id] = nil
      pair_reply(id, action == "accept" and "known" or "rejected")
      if action == "accept" then runtime.restart_needed = true end
    end
    runtime.ui.mark_dirty()
    return ok, message
  end
  -- The operator restarts the master (the setup page): the state is saved, then the restart runs (signals to RED, reboot).
  function runtime.restart_master(operator)
    if not runtime.restart then return false, "Der Neustart ist hier nicht verfuegbar." end
    audit("master_restart", { by = operator })
    runtime.save_recovery_state("restart")
    return runtime.restart(operator)
  end

  -- how many blocks are in use right now (a restart stops the trains in front of red signals)
  function runtime.busy_blocks()
    local overview = runtime.dispatcher and runtime.dispatcher.get_overview and runtime.dispatcher.get_overview() or {}
    local busy = 0
    for _, block in pairs(overview) do
      if type(block) == "table" and (block.state == "OCCUPIED" or block.state == "RESERVED") then busy = busy + 1 end
    end
    return busy
  end

  -- Signals are re-sent, not read back. Whatever failed is reported once per change, not on every pass.
  local function note_signal_result(result, what)
    if not result then return end
    if result.failed > 0 then
      signal_once.warn("signals", "signals did not answer", { what = what, failed = result.failed, blocks = table.concat(result.failed_blocks, ",") })
    else
      signal_once.ok("signals", "signals answer again")
    end
  end

  local function maintenance_enabled() if not runtime.maintenance then return false end; if runtime.maintenance.is_locked then return runtime.maintenance.is_locked() end; if runtime.maintenance.status then return runtime.maintenance.status().enabled == true end; return runtime.maintenance.enabled == true end
  local function recovery_locked() return runtime.recovery.required == true and runtime.recovery.confirmed ~= true end
  local function release_locked() return runtime.release.required == true and runtime.release.released ~= true end

  -- The operator releases the operation (config require_release): from here on trains may start journeys. Only when the network is as it
  -- should be: every computer of the plan that runs the track (not trains, not panels) is online and no block is in FAULT. A restart of the
  -- master takes the release back, like it asks for the recovery to be confirmed again.
  local RELEASE_ROLES = { signal = true, sensor = true, switch = true, station = true, depot = true }
  function runtime.release_operation(operator)
    local release = runtime.release
    if not release.required then return true, "Fuer dieses Netz wird keine Freigabe verlangt." end
    if release.released then return true, "Der Betrieb ist schon freigegeben." end
    if recovery_locked() then return false, "Erst den Wiederanlauf bestaetigen, dann den Betrieb freigeben." end
    local registry = runtime.registry.all and runtime.registry.all() or {}
    local offline = {}
    for _, node in ipairs((runtime.config and runtime.config.nodes) or {}) do
      if RELEASE_ROLES[node.role] then
        local entry = registry[node.id]
        if not (entry and tostring(entry.status):upper() == "UP") then offline[#offline + 1] = node.id end
      end
    end
    table.sort(offline)
    if #offline > 0 then
      local names = table.concat(offline, ", ", 1, math.min(3, #offline)) .. (#offline > 3 and ", ..." or "")
      return false, "Nicht freigegeben: " .. #offline .. " Computer offline (" .. names .. ")."
    end
    local overview = runtime.dispatcher and runtime.dispatcher.get_overview and runtime.dispatcher.get_overview() or {}
    local faulted = 0
    for _, block in pairs(overview) do if type(block) == "table" and block.state == "FAULT" then faulted = faulted + 1 end end
    if faulted > 0 then return false, "Nicht freigegeben: " .. faulted .. " Bloecke gestoert (erst beheben)." end
    release.released, release.by, release.at = true, operator, time.now_s()
    audit("operation_released", { by = operator })
    if runtime.alerts and runtime.alerts.clear then runtime.alerts.clear("release:required") end
    runtime.ui.mark_dirty()
    return true, "Betrieb freigegeben."
  end

  function runtime.save_recovery_state(reason)
    if not runtime.auto_save_state or not runtime.state_store or not runtime.dispatcher or not runtime.dispatcher.snapshot then return true end
    local ok, err = runtime.state_store.save(runtime.dispatcher.snapshot())
    runtime.recovery.saved = ok == true
    runtime.recovery.last_save_reason = reason
    runtime.recovery.last_error = ok and nil or err
    if ok then audit("state_saved", { reason = reason }) elseif runtime.logger then runtime.logger.warn("state save failed", { reason = reason, error = err }) end
    return ok, err
  end

  function runtime.restore_recovery_state()
    if not runtime.auto_restore_state or not runtime.state_store or not runtime.dispatcher or not runtime.dispatcher.restore then return false, "restore disabled" end
    local snapshot, payload_or_err = runtime.state_store.load()
    if not snapshot then
      runtime.recovery.last_error = payload_or_err
      if payload_or_err ~= "missing" and runtime.logger then runtime.logger.warn("state restore skipped", { error = payload_or_err }) end
      return false, payload_or_err
    end
    local ok, err = runtime.dispatcher.restore(snapshot)
    runtime.recovery.restored = ok == true
    runtime.recovery.required = ok == true
    runtime.recovery.confirmed = ok ~= true
    runtime.recovery.last_error = ok and nil or err
    if ok then audit("state_restored", { saved_at = payload_or_err and payload_or_err.saved_at, recovery_required = true }) elseif runtime.logger then runtime.logger.warn("state restore failed", { error = err }) end
    return ok, err
  end

  function runtime.confirm_recovery(operator, reason)
    runtime.recovery.required = false
    runtime.recovery.confirmed = true
    runtime.recovery.confirmed_by = operator or "operator"
    runtime.recovery.confirm_reason = reason
    runtime.recovery.last_error = nil
    audit("recovery_confirmed", { by = runtime.recovery.confirmed_by, reason = reason })
    runtime.save_recovery_state("recovery_confirmed")
    runtime.ui.mark_dirty()
    return true
  end

  local function save_after(reason) runtime.save_recovery_state(reason) end

  local function reject_maintenance(msg, action)
    local err = errors.make(errors.codes.MAINTENANCE_LOCKED, "event blocked by maintenance", { action = action, src = msg.src })
    audit("maintenance_rejected", err)
    if runtime.logger then runtime.logger.warn("maintenance rejected event", err) end
    runtime.network.ack_for(msg, true)
    runtime.ui.mark_dirty()
    return true
  end

  local function reject_recovery(msg, action)
    local payload = msg.payload or {}
    audit("recovery_blocked", { action = action, src = msg.src, train_id = payload.train_id, route_id = payload.route_id })
    if payload.train_id then
      if runtime.network.send_reliable then
        runtime.network.send_reliable("cmd", msg.src, { cmd = "hold_position", train_id = payload.train_id, route_id = payload.route_id, reason = "recovery review required" })
      else
        runtime.network.send("cmd", msg.src, { cmd = "hold_position", train_id = payload.train_id, route_id = payload.route_id, reason = "recovery review required" })
      end
    end
    runtime.network.ack_for(msg, true)
    runtime.ui.mark_dirty()
    return true
  end

  local function reject_release(msg, action)
    local payload = msg.payload or {}
    audit("release_blocked", { action = action, src = msg.src, train_id = payload.train_id, route_id = payload.route_id })
    if payload.train_id then
      local body = { cmd = "hold_position", train_id = payload.train_id, route_id = payload.route_id, reason = "Betrieb nicht freigegeben" }
      if runtime.network.send_reliable then runtime.network.send_reliable("cmd", msg.src, body) else runtime.network.send("cmd", msg.src, body) end
    end
    runtime.network.ack_for(msg, true)
    runtime.ui.mark_dirty()
    return true
  end

  local function panel_snapshot()
    local context_view = { config = runtime.config, registry = runtime.registry, logger = runtime.logger, dispatcher = runtime.dispatcher, route_integration = runtime.route_integration, service_plan_registry = runtime.service_plan_registry, audit_log = runtime.audit_log, maintenance = runtime.maintenance }
    local master_state = maintenance_enabled() and "MAINTENANCE" or (recovery_locked() and "RECOVERY" or (release_locked() and "NICHT_FREIGEGEBEN" or "ONLINE"))
    local built = { cmd = "panel_update", master_state = master_state, overview = runtime.dispatcher and runtime.dispatcher.get_overview() or {}, trains = runtime.train_registry and runtime.train_registry.list() or {}, stations = runtime.station_registry and runtime.station_registry.list() or {}, depots = runtime.depot_registry and runtime.depot_registry.list() or {}, service_plans = runtime.service_plan_registry and runtime.service_plan_registry.list() or {}, diagnostics = diagnostics.build(context_view) }
    built.diagnostics.recovery = runtime.recovery
    local locks = runtime.update_control and runtime.update_control.locks() or {}
    local faulty = {}
    for _, lock in ipairs(locks) do faulty[#faulty + 1] = lock.node_id end
    local both_masters -- nil in a plan with one master; with two a leader whose lease holds has the majority
    if runtime.ha then both_masters = runtime.ha.is_leader() end
    local commit_clear = true
    if runtime.dispatcher and runtime.dispatcher.commit_pending and runtime.ha then commit_clear = #runtime.dispatcher.commit_pending() == 0 end
    built.op_state, built.op_reason = op_state.derive({
      setup_done = true, recovery = recovery_locked(), maintenance = maintenance_enabled(), local_faults = faulty,
      both_masters = both_masters, commit_clear = commit_clear
    })
    built.op_text = op_state.describe(built.op_state)
    built.diagnostics.update_locks = locks
    -- the panel draws the track diagram of the topology the master runs: it announces the version and the panel fetches the plan
    if not runtime.topology_version and runtime.config and runtime.config.blocks then
      local built_ok, graph = pcall(safety_graph.build, runtime.config)
      runtime.topology_version = built_ok and graph.version or false
    end
    built.topology_version = runtime.topology_version or nil
    built.signals = runtime.signal_states and runtime.signal_states() or nil
    local faults = {}
    for _, entry in ipairs(runtime.alerts and runtime.alerts.list({ active_only = false, limit = 40 }) or {}) do
      faults[#faults + 1] = { key = entry.key, severity = entry.severity, text = entry.text, acked = entry.acked, acked_by = entry.acked_by, state = entry.state }
    end
    built.faults = faults
    local node_list = {}
    for id, node in pairs(runtime.registry and runtime.registry.all and runtime.registry.all() or {}) do node_list[id] = { role = node.role, status = node.status } end
    built.nodes = node_list
    -- the fleet pairs as they last reported: a report older than 20 s is told so (the panel labels stale data)
    local fleet = { lines = {}, trips = {}, pairs = {}, results = runtime.fleet_results }
    local cargo = {}
    for pair_id, entry in pairs(runtime.fleet_reports) do
      fleet.pairs[pair_id] = { healthy = entry.healthy, age_s = time.now_s() - entry.at, node = entry.node }
      for id, line in pairs(entry.report.lines or {}) do line.pair_id = pair_id; fleet.lines[id] = line end
      for id, trip in pairs(entry.report.trips or {}) do trip.pair_id = pair_id; fleet.trips[id] = trip end
      for id, order in pairs(entry.report.cargo or {}) do cargo[id] = order end
    end
    built.fleet, built.cargo = fleet, cargo
    if runtime.replacement then
      local list = {}
      for _, node in ipairs((runtime.config or {}).nodes or {}) do
        local state = runtime.replacement.wizard.state_of(node.id)
        if state then list[node.id] = state end
      end
      built.replacements = list
    end
    built.diagnostics.loop = runtime.ticker.stats()
    return built
  end

  local function send_panel_snapshot(dst)
    local snap = panel_snapshot()
    if runtime.network.send_reliable then
      runtime.network.send_reliable("cmd", dst, snap)
    else
      runtime.network.send("cmd", dst, snap)
    end
  end
  local function apply_station_snapshot(station_id, payload) if not runtime.station_registry then return end; runtime.station_registry.register(station_id, payload.node_id or station_id, payload or {}); for platform_id, platform in pairs((payload and payload.platforms) or {}) do runtime.station_registry.update_platform(station_id, platform_id, platform) end end
  local function apply_depot_snapshot(depot_id, payload) if not runtime.depot_registry then return end; runtime.depot_registry.register(depot_id, payload.node_id or depot_id, payload or {}); for track_id, track in pairs((payload and payload.tracks) or {}) do runtime.depot_registry.update_track(depot_id, track_id, track) end end

  -- A computer that the plan does not list with this role is a candidate, not a node: it is told where it stands and nothing else happens.
  local function not_a_node(msg, role)
    local planned = plan_role_of(msg.src)
    if planned ~= nil and planned == role then return false end
    note_candidate(msg.src, { role = role })
    runtime.network.ack_for(msg, true)
    runtime.ui.mark_dirty()
    return true
  end

  handlers.register = function(msg)
    local role = msg.payload and msg.payload.role
    audit("register", { src = msg.src, role = role })
    if not_a_node(msg, role) then return true end
    local previous = runtime.registry.all and runtime.registry.all()[msg.src]
    runtime.registry.register(msg.src, role, nil)
    note_candidate(msg.src, { role = role }, false)
    if previous and tostring(previous.status):lower() == "down" then audit("node_reconnect", { node_id = msg.src, role = role }) end
    if role == "train" and runtime.train_registry then
      local train_id = msg.payload.train_id or msg.src
      runtime.train_registry.register(train_id, msg.src, msg.payload or {})
      if runtime.route_integration and not maintenance_enabled() and not recovery_locked() and not release_locked() then runtime.route_integration.send_service_plan(train_id) end
    elseif role == "station" and runtime.station_registry then apply_station_snapshot(msg.payload.station_id or msg.src, msg.payload or {})
    elseif role == "depot" and runtime.depot_registry then apply_depot_snapshot(msg.payload.depot_id or msg.src, msg.payload or {})
    elseif role == "panel" then send_panel_snapshot(msg.src)
    elseif role == "signal" and runtime.dispatcher.resend_signals then note_signal_result(runtime.dispatcher.resend_signals(msg.src), "register " .. tostring(msg.src)) end
    runtime.network.ack_for(msg, true); runtime.ui.mark_dirty(); save_after("register"); return true
  end

  handlers.heartbeat = function(msg)
    local known = runtime.registry.all and runtime.registry.all()[msg.src]
    local announced_role = msg.payload and msg.payload.role
    -- a heartbeat does not make a computer a node: the plan lists it (with the role it announces) or it is only a candidate
    local planned = plan_role_of(msg.src)
    if planned == nil or (announced_role ~= nil and announced_role ~= planned) then
      note_candidate(msg.src, { role = announced_role })
      runtime.ui.mark_dirty()
      return true
    end
    announced_role = announced_role or planned
    -- a sensor tells whether its detector is occupied (not while its read fails); this clears blocks after an outage
    if announced_role == "sensor" and type(msg.payload) == "table" and type(msg.payload.occupied) == "boolean" then
      runtime.sensor_levels[msg.src] = { occupied = msg.payload.occupied, at = time.now_s() }
    end
    -- a multi-signal node tells which of its signals it can use: one that is missing, of another type or unknown to the master takes its blocks out of service
    if announced_role == "signal" and type(msg.payload) == "table" and type(msg.payload.signals) == "table" then
      local report = {}
      for signal_id, state in pairs(msg.payload.signals) do if type(signal_id) == "string" then report[signal_id] = tostring(state) end end
      runtime.signal_reports[msg.src] = { signals = report, at = time.now_s() }
    end
    if announced_role == "signal" and type(msg.payload) == "table" and type(msg.payload.signals) == "table" and runtime.dispatcher.signal_failed and runtime.active() then
      for signal_id, state in pairs(msg.payload.signals) do
        if state ~= "OK" and type(signal_id) == "string" then
          local changed = runtime.dispatcher.signal_failed(signal_id, "node " .. tostring(msg.src) .. " reports " .. tostring(state))
          if #changed > 0 then audit("signal_unusable", { node_id = msg.src, signal_id = signal_id, state = state, blocks = changed }); runtime.ui.mark_dirty() end
        end
      end
    end
    if not known and announced_role and runtime.registry.register then
      -- after a master restart the nodes keep heartbeating but never register again: adopt them
      runtime.registry.register(msg.src, announced_role, nil)
      audit("node_adopted", { node_id = msg.src, role = announced_role })
      note_candidate(msg.src, { role = announced_role }, false)
    elseif known and tostring(known.status):lower() == "down" then
      audit("node_reconnect", { node_id = msg.src, role = known.role })
      if known.role == "signal" and runtime.dispatcher.resend_signals then note_signal_result(runtime.dispatcher.resend_signals(msg.src), "reconnect " .. tostring(msg.src)) end
    end
    runtime.registry.heartbeat(msg.src)
    if runtime.ota and runtime.ota.on_heartbeat then runtime.ota.on_heartbeat(msg) end
    if msg.payload and msg.payload.role == "train" and runtime.train_registry then runtime.train_registry.register(msg.payload.train_id or msg.src, msg.src, msg.payload)
    elseif msg.payload and msg.payload.role == "station" and runtime.station_registry then apply_station_snapshot(msg.payload.station_id or msg.src, msg.payload)
    elseif msg.payload and msg.payload.role == "depot" and runtime.depot_registry then apply_depot_snapshot(msg.payload.depot_id or msg.src, msg.payload) end
    runtime.ui.mark_dirty(); return true
  end

  local function handle_sensor_event(msg)
    local action = msg.payload and msg.payload.action
    if action == "enter" or action == "leave" then
      runtime.sensor_levels[msg.payload.sensor_id] = { occupied = action == "enter", at = time.now_s() }
    end
    if maintenance_enabled() then return reject_maintenance(msg, "sensor") end
    audit("sensor", { src = msg.src, sensor_id = msg.payload.sensor_id, action = msg.payload.action })
    local ok, err = runtime.dispatcher.on_sensor_event_by_sensor(msg.payload.sensor_id, msg.payload.action)
    runtime.network.ack_for(msg, true)
    if ok == false and runtime.logger then runtime.logger.warn("sensor event rejected", { error = err, sensor_id = msg.payload.sensor_id }) end
    if runtime.route_integration and not recovery_locked() and not release_locked() then runtime.route_integration.process_queue() end
    runtime.ui.mark_dirty(); save_after("sensor")
  end

  local function handle_train_event(msg)
    if not runtime.train_registry then runtime.network.ack_for(msg, true); return end
    local payload = msg.payload or {}; local train_id = payload.train_id or msg.src
    audit("train_event", { src = msg.src, train_id = train_id, event_type = payload.type })
    if maintenance_enabled() and (payload.type == "request_departure" or payload.type == "arrived") then return reject_maintenance(msg, payload.type) end
    if recovery_locked() and payload.type == "request_departure" then return reject_recovery(msg, payload.type) end
    if release_locked() and payload.type == "request_departure" then return reject_release(msg, payload.type) end
    if payload.type == "train_status" then runtime.train_registry.update_status(train_id, payload)
    elseif payload.type == "request_departure" then if runtime.route_integration then runtime.route_integration.handle_train_request(payload, msg.src) end; if runtime.logger then runtime.logger.info("train requested departure", payload) end; save_after("route_request")
    elseif payload.type == "arrived" then if runtime.route_integration then runtime.route_integration.handle_train_arrival(payload, msg.src) end; save_after("train_arrival")
    elseif payload.type == "schedule_applied" then runtime.train_registry.update_status(train_id, { state = payload.state or (payload.schedule_state == "failed" and "SCHEDULE_FAILED" or "ROUTE_ASSIGNED"), route_id = payload.route_id, destination = payload.destination, create_destination = payload.create_destination, schedule_state = payload.schedule_state, schedule_station = payload.schedule_station, service_plan = payload.service_plan, service_stop_index = payload.service_stop_index, message = payload.message })
    elseif payload.type == "train_fault" then runtime.train_registry.update_status(train_id, { state = "FAULT", error = payload.error, message = payload.error }); if runtime.logger then runtime.logger.warn("train fault", payload) end end
    runtime.network.ack_for(msg, true); runtime.ui.mark_dirty()
  end

  local function handle_station_event(msg)
    if not runtime.station_registry then runtime.network.ack_for(msg, true); return end
    local payload = msg.payload or {}; local station_id = payload.station_id or msg.src
    audit("station_event", { src = msg.src, station_id = station_id, event_type = payload.type })
    -- the fleet is told which train stands in which station (the train it waits for)
    if runtime.fleet_bridge and runtime.active() and (payload.type == "train_arrived_station" or payload.type == "train_left_station") then runtime.fleet_bridge.on_station_event(payload, station_id) end
    if maintenance_enabled() and payload.type == "station_ready_departure" then return reject_maintenance(msg, payload.type) end
    if recovery_locked() and payload.type == "station_ready_departure" then return reject_recovery(msg, payload.type) end
    if release_locked() and payload.type == "station_ready_departure" then return reject_release(msg, payload.type) end
    if payload.type == "station_status" then runtime.station_registry.update_status(station_id, payload); if payload.platforms then apply_station_snapshot(station_id, payload) end
    elseif payload.type == "platform_status" then runtime.station_registry.update_platform(station_id, payload.platform_id, payload)
    elseif payload.type == "train_arrived_station" then runtime.station_registry.update_platform(station_id, payload.platform_id, { state = "DWELLING", train_id = payload.train_id, train_name = payload.train_name, route_id = payload.route_id, destination = payload.destination })
    elseif payload.type == "train_left_station" then if runtime.station_registry.release_platform then runtime.station_registry.release_platform(station_id, payload.platform_id) else runtime.station_registry.update_platform(station_id, payload.platform_id, { state = "EMPTY", train_id = nil, train_name = nil, route_id = nil, destination = nil }) end
    elseif payload.type == "station_ready_departure" then if runtime.route_integration then runtime.route_integration.handle_station_ready(payload, msg.src) end; save_after("station_departure")
    elseif payload.type == "station_fault" then runtime.station_registry.update_status(station_id, { state = "FAULT", message = payload.error }); if runtime.logger then runtime.logger.warn("station fault", payload) end end
    runtime.network.ack_for(msg, true); runtime.ui.mark_dirty()
  end

  local function handle_depot_event(msg)
    if not runtime.depot_registry then runtime.network.ack_for(msg, true); return end
    local payload = msg.payload or {}; local depot_id = payload.depot_id or msg.src
    audit("depot_event", { src = msg.src, depot_id = depot_id, event_type = payload.type })
    if maintenance_enabled() and payload.type == "depot_request_dispatch" then return reject_maintenance(msg, payload.type) end
    if recovery_locked() and payload.type == "depot_request_dispatch" then return reject_recovery(msg, payload.type) end
    if release_locked() and payload.type == "depot_request_dispatch" then return reject_release(msg, payload.type) end
    if payload.type == "depot_status" then runtime.depot_registry.update_status(depot_id, payload); if payload.tracks then apply_depot_snapshot(depot_id, payload) end
    elseif payload.type == "depot_track_status" then runtime.depot_registry.update_track(depot_id, payload.track_id, payload)
    elseif payload.type == "depot_train_ready" then runtime.depot_registry.update_track(depot_id, payload.track_id, { state = "READY", train_id = payload.train_id, train_name = payload.train_name, route_id = payload.route_id, destination = payload.destination })
    elseif payload.type == "depot_request_dispatch" then if runtime.route_integration then runtime.route_integration.handle_depot_request(payload, msg.src) end; if runtime.logger then runtime.logger.info("depot requested dispatch", payload) end; save_after("depot_dispatch")
    elseif payload.type == "depot_train_arrived" then runtime.depot_registry.update_track(depot_id, payload.track_id, { state = "OCCUPIED", train_id = payload.train_id, train_name = payload.train_name, route_id = payload.route_id })
    elseif payload.type == "depot_train_left" then if runtime.depot_registry.release_track then runtime.depot_registry.release_track(depot_id, payload.track_id) else runtime.depot_registry.update_track(depot_id, payload.track_id, { state = "EMPTY", train_id = nil, train_name = nil, route_id = nil, destination = nil }) end
    elseif payload.type == "depot_fault" then runtime.depot_registry.update_status(depot_id, { state = "FAULT", message = payload.error }); if runtime.logger then runtime.logger.warn("depot fault", payload) end end
    runtime.network.ack_for(msg, true); runtime.ui.mark_dirty()
  end

  local function handle_panel_event(msg)
    if msg.payload and msg.payload.type == "panel_request_snapshot" then audit("panel_snapshot", { src = msg.src }); send_panel_snapshot(msg.src); runtime.network.ack_for(msg, true)
    elseif msg.payload and msg.payload.type == "manual_control" then
      -- the decisive permission check is here, at the receiver: what the panel hides from its screen protects nothing (Kap. 11.4)
      local allowed, why = permissions.check(runtime.config, msg.src, msg.payload.action, msg.payload)
      if not allowed then
        audit("panel_denied", { src = msg.src, action = msg.payload.action, reason = why })
        if runtime.logger then runtime.logger.warn("manual control denied", { src = msg.src, action = msg.payload.action, reason = why }) end
        if runtime.alerts then runtime.alerts.raise("panel_denied:" .. tostring(msg.src), "YELLOW", "Bedienung abgelehnt: " .. tostring(why), nil, { ttl_s = 120 }) end
        runtime.network.ack_for(msg, true)
        return true
      end
      if msg.payload.action == "confirm_recovery" then runtime.confirm_recovery(msg.src, msg.payload.reason); runtime.network.ack_for(msg, true); return true end
      if msg.payload.action == "release_operation" then runtime.release_operation(msg.src); runtime.network.ack_for(msg, true); return true end
      local ok, err = false, "manual control unavailable"
      if runtime.manual_control and not recovery_locked() then ok, err = runtime.manual_control.handle(msg.payload, msg.src) elseif recovery_locked() then ok, err = false, "recovery review required" end
      if not ok and runtime.logger then runtime.logger.warn("manual control rejected", { error = err, src = msg.src }) end
      runtime.network.ack_for(msg, true); runtime.ui.mark_dirty(); save_after("manual_control")
    end
  end

  -- forwarded warnings and errors of the nodes; best-effort messages, so no ack
  local function handle_log_batch(msg)
    if runtime.logs then runtime.logs.ingest(msg.src, msg.payload) end
  end

  local function handle_ota_need(msg)
    if runtime.ota then runtime.ota.on_need(msg) end
    runtime.network.ack_for(msg, true)
  end

  local function handle_ota_confirmed(msg)
    local payload = msg.payload or {}
    if runtime.ota then runtime.ota.on_confirmed(msg) end
    audit("ota_confirmed", { node_id = msg.src, version = payload.version })
    runtime.network.ack_for(msg, true)
    runtime.ui.mark_dirty()
  end

  local function handle_ota_result(msg)
    local payload = msg.payload or {}
    if runtime.ota then runtime.ota.on_result(msg) end
    if payload.success then
      audit("ota_success", { node_id = payload.node_id, files = payload.files, version = payload.version })
      if runtime.logger then runtime.logger.info("OTA update succeeded", { node_id = payload.node_id, version = payload.version }) end
    else
      audit("ota_failed", { node_id = payload.node_id, errors = payload.errors })
      if runtime.logger then runtime.logger.warn("OTA update failed", { node_id = payload.node_id, errors = payload.errors }) end
    end
    runtime.ui.mark_dirty()
  end

  local function handle_fleet_event(msg)
    if runtime.fleet_bridge then runtime.fleet_bridge.handle(msg); runtime.ui.mark_dirty() end
    runtime.network.ack_for(msg, true)
  end

  -- Explicit event type routing table — no fragile prefix matching
  local event_routes = {
    sensor                   = handle_sensor_event,
    -- train events
    train_status             = handle_train_event,
    request_departure        = handle_train_event,
    arrived                  = handle_train_event,
    schedule_applied         = handle_train_event,
    train_fault              = handle_train_event,
    -- station events
    station_status           = handle_station_event,
    station_ready_departure  = handle_station_event,
    station_fault            = handle_station_event,
    platform_status          = handle_station_event,
    train_arrived_station    = handle_station_event,
    train_left_station       = handle_station_event,
    -- depot events
    depot_status             = handle_depot_event,
    depot_track_status       = handle_depot_event,
    depot_train_ready        = handle_depot_event,
    depot_request_dispatch   = handle_depot_event,
    depot_train_arrived      = handle_depot_event,
    depot_train_left         = handle_depot_event,
    depot_fault              = handle_depot_event,
    -- panel events
    panel_request_snapshot   = handle_panel_event,
    manual_control           = handle_panel_event,
    -- the fleet pair asks for routes and is told what became of them (src/master/fleet_bridge.lua)
    -- what the fleet pairs report for the panels (lines, trips, cargo) and the answers to the operator commands that were forwarded to them
    fleet_status             = function(msg)
      local payload = msg.payload or {}
      if type(payload.pair_id) == "string" and type(payload.report) == "table" then
        runtime.fleet_reports[payload.pair_id] = { report = payload.report, healthy = payload.healthy == true, at = time.now_s(), node = msg.src }
      end
      runtime.network.ack_for(msg, true)
    end,
    fleet_admin_result       = function(msg)
      local payload = msg.payload or {}
      if type(payload.request_id) == "string" then
        runtime.fleet_results[payload.request_id] = { ok = payload.ok == true, reason = payload.reason, problems = payload.problems, version = payload.version, line_id = payload.line_id, conflict = payload.conflict == true, pair_id = payload.pair_id, at = time.now_s() }
        runtime.fleet_result_order[#runtime.fleet_result_order + 1] = payload.request_id
        while #runtime.fleet_result_order > 12 do runtime.fleet_results[table.remove(runtime.fleet_result_order, 1)] = nil end
        audit("fleet_admin_result", { request_id = payload.request_id, pair_id = payload.pair_id, ok = payload.ok == true, reason = payload.reason })
      end
      runtime.network.ack_for(msg, true)
    end,
    fleet_route              = handle_fleet_event,
    fleet_release            = handle_fleet_event,
    fleet_hold               = handle_fleet_event,
    fleet_reconstruct        = handle_fleet_event,
    fleet_complete           = handle_fleet_event,
    -- OTA update results
    ota_result               = handle_ota_result,
    ota_need                 = handle_ota_need,
    log_batch                = handle_log_batch,
    ota_confirmed            = handle_ota_confirmed,
    -- pairing: a node tells which entry of the plan it is, the setup wizard asks whether the master knows the computer
    pair_announce            = function(msg)
      local payload = msg.payload or {}
      note_candidate(msg.src, { role = payload.role, entry = payload.entry, setup = payload.setup })
      runtime.network.ack_for(msg, true)
      runtime.ui.mark_dirty()
    end,
    -- a station or depot computer asks for the plan (setup wizard): the plan is handed out, in parts, to those two roles of the plan and to
    -- nobody else; the others are told why not (a small answer, nothing is kept for them)
    plan_get                 = function(msg)
      local payload = msg.payload or {}
      local role = plan_role_of(msg.src)
      local reply
      if not runtime.plan_service then reply = { ok = false, state = "refused", reason = "unavailable" }
      elseif not role then reply = { ok = false, state = "refused", reason = "not_in_plan" }
      elseif payload.role ~= nil and payload.role ~= role then reply = { ok = false, state = "refused", reason = "conflict" }
      elseif role ~= "station" and role ~= "depot" and role ~= "panel" then reply = { ok = false, state = "refused", reason = "role" }
      else
        reply = runtime.plan_service.part(payload.index, payload.version)
        if reply.ok and reply.index == 1 then audit("plan_served", { node_id = msg.src, version = reply.version, parts = reply.total }) end
      end
      reply.cmd, reply.question = "plan_part", msg.id
      -- no retry state on the master: the asker asks for a part again when it did not arrive
      runtime.network.send("cmd", msg.src, reply)
      runtime.network.ack_for(msg, true)
    end,
    pair_probe               = function(msg)
      local payload = msg.payload or {}
      note_candidate(msg.src, { role = payload.role, entry = payload.entry, setup = payload.setup }, msg.id, payload.echo)
      runtime.network.ack_for(msg, true)
      runtime.ui.mark_dirty()
    end,
  }

  -- Who may send what. The plan decides who is a node and with which role; an event type that belongs to one role (a sensor event comes from a
  -- sensor and names itself, manual control comes from a panel) is taken from that role only, every other event (log, update) from any node
  -- of the plan. Only the announcements of pairing are open to every computer.
  local OPEN_EVENTS = { pair_announce = true, pair_probe = true, plan_get = true }
  local EVENT_ROLE = {
    sensor = "sensor",
    train_status = "train", request_departure = "train", arrived = "train", schedule_applied = "train", train_fault = "train",
    station_status = "station", station_ready_departure = "station", station_fault = "station", platform_status = "station",
    train_arrived_station = "station", train_left_station = "station",
    depot_status = "depot", depot_track_status = "depot", depot_train_ready = "depot", depot_request_dispatch = "depot",
    depot_train_arrived = "depot", depot_train_left = "depot", depot_fault = "depot",
    panel_request_snapshot = "panel", manual_control = "panel",
    fleet_route = "fleet", fleet_release = "fleet", fleet_hold = "fleet", fleet_reconstruct = "fleet", fleet_complete = "fleet",
  }

  -- returns nil when the sender may send this event, else the reason and whether the sender is a computer of the plan at all
  local function event_sender_problem(msg, ptype)
    if OPEN_EVENTS[ptype] then return nil end
    local payload = msg.payload or {}
    local planned = plan_role_of(msg.src)
    if not planned then return "sender is not in the plan", false end
    local needed = EVENT_ROLE[ptype]
    if needed and planned ~= needed then return ptype .. " from a " .. planned .. " node", true end
    if ptype == "sensor" and payload.sensor_id ~= msg.src then
      return "sensor event for " .. tostring(payload.sensor_id) .. " sent by " .. tostring(msg.src), true
    end
    if ptype == "manual_control" then
      local sender = runtime.registry.all and runtime.registry.all()[msg.src]
      if not sender or sender.role ~= "panel" then return "manual control from a node that is not a panel", true end
    end
    return nil
  end

  -- observations and requests that the dispatcher would act on: the standby master takes them in (acknowledges them) and leaves the decision to the leader
  local STANDBY_EVENTS = {
    sensor = true, train_status = true, request_departure = true, arrived = true, schedule_applied = true, train_fault = true,
    station_status = true, station_ready_departure = true, station_fault = true, platform_status = true, train_arrived_station = true, train_left_station = true,
    depot_status = true, depot_track_status = true, depot_train_ready = true, depot_request_dispatch = true, depot_train_arrived = true, depot_train_left = true, depot_fault = true,
    manual_control = true,
    fleet_route = true, fleet_release = true, fleet_hold = true, fleet_reconstruct = true, fleet_complete = true,
  }

  handlers.event = function(msg)
    local ptype = msg.payload and tostring(msg.payload.type) or ""
    if runtime.ha and STANDBY_EVENTS[ptype] and not runtime.active() then
      runtime.network.ack_for(msg, true)
      return true
    end
    local problem, in_plan = event_sender_problem(msg, ptype)
    if problem then
      if in_plan then
        audit("event_rejected", { src = msg.src, type = ptype, reason = problem })
        event_once.warn("event:" .. tostring(msg.src) .. ":" .. ptype, "event rejected", { src = msg.src, type = ptype, reason = problem })
        if runtime.alerts then runtime.alerts.raise("event:" .. tostring(msg.src) .. ":" .. ptype, "YELLOW", "Ereignis abgelehnt: " .. problem, nil, { ttl_s = 120 }) end
      else
        -- a computer the plan does not list: one line per minute for all of them together (strangers must not fill the log or the alerts)
        if unplanned_once.first("unplanned") then
          audit("event_rejected", { src = msg.src, type = ptype, reason = problem })
          if runtime.logger then runtime.logger.warn("events of computers that are not in the plan are ignored", { src = msg.src, type = ptype }) end
        end
      end
      -- acknowledged all the same: the sender must not retry what will never be accepted
      runtime.network.ack_for(msg, true)
      return true
    end
    local handler = event_routes[ptype]
    if handler then
      handler(msg)
    elseif runtime.logger then
      runtime.logger.warn("unrouted event type", { type = ptype, src = msg.src })
    end
    return true
  end

  handlers.cmd = function(msg)
    if runtime.ha and runtime.ha.handle(msg) then return true end
    if runtime.replica and runtime.replica.handle(msg) then return true end
    runtime.ui.mark_dirty()
    return true
  end
  handlers.ack = function() runtime.ui.mark_dirty(); return true end
  handlers.err = function(msg) audit("node_error", { src = msg.src, payload = msg.payload }); if runtime.logger then runtime.logger.warn("node error", msg.payload or {}) end; runtime.ui.mark_dirty(); return true end

  local function check_timeouts()
    local now = time.now_s()
    local any_timeout = false
    for node_id, node_state in pairs(runtime.registry.all()) do
      -- a node that is receiving, swapping or rebooting for an update is silent on purpose
      local updating = runtime.ota and runtime.ota.is_updating and runtime.ota.is_updating(node_id)
      -- once per outage: a node that is down already was dealt with (timeout_node, audit, state save)
      if not updating and tostring(node_state.status):upper() ~= "DOWN" and now - node_state.last_seen > runtime.heartbeat_timeout_s then
        runtime.registry.mark_down(node_id)
        if runtime.active() then
          local ok, err = pcall(runtime.dispatcher.timeout_node, node_id)
          if not ok and runtime.logger then runtime.logger.warn("timeout_node error", { node_id = node_id, error = tostring(err) }) end
        end
        audit("node_timeout", { node_id = node_id, role = node_state.role })
        if runtime.train_registry and node_state.role == "train" then runtime.train_registry.mark_offline(node_id) end
        if runtime.station_registry and node_state.role == "station" then runtime.station_registry.mark_offline(node_id) end
        if runtime.depot_registry and node_state.role == "depot" then runtime.depot_registry.mark_offline(node_id) end
        any_timeout = true
      end
    end
    -- Single save and dirty-mark after all timeouts processed (not per-node)
    if any_timeout then runtime.ui.mark_dirty(); save_after("timeout") end
  end

  function runtime.start()
    -- a network that asks for a release says so until the operator gave it
    if release_locked() and runtime.alerts then
      runtime.alerts.raise("release:required", "YELLOW", "Betrieb nicht freigegeben (Seite EINRICHTUNG: BETRIEB FREIGEBEN)")
    end
    local ok_restore, restore_err = pcall(runtime.restore_recovery_state)
    if not ok_restore and runtime.logger then
      runtime.logger.warn("state restore error on start", { error = tostring(restore_err) })
    end
    -- whatever the signals showed before the master came up: RED everywhere, GREEN for the trains that wait
    if runtime.dispatcher.refresh_signals and (runtime.config or {}).signal_refresh_per_s ~= 0 and runtime.active() then
      local ok_refresh, refreshed = pcall(runtime.dispatcher.refresh_signals)
      if ok_refresh then note_signal_result(refreshed, "start") elseif runtime.logger then runtime.logger.warn("signal refresh error on start", { error = tostring(refreshed) }) end
    end
    runtime.ticker.start()
    -- the code of an update that just landed got this far: keep it (an unconfirmed first boot is rolled back)
    pcall(function() require("src.shared.ota_recovery").confirm() end)
    runtime.ui.draw()
  end

  runtime.check_timeouts = check_timeouts
  -- the election: twice a second; a change of leadership is written to the audit log and raises an alert for the operator
  if runtime.ha then
    local was_active = false
    local function raise(key, text) if runtime.alerts then runtime.alerts.raise(key, "YELLOW", text, nil, { ttl_s = 300 }) end end
    -- noticed by whichever comes first: the election job, or the end of a message step (a vote can make this master the leader in the middle of a message);
    -- the state it starts from is taken before anything of its own is written
    function runtime.check_leadership()
      local active = runtime.ha.is_leader()
      if active == was_active then return end
      was_active = active
      audit(active and "leader_gained" or "leader_lost", { term = runtime.ha.term() })
      if active then
        raise("ha:leader", "Dieser Master fuehrt jetzt (Periode " .. tostring(runtime.ha.term()) .. ")")
        -- the state that both masters confirmed is the state this leader starts from; what was only prepared is cut (replica.promote)
        if runtime.replica then
          local state = runtime.replica.promote()
          if type(state) == "table" and next(state) ~= nil and runtime.dispatcher.restore then
            local restored, restore_err = runtime.dispatcher.restore(state)
            audit("failover_restored", { ok = restored == true, error = restore_err, committed_idx = runtime.replica.committed_idx() })
            if restored then
              -- trains and blocks as the dead master left them: the operator confirms what the track shows before new routes are given
              runtime.recovery.restored, runtime.recovery.required, runtime.recovery.confirmed = true, true, false
              if runtime.dispatcher.refresh_signals then pcall(runtime.dispatcher.refresh_signals) end
            end
          end
        end
      else
        raise("ha:leader", "Dieser Master fuehrt nicht (mehr)")
        if runtime.replica then runtime.replica.demote() end
        if runtime.barrier then runtime.barrier.discard("leadership lost") end
      end
      runtime.ui.mark_dirty()
    end
    runtime.ticker.every("election", 0.5, function()
      runtime.ha.tick()
      runtime.check_leadership()
      if runtime.replica and runtime.ha.is_leader() then
        if runtime.replica.peer_ok() then
          if runtime.alerts and runtime.alerts.clear then runtime.alerts.clear("ha:partner") end
        else
          raise("ha:partner", "Zweiter Master antwortet nicht: keine neuen Freigaben")
        end
      end
    end)
    if runtime.replica then runtime.ticker.every("replica", 0.5, function() runtime.replica.tick() end) end
  end

  runtime.ticker.every("timeouts", 1, function() runtime.check_timeouts() end)
  -- keys issued or revoked with scripts/keys.lua count within seconds (the list of keys is read again when it changed)
  if runtime.network.auth and runtime.network.auth.reload_trust then runtime.ticker.every("trust", 5, function() runtime.network.auth.reload_trust() end) end

  -- Blocks that faulted because a node went silent are cleared again once the node is back and the detectors show the
  -- track free (config auto_clear_faults = false switches this off). See Dispatcher.auto_clear_faults for the rules.
  function runtime.auto_clear_faults()
    local cfg = runtime.config or {}
    if cfg.auto_clear_faults == false or not runtime.dispatcher.auto_clear_faults then return {} end
    if maintenance_enabled() or recovery_locked() then return {} end
    local now = time.now_s()
    local cleared = runtime.dispatcher.auto_clear_faults({
      now = now, stable_s = cfg.auto_clear_stable_s, max_age_s = cfg.auto_clear_max_age_s,
      node_up = function(node_id)
        local node = runtime.registry.all()[node_id]
        return node ~= nil and tostring(node.status):upper() == "UP" and now - node.last_seen <= runtime.heartbeat_timeout_s
      end,
      sensor_level = function(sensor_id)
        local level = runtime.sensor_levels[sensor_id]
        if not level then return nil, nil end
        return level.occupied, level.at
      end
    })
    for _, item in ipairs(cleared) do audit("fault_auto_cleared", item) end
    if #cleared > 0 then
      if runtime.route_integration then runtime.route_integration.process_queue() end
      runtime.ui.mark_dirty(); save_after("auto_clear")
    end
    return cleared
  end
  runtime.ticker.every("auto_clear", 2, function() if runtime.active() then runtime.auto_clear_faults() end end)

  -- Blocks nobody holds are proven free by fresh detector levels (every sensor of the block says free); with config.occupancy_proof = "on" a route is only given over such blocks.
  function runtime.prove_free_blocks()
    if not runtime.dispatcher.prove_free_from_sensors or maintenance_enabled() or recovery_locked() then return {} end
    local cfg = runtime.config or {}
    local proven = runtime.dispatcher.prove_free_from_sensors({
      now = time.now_s(), max_age_s = cfg.auto_clear_max_age_s,
      sensor_level = function(sensor_id)
        local level = runtime.sensor_levels[sensor_id]
        if not level then return nil, nil end
        return level.occupied, level.at
      end
    })
    if #proven > 0 then
      if runtime.route_integration then runtime.route_integration.process_queue() end
      runtime.ui.mark_dirty()
    end
    return proven
  end
  -- the fleet pair hears what became of its routes and which blocks can be reserved
  runtime.ticker.every("fleet_bridge", 1, function() if runtime.fleet_bridge and runtime.active() then runtime.fleet_bridge.poll() end end)
  runtime.ticker.every("fleet_blocks", 2, function() if runtime.fleet_bridge and runtime.active() then runtime.fleet_bridge.report_blocks() end end)
  runtime.ticker.every("prove_free", 2, function() if runtime.active() then runtime.prove_free_blocks() end end)

  -- Rolling signal refresh: a few blocks per second, so a signal that lost its state (node reboot, chunk reload, lost
  -- command) is corrected within one round. config signal_refresh_per_s = 0 turns it off.
  function runtime.refresh_signals()
    local per_second = (runtime.config or {}).signal_refresh_per_s
    if per_second == nil then per_second = 2 end
    if per_second <= 0 or not runtime.dispatcher.refresh_signals then return nil end
    local result = runtime.dispatcher.refresh_signals(per_second)
    note_signal_result(result, "refresh")
    return result
  end
  runtime.ticker.every("signals", 1, function() if runtime.active() then runtime.refresh_signals() end end)

  runtime.ticker.every("dwell", 1, function()
    if runtime.route_integration and runtime.active() and not maintenance_enabled() and not recovery_locked() and not release_locked() then
      runtime.route_integration.process_due()
      save_after("dwell")
    end
    runtime.ui.mark_dirty()
  end)

  if runtime.ota and runtime.ota.tick then runtime.ticker.every("ota", 1, runtime.ota.tick) end

  -- the list of alerts follows the state of the network; one pass over nodes and blocks every 2 s
  if runtime.alerts then
    local rules = alert_rules.new(runtime.alerts)
    local traced, last_trace_at = {}, nil
    runtime.ticker.every("alerts", 2, function()
      rules.evaluate(status_model.collect({
        registry = runtime.registry, dispatcher = runtime.dispatcher, maintenance = runtime.maintenance,
        ota = function() return runtime.ota end, recovery = function() return runtime.recovery end
      }))
      runtime.alerts.tick()
      -- the moment a block faults, the last 500 dispatcher calls go to traces/fault_<n>.json (at most once a minute, 5 files),
      -- ready for scripts/replay_trace.lua
      if runtime.trace then
        local now = time.now_s()
        local active = {}
        for _, alert in ipairs(runtime.alerts.list({ active_only = true })) do
          if alert.severity == "RED" and alert.key:sub(1, 6) == "block:" then
            active[alert.key] = true
            if not traced[alert.key] and (not last_trace_at or now - last_trace_at >= 60) then
              local path, err = runtime.trace.dump_slot("traces/fault_", 5)
              traced[alert.key] = true
              last_trace_at = now
              audit("trace_dumped", { path = path, error = err, reason = alert.key })
            end
          end
        end
        for key in pairs(traced) do if not active[key] then traced[key] = nil end end
      end
      runtime.ui.mark_dirty()
    end)
  end

  runtime.ticker.every("ui", 0.2, function()
    local ok, err = pcall(runtime.ui.draw)
    if ok then ui_once.ok("ui_draw", "ui draws again")
    else ui_once.warn("ui_draw", "ui draw error", { error = tostring(err) }) end
  end)

  function runtime.handle_event(event)
    if event[1] == "modem_message" then
      local msg = event[5]
      local status = runtime.network.receive(msg)
      if status == "ok" then
        local ok, err = pcall(message_handlers.dispatch, msg, handlers)
        if not ok and runtime.logger then runtime.logger.error("message handler error", { error = tostring(err), type = msg and msg.type, src = msg and msg.src }) end
      elseif status == "duplicate" and (msg.type == "event" or msg.type == "register") then
        -- the sender retries because our ack got lost: confirm again, the work was done the first time
        runtime.network.ack_for(msg, true)
      end
    elseif event[1] == "monitor_touch" then runtime.ui.handle_touch(event[3], event[4])
    end
    -- after the message: a queued heartbeat must be counted before the timeout job looks at last_seen
    runtime.ticker.handle_event(event)
    runtime.network.tick()
    runtime.sync_step()
  end

  -- dual commit: what this step changed in the state is written, sent to the other master and, once it confirmed, the actuations that depend on it are carried out
  function runtime.sync_step()
    if not runtime.replica or not runtime.barrier then return end
    if runtime.check_leadership then runtime.check_leadership() end
    if runtime.ha and runtime.ha.is_leader() then
      local idx = runtime.replica.capture()
      -- the reservations of this change are PREPARED when the standby holds them and COMMITTED when both have committed; only then the dispatcher gives a signal for them
      if idx and runtime.dispatcher.tag_commit then
        runtime.dispatcher.tag_commit(idx)
        runtime.dispatcher.advance_commits(runtime.replica.prepared_idx(), runtime.replica.committed_idx())
      end
      -- a change that could not be written is never confirmed: whatever it produced waits (and is dropped when the leadership goes)
      runtime.barrier.tag(idx or math.huge)
      runtime.barrier.release(function(need) return runtime.replica.confirmed(need) end)
    else
      runtime.barrier.discard("not the leader")
    end
  end

  function runtime.run() runtime.start(); while true do runtime.handle_event({ runtime.pull_event() }) end end
  return runtime
end

return master_runtime

