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

  handlers.register = function(msg)
    local role = msg.payload and msg.payload.role
    runtime.registry.register(msg.src, role, nil)
    if role == "train" and runtime.train_registry then
      runtime.train_registry.register(msg.payload.train_id or msg.src, msg.src, msg.payload or {})
    end
    runtime.network.ack_for(msg)
    runtime.ui.mark_dirty()
    return true
  end

  handlers.heartbeat = function(msg)
    runtime.registry.heartbeat(msg.src)
    if msg.payload and msg.payload.role == "train" and runtime.train_registry then
      runtime.train_registry.register(msg.payload.train_id or msg.src, msg.src, msg.payload)
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
    runtime.ui.mark_dirty()
  end

  local function handle_train_event(msg)
    if not runtime.train_registry then
      runtime.network.ack_for(msg)
      return
    end

    local payload = msg.payload or {}
    local train_id = payload.train_id or msg.src

    if payload.type == "train_status" then
      runtime.train_registry.update_status(train_id, payload)
    elseif payload.type == "request_departure" then
      runtime.train_registry.update_status(train_id, {
        state = "WAITING_FOR_ROUTE",
        destination = payload.to or payload.destination,
        from = payload.from,
        route_id = payload.route_id
      })
      if runtime.logger then
        runtime.logger.info("train requested departure", payload)
      end
    elseif payload.type == "arrived" then
      runtime.train_registry.update_status(train_id, {
        state = "ARRIVED",
        destination = payload.station,
        route_id = payload.route_id
      })
    elseif payload.type == "schedule_applied" then
      runtime.train_registry.update_status(train_id, {
        state = payload.state or "ROUTE_ASSIGNED",
        route_id = payload.route_id,
        destination = payload.destination
      })
    elseif payload.type == "train_fault" then
      runtime.train_registry.update_status(train_id, {
        state = "FAULT",
        error = payload.error
      })
      if runtime.logger then
        runtime.logger.warn("train fault", payload)
      end
    end

    runtime.network.ack_for(msg)
    runtime.ui.mark_dirty()
  end

  handlers.event = function(msg)
    if msg.payload and msg.payload.type == "sensor" then
      handle_sensor_event(msg)
    elseif msg.payload and string.sub(tostring(msg.payload.type), 1, 6) == "train_" then
      handle_train_event(msg)
    elseif msg.payload and (msg.payload.type == "request_departure" or msg.payload.type == "arrived" or msg.payload.type == "schedule_applied") then
      handle_train_event(msg)
    end
    return true
  end

  handlers.cmd = function()
    runtime.ui.mark_dirty()
    return true
  end

  handlers.ack = function()
    runtime.ui.mark_dirty()
    return true
  end

  handlers.err = function(msg)
    if runtime.logger then
      runtime.logger.warn("node error", msg.payload or {})
    end
    runtime.ui.mark_dirty()
    return true
  end

  local function check_timeouts()
    local now = os.clock()
    for node_id, node_state in pairs(runtime.registry.all()) do
      if now - node_state.last_seen > runtime.heartbeat_timeout_s then
        runtime.registry.mark_down(node_id)
        runtime.dispatcher.timeout_node(node_id)
        if runtime.train_registry and node_state.role == "train" then
          runtime.train_registry.mark_offline(node_id)
        end
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
      if status == "ok" then
        message_handlers.dispatch(msg, handlers)
      end
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
