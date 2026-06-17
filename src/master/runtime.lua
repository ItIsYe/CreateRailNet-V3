--[[
Purpose: Master event runtime for modem, UI, timeout handling, audit, maintenance guard, persistent dispatcher recovery, and safe recovery mode.
Public API: new(context) -> runtime with handle_event(event), run(), save_recovery_state(), restore_recovery_state(), confirm_recovery().
]]

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
    state_store = context.state_store or master_state_store.new((context.config and context.config.state_file) or nil),
    auto_restore_state = context.auto_restore_state ~= false,
    auto_save_state = context.auto_save_state ~= false,
    recovery = { restored = false, saved = false, required = false, confirmed = true, last_error = nil, last_save_reason = nil },
    pull_event = context.pull_event or os.pullEvent,
    heartbeat_timeout_s = context.heartbeat_timeout_s or 6,
    timeout_timer = nil,
    ui_timer = nil,
    dwell_timer = nil
  }

  local handlers = {}

  local function audit(kind, data) if runtime.audit_log then runtime.audit_log.record(kind, data) end end
  local function maintenance_enabled() if not runtime.maintenance then return false end; if runtime.maintenance.is_locked then return runtime.maintenance.is_locked() end; if runtime.maintenance.status then return runtime.maintenance.status().enabled == true end; return runtime.maintenance.enabled == true end
  local function recovery_locked() return runtime.recovery.required == true and runtime.recovery.confirmed ~= true end

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
    runtime.network.ack_for(msg)
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
    runtime.network.ack_for(msg)
    runtime.ui.mark_dirty()
    return true
  end

  local function panel_snapshot()
    local context_view = { config = runtime.config, registry = runtime.registry, logger = runtime.logger, dispatcher = runtime.dispatcher, route_integration = runtime.route_integration, service_plan_registry = runtime.service_plan_registry, audit_log = runtime.audit_log, maintenance = runtime.maintenance }
    local master_state = maintenance_enabled() and "MAINTENANCE" or (recovery_locked() and "RECOVERY" or "ONLINE")
    local built = { cmd = "panel_update", master_state = master_state, overview = runtime.dispatcher and runtime.dispatcher.get_overview() or {}, trains = runtime.train_registry and runtime.train_registry.list() or {}, stations = runtime.station_registry and runtime.station_registry.list() or {}, depots = runtime.depot_registry and runtime.depot_registry.list() or {}, service_plans = runtime.service_plan_registry and runtime.service_plan_registry.list() or {}, diagnostics = diagnostics.build(context_view) }
    built.diagnostics.recovery = runtime.recovery
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

  handlers.register = function(msg)
    local role = msg.payload and msg.payload.role
    audit("register", { src = msg.src, role = role })
    local previous = runtime.registry.all and runtime.registry.all()[msg.src]
    runtime.registry.register(msg.src, role, nil)
    if previous and previous.status == "down" then audit("node_reconnect", { node_id = msg.src, role = role }) end
    if role == "train" and runtime.train_registry then
      local train_id = msg.payload.train_id or msg.src
      runtime.train_registry.register(train_id, msg.src, msg.payload or {})
      if runtime.route_integration and not maintenance_enabled() and not recovery_locked() then runtime.route_integration.send_service_plan(train_id) end
    elseif role == "station" and runtime.station_registry then apply_station_snapshot(msg.payload.station_id or msg.src, msg.payload or {})
    elseif role == "depot" and runtime.depot_registry then apply_depot_snapshot(msg.payload.depot_id or msg.src, msg.payload or {})
    elseif role == "panel" then send_panel_snapshot(msg.src) end
    runtime.network.ack_for(msg); runtime.ui.mark_dirty(); save_after("register"); return true
  end

  handlers.heartbeat = function(msg)
    runtime.registry.heartbeat(msg.src)
    if msg.payload and msg.payload.role == "train" and runtime.train_registry then runtime.train_registry.register(msg.payload.train_id or msg.src, msg.src, msg.payload)
    elseif msg.payload and msg.payload.role == "station" and runtime.station_registry then apply_station_snapshot(msg.payload.station_id or msg.src, msg.payload)
    elseif msg.payload and msg.payload.role == "depot" and runtime.depot_registry then apply_depot_snapshot(msg.payload.depot_id or msg.src, msg.payload) end
    runtime.ui.mark_dirty(); return true
  end

  local function handle_sensor_event(msg)
    if maintenance_enabled() then return reject_maintenance(msg, "sensor") end
    audit("sensor", { src = msg.src, sensor_id = msg.payload.sensor_id, action = msg.payload.action })
    local ok, err = runtime.dispatcher.on_sensor_event_by_sensor(msg.payload.sensor_id, msg.payload.action)
    runtime.network.ack_for(msg)
    if ok == false and runtime.logger then runtime.logger.warn("sensor event rejected", { error = err, sensor_id = msg.payload.sensor_id }) end
    if runtime.route_integration and not recovery_locked() then runtime.route_integration.process_queue() end
    runtime.ui.mark_dirty(); save_after("sensor")
  end

  local function handle_train_event(msg)
    if not runtime.train_registry then runtime.network.ack_for(msg); return end
    local payload = msg.payload or {}; local train_id = payload.train_id or msg.src
    audit("train_event", { src = msg.src, train_id = train_id, event_type = payload.type })
    if maintenance_enabled() and (payload.type == "request_departure" or payload.type == "arrived") then return reject_maintenance(msg, payload.type) end
    if recovery_locked() and payload.type == "request_departure" then return reject_recovery(msg, payload.type) end
    if payload.type == "train_status" then runtime.train_registry.update_status(train_id, payload)
    elseif payload.type == "request_departure" then if runtime.route_integration then runtime.route_integration.handle_train_request(payload, msg.src) end; if runtime.logger then runtime.logger.info("train requested departure", payload) end; save_after("route_request")
    elseif payload.type == "arrived" then if runtime.route_integration then runtime.route_integration.handle_train_arrival(payload, msg.src) end; save_after("train_arrival")
    elseif payload.type == "schedule_applied" then runtime.train_registry.update_status(train_id, { state = payload.state or (payload.schedule_state == "failed" and "SCHEDULE_FAILED" or "ROUTE_ASSIGNED"), route_id = payload.route_id, destination = payload.destination, create_destination = payload.create_destination, schedule_state = payload.schedule_state, schedule_station = payload.schedule_station, service_plan = payload.service_plan, service_stop_index = payload.service_stop_index, message = payload.message })
    elseif payload.type == "train_fault" then runtime.train_registry.update_status(train_id, { state = "FAULT", error = payload.error, message = payload.error }); if runtime.logger then runtime.logger.warn("train fault", payload) end end
    runtime.network.ack_for(msg); runtime.ui.mark_dirty()
  end

  local function handle_station_event(msg)
    if not runtime.station_registry then runtime.network.ack_for(msg); return end
    local payload = msg.payload or {}; local station_id = payload.station_id or msg.src
    audit("station_event", { src = msg.src, station_id = station_id, event_type = payload.type })
    if maintenance_enabled() and payload.type == "station_ready_departure" then return reject_maintenance(msg, payload.type) end
    if recovery_locked() and payload.type == "station_ready_departure" then return reject_recovery(msg, payload.type) end
    if payload.type == "station_status" then runtime.station_registry.update_status(station_id, payload); if payload.platforms then apply_station_snapshot(station_id, payload) end
    elseif payload.type == "platform_status" then runtime.station_registry.update_platform(station_id, payload.platform_id, payload)
    elseif payload.type == "train_arrived_station" then runtime.station_registry.update_platform(station_id, payload.platform_id, { state = "DWELLING", train_id = payload.train_id, train_name = payload.train_name, route_id = payload.route_id, destination = payload.destination })
    elseif payload.type == "train_left_station" then if runtime.station_registry.release_platform then runtime.station_registry.release_platform(station_id, payload.platform_id) else runtime.station_registry.update_platform(station_id, payload.platform_id, { state = "EMPTY", train_id = nil, train_name = nil, route_id = nil, destination = nil }) end
    elseif payload.type == "station_ready_departure" then if runtime.route_integration then runtime.route_integration.handle_station_ready(payload, msg.src) end; save_after("station_departure")
    elseif payload.type == "station_fault" then runtime.station_registry.update_status(station_id, { state = "FAULT", message = payload.error }); if runtime.logger then runtime.logger.warn("station fault", payload) end end
    runtime.network.ack_for(msg); runtime.ui.mark_dirty()
  end

  local function handle_depot_event(msg)
    if not runtime.depot_registry then runtime.network.ack_for(msg); return end
    local payload = msg.payload or {}; local depot_id = payload.depot_id or msg.src
    audit("depot_event", { src = msg.src, depot_id = depot_id, event_type = payload.type })
    if maintenance_enabled() and payload.type == "depot_request_dispatch" then return reject_maintenance(msg, payload.type) end
    if recovery_locked() and payload.type == "depot_request_dispatch" then return reject_recovery(msg, payload.type) end
    if payload.type == "depot_status" then runtime.depot_registry.update_status(depot_id, payload); if payload.tracks then apply_depot_snapshot(depot_id, payload) end
    elseif payload.type == "depot_track_status" then runtime.depot_registry.update_track(depot_id, payload.track_id, payload)
    elseif payload.type == "depot_train_ready" then runtime.depot_registry.update_track(depot_id, payload.track_id, { state = "READY", train_id = payload.train_id, train_name = payload.train_name, route_id = payload.route_id, destination = payload.destination })
    elseif payload.type == "depot_request_dispatch" then if runtime.route_integration then runtime.route_integration.handle_depot_request(payload, msg.src) end; if runtime.logger then runtime.logger.info("depot requested dispatch", payload) end; save_after("depot_dispatch")
    elseif payload.type == "depot_train_arrived" then runtime.depot_registry.update_track(depot_id, payload.track_id, { state = "OCCUPIED", train_id = payload.train_id, train_name = payload.train_name, route_id = payload.route_id })
    elseif payload.type == "depot_train_left" then if runtime.depot_registry.release_track then runtime.depot_registry.release_track(depot_id, payload.track_id) else runtime.depot_registry.update_track(depot_id, payload.track_id, { state = "EMPTY", train_id = nil, train_name = nil, route_id = nil, destination = nil }) end
    elseif payload.type == "depot_fault" then runtime.depot_registry.update_status(depot_id, { state = "FAULT", message = payload.error }); if runtime.logger then runtime.logger.warn("depot fault", payload) end end
    runtime.network.ack_for(msg); runtime.ui.mark_dirty()
  end

  local function handle_panel_event(msg)
    if msg.payload and msg.payload.type == "panel_request_snapshot" then audit("panel_snapshot", { src = msg.src }); send_panel_snapshot(msg.src); runtime.network.ack_for(msg)
    elseif msg.payload and msg.payload.type == "manual_control" then
      if msg.payload.action == "confirm_recovery" then runtime.confirm_recovery(msg.src, msg.payload.reason); runtime.network.ack_for(msg); return true end
      local ok, err = false, "manual control unavailable"
      if runtime.manual_control and not recovery_locked() then ok, err = runtime.manual_control.handle(msg.payload, msg.src) elseif recovery_locked() then ok, err = false, "recovery review required" end
      if not ok and runtime.logger then runtime.logger.warn("manual control rejected", { error = err, src = msg.src }) end
      runtime.network.ack_for(msg); runtime.ui.mark_dirty(); save_after("manual_control")
    end
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
  }

  handlers.event = function(msg)
    local ptype = msg.payload and tostring(msg.payload.type) or ""
    local handler = event_routes[ptype]
    if handler then
      handler(msg)
    elseif runtime.logger then
      runtime.logger.warn("unrouted event type", { type = ptype, src = msg.src })
    end
    return true
  end

  handlers.cmd = function() runtime.ui.mark_dirty(); return true end
  handlers.ack = function() runtime.ui.mark_dirty(); return true end
  handlers.err = function(msg) audit("node_error", { src = msg.src, payload = msg.payload }); if runtime.logger then runtime.logger.warn("node error", msg.payload or {}) end; runtime.ui.mark_dirty(); return true end

  local function check_timeouts()
    local now = os.time()
    local any_timeout = false
    for node_id, node_state in pairs(runtime.registry.all()) do
      if now - node_state.last_seen > runtime.heartbeat_timeout_s then
        runtime.registry.mark_down(node_id)
        local ok, err = pcall(runtime.dispatcher.timeout_node, node_id)
        if not ok and runtime.logger then runtime.logger.warn("timeout_node error", { node_id = node_id, error = tostring(err) }) end
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
    local ok_restore, restore_err = pcall(runtime.restore_recovery_state)
    if not ok_restore and runtime.logger then
      runtime.logger.warn("state restore error on start", { error = tostring(restore_err) })
    end
    runtime.timeout_timer = os.startTimer(1)
    runtime.ui_timer = os.startTimer(0.2)
    runtime.dwell_timer = os.startTimer(1)
    runtime.ui.draw()
  end

  function runtime.handle_event(event)
    if event[1] == "modem_message" then
      local msg = event[5]
      local status = runtime.network.receive(msg)
      if status == "ok" then
        local ok, err = pcall(message_handlers.dispatch, msg, handlers)
        if not ok and runtime.logger then runtime.logger.error("message handler error", { error = tostring(err), type = msg and msg.type, src = msg and msg.src }) end
      end
    elseif event[1] == "monitor_touch" then runtime.ui.handle_touch(event[3], event[4])
    elseif event[1] == "timer" and event[2] == runtime.timeout_timer then check_timeouts(); runtime.timeout_timer = os.startTimer(1)
    elseif event[1] == "timer" and event[2] == runtime.dwell_timer then if runtime.route_integration and not maintenance_enabled() and not recovery_locked() then runtime.route_integration.process_due(); save_after("dwell") end; runtime.dwell_timer = os.startTimer(1); runtime.ui.mark_dirty()
    elseif event[1] == "timer" and event[2] == runtime.ui_timer then
      local ok, err = pcall(runtime.ui.draw)
      if not ok and runtime.logger then runtime.logger.warn("ui draw error", { error = tostring(err) }) end
      runtime.ui_timer = os.startTimer(0.2)
    end
    runtime.network.tick()
  end

  function runtime.run() runtime.start(); while true do runtime.handle_event({ runtime.pull_event() }) end end
  return runtime
end

return master_runtime

