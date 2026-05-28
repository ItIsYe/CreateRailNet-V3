--[[
Purpose: Master event runtime for modem, UI, and timeout handling.
Public API: new(context) -> runtime with handle_event(event), run().
]]

local message_handlers = require("src.shared.message_handlers")

local master_runtime = {}

function master_runtime.new(context)
  local runtime = {
    registry = context.registry,
    train_registry = context.train_registry,
    station_registry = context.station_registry,
    depot_registry = context.depot_registry,
    route_integration = context.route_integration,
    dispatcher = context.dispatcher,
    network = context.network,
    ui = context.ui,
    logger = context.logger,
    pull_event = context.pull_event or os.pullEvent,
    heartbeat_timeout_s = context.heartbeat_timeout_s or 6,
    timeout_timer = nil,
    ui_timer = nil
  }

  local handlers = {}

  local function panel_snapshot()
    return {
      cmd = "panel_update",
      master_state = "ONLINE",
      overview = runtime.dispatcher and runtime.dispatcher.get_overview() or {},
      trains = runtime.train_registry and runtime.train_registry.list() or {},
      stations = runtime.station_registry and runtime.station_registry.list() or {},
      depots = runtime.depot_registry and runtime.depot_registry.list() or {},
      diagnostics = {
        nodes = runtime.registry and runtime.registry.all() or {},
        queue = runtime.dispatcher and runtime.dispatcher.get_queue and runtime.dispatcher.get_queue() or {},
        switch_locks = runtime.dispatcher and runtime.dispatcher.get_switch_locks and runtime.dispatcher.get_switch_locks() or {}
      }
    }
  end

  local function send_panel_snapshot(dst)
    runtime.network.send("cmd", dst, panel_snapshot())
  end

  handlers.register = function(msg)
    local role = msg.payload and msg.payload.role
    runtime.registry.register(msg.src, role, nil)
    if role == "train" and runtime.train_registry then
      runtime.train_registry.register(msg.payload.train_id or msg.src, msg.src, msg.payload or {})
    elseif role == "station" and runtime.station_registry then
      runtime.station_registry.register(msg.payload.station_id or msg.src, msg.src, msg.payload or {})
    elseif role == "depot" and runtime.depot_registry then
      runtime.depot_registry.register(msg.payload.depot_id or msg.src, msg.src, msg.payload or {})
    elseif role == "panel" then
      send_panel_snapshot(msg.src)
    end
    runtime.network.ack_for(msg)
    runtime.ui.mark_dirty()
    return true
  end

  handlers.heartbeat = function(msg)
    runtime.registry.heartbeat(msg.src)
    if msg.payload and msg.payload.role == "train" and runtime.train_registry then
      runtime.train_registry.register(msg.payload.train_id or msg.src, msg.src, msg.payload)
    elseif msg.payload and msg.payload.role == "station" and runtime.station_registry then
      runtime.station_registry.register(msg.payload.station_id or msg.src, msg.src, msg.payload)
    elseif msg.payload and msg.payload.role == "depot" and runtime.depot_registry then
      runtime.depot_registry.register(msg.payload.depot_id or msg.src, msg.src, msg.payload)
    end
    runtime.ui.mark_dirty()
    return true
  end

  local function handle_sensor_event(msg)
    local ok, err = runtime.dispatcher.on_sensor_event_by_sensor(msg.payload.sensor_id, msg.payload.action)
    runtime.network.ack_for(msg)
    if ok == false and runtime.logger then
      runtime.logger.warn("sensor event rejected", { error = err, sensor_id = msg.payload.sensor_id })
    end
    if runtime.route_integration then runtime.route_integration.process_queue() end
    runtime.ui.mark_dirty()
  end

  local function handle_train_event(msg)
    if not runtime.train_registry then runtime.network.ack_for(msg); return end
    local payload = msg.payload or {}
    local train_id = payload.train_id or msg.src
    if payload.type == "train_status" then
      runtime.train_registry.update_status(train_id, payload)
    elseif payload.type == "request_departure" then
      if runtime.route_integration then runtime.route_integration.handle_train_request(payload, msg.src) end
      if runtime.logger then runtime.logger.info("train requested departure", payload) end
    elseif payload.type == "arrived" then
      runtime.train_registry.update_status(train_id, { state = "ARRIVED", destination = payload.station, route_id = payload.route_id })
    elseif payload.type == "schedule_applied" then
      runtime.train_registry.update_status(train_id, { state = payload.state or "ROUTE_ASSIGNED", route_id = payload.route_id, destination = payload.destination })
    elseif payload.type == "train_fault" then
      runtime.train_registry.update_status(train_id, { state = "FAULT", error = payload.error })
      if runtime.logger then runtime.logger.warn("train fault", payload) end
    end
    runtime.network.ack_for(msg)
    runtime.ui.mark_dirty()
  end

  local function handle_station_event(msg)
    if not runtime.station_registry then runtime.network.ack_for(msg); return end
    local payload = msg.payload or {}
    local station_id = payload.station_id or msg.src
    if payload.type == "station_status" then
      runtime.station_registry.update_status(station_id, payload)
    elseif payload.type == "platform_status" then
      runtime.station_registry.update_platform(station_id, payload.platform_id, payload)
    elseif payload.type == "train_arrived_station" then
      runtime.station_registry.update_platform(station_id, payload.platform_id, { state = "DWELLING", train_id = payload.train_id, route_id = payload.route_id, destination = payload.destination })
    elseif payload.type == "station_ready_departure" then
      if runtime.route_integration then runtime.route_integration.handle_station_ready(payload, msg.src) end
    elseif payload.type == "station_fault" then
      runtime.station_registry.update_status(station_id, { state = "FAULT", message = payload.error })
      if runtime.logger then runtime.logger.warn("station fault", payload) end
    end
    runtime.network.ack_for(msg)
    runtime.ui.mark_dirty()
  end

  local function handle_depot_event(msg)
    if not runtime.depot_registry then runtime.network.ack_for(msg); return end
    local payload = msg.payload or {}
    local depot_id = payload.depot_id or msg.src
    if payload.type == "depot_status" then
      runtime.depot_registry.update_status(depot_id, payload)
    elseif payload.type == "depot_track_status" then
      runtime.depot_registry.update_track(depot_id, payload.track_id, payload)
    elseif payload.type == "depot_train_ready" then
      runtime.depot_registry.update_track(depot_id, payload.track_id, { state = "READY", train_id = payload.train_id, route_id = payload.route_id, destination = payload.destination })
    elseif payload.type == "depot_request_dispatch" then
      if runtime.route_integration then runtime.route_integration.handle_depot_request(payload, msg.src) end
      if runtime.logger then runtime.logger.info("depot requested dispatch", payload) end
    elseif payload.type == "depot_train_arrived" then
      runtime.depot_registry.update_track(depot_id, payload.track_id, { state = "OCCUPIED", train_id = payload.train_id, route_id = payload.route_id })
    elseif payload.type == "depot_fault" then
      runtime.depot_registry.update_status(depot_id, { state = "FAULT", message = payload.error })
      if runtime.logger then runtime.logger.warn("depot fault", payload) end
    end
    runtime.network.ack_for(msg)
    runtime.ui.mark_dirty()
  end

  local function handle_panel_event(msg)
    if msg.payload and msg.payload.type == "panel_request_snapshot" then
      send_panel_snapshot(msg.src)
      runtime.network.ack_for(msg)
    end
  end

  handlers.event = function(msg)
    if msg.payload and msg.payload.type == "sensor" then
      handle_sensor_event(msg)
    elseif msg.payload and string.sub(tostring(msg.payload.type), 1, 6) == "train_" then
      handle_train_event(msg)
    elseif msg.payload and string.sub(tostring(msg.payload.type), 1, 8) == "station_" then
      handle_station_event(msg)
    elseif msg.payload and string.sub(tostring(msg.payload.type), 1, 6) == "depot_" then
      handle_depot_event(msg)
    elseif msg.payload and string.sub(tostring(msg.payload.type), 1, 6) == "panel_" then
      handle_panel_event(msg)
    elseif msg.payload and msg.payload.type == "platform_status" then
      handle_station_event(msg)
    elseif msg.payload and (msg.payload.type == "request_departure" or msg.payload.type == "arrived" or msg.payload.type == "schedule_applied") then
      handle_train_event(msg)
    end
    return true
  end

  handlers.cmd = function() runtime.ui.mark_dirty(); return true end
  handlers.ack = function() runtime.ui.mark_dirty(); return true end
  handlers.err = function(msg)
    if runtime.logger then runtime.logger.warn("node error", msg.payload or {}) end
    runtime.ui.mark_dirty()
    return true
  end

  local function check_timeouts()
    local now = os.clock()
    for node_id, node_state in pairs(runtime.registry.all()) do
      if now - node_state.last_seen > runtime.heartbeat_timeout_s then
        runtime.registry.mark_down(node_id)
        runtime.dispatcher.timeout_node(node_id)
        if runtime.train_registry and node_state.role == "train" then runtime.train_registry.mark_offline(node_id) end
        if runtime.station_registry and node_state.role == "station" then runtime.station_registry.mark_offline(node_id) end
        if runtime.depot_registry and node_state.role == "depot" then runtime.depot_registry.mark_offline(node_id) end
        runtime.ui.mark_dirty()
      end
    end
  end

  function runtime.start()
    runtime.timeout_timer = os.startTimer(1)
    runtime.ui_timer = os.startTimer(0.2)
    runtime.ui.draw()
  end

  function runtime.handle_event(event)
    if event[1] == "modem_message" then
      local msg = event[5]
      local status = runtime.network.receive(msg)
      if status == "ok" then message_handlers.dispatch(msg, handlers) end
    elseif event[1] == "monitor_touch" then
      runtime.ui.handle_touch(event[3], event[4])
    elseif event[1] == "timer" and event[2] == runtime.timeout_timer then
      check_timeouts()
      runtime.timeout_timer = os.startTimer(1)
    elseif event[1] == "timer" and event[2] == runtime.ui_timer then
      runtime.ui.draw()
      runtime.ui_timer = os.startTimer(0.2)
    end
    runtime.network.tick()
  end

  function runtime.run()
    runtime.start()
    while true do
      runtime.handle_event({ runtime.pull_event() })
    end
  end

  return runtime
end

return master_runtime
