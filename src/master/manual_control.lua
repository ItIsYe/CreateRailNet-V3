--[[
Purpose: Manual control helper for panel/operator commands with maintenance guard.
Public API: new(context) -> helper with handle(command, src).
]]

local errors = require("src.shared.error_codes")

local manual_control = {}

local SAFE_ACTIONS = { enter_maintenance = true, exit_maintenance = true, hold_train = true, emergency_stop = true }

local function send_cmd(network, dst, cmd, payload)
  local body = payload or {}
  body.cmd = cmd
  -- Manual control commands are critical (emergency stop, authorize, hold)
  if network.send_reliable then
    return network.send_reliable("cmd", dst, body)
  end
  return network.send("cmd", dst, body)
end

function manual_control.new(context)
  local self = {
    dispatcher = context.dispatcher,
    network = context.network,
    logger = context.logger,
    train_registry = context.train_registry,
    route_integration = context.route_integration,
    maintenance = context.maintenance,
    audit_log = context.audit_log,
    ota = context.ota
  }

  local function audit(kind, data)
    if self.audit_log then self.audit_log.record(kind, data) end
  end

  local function train_node_id(train_id)
    local train = self.train_registry and self.train_registry.get(train_id)
    return (train and train.node_id) or train_id
  end

  local function maintenance_blocked(action)
    if not self.maintenance then return false end
    if self.maintenance.is_locked then return self.maintenance.is_locked() and not SAFE_ACTIONS[action] end
    return self.maintenance.enabled and not SAFE_ACTIONS[action]
  end

  local function enter_maintenance(reason, actor)
    if self.maintenance and self.maintenance.enable then return self.maintenance.enable(reason, actor) end
    if self.maintenance then self.maintenance.enabled = true; self.maintenance.reason = reason end
    return true
  end

  local function exit_maintenance(actor)
    if self.maintenance and self.maintenance.disable then return self.maintenance.disable(actor) end
    if self.maintenance then self.maintenance.enabled = false; self.maintenance.reason = nil end
    return true
  end

  function self.handle(command, src)
    local cmd = command or {}
    audit("manual_control", { src = src, action = cmd.action, train_id = cmd.train_id, route_id = cmd.route_id })

    if cmd.action == "enter_maintenance" then
      enter_maintenance(cmd.reason or "manual maintenance", src)
      audit("maintenance_enter", { src = src, reason = cmd.reason })
      return true
    elseif cmd.action == "exit_maintenance" then
      exit_maintenance(src)
      audit("maintenance_exit", { src = src })
      return true
    end

    if maintenance_blocked(cmd.action) then
      local err = errors.make(errors.codes.MAINTENANCE_LOCKED, "manual action blocked by maintenance", { action = cmd.action })
      audit("manual_rejected", err)
      return false, err.message
    end

    if cmd.action == "request_route" then
      if self.route_integration then
        return self.route_integration.handle_train_request({ train_id = cmd.train_id, route_id = cmd.route_id, from = cmd.from, to = cmd.to, destination = cmd.destination, priority = cmd.priority, kind = cmd.kind }, src or cmd.train_id)
      end
      return false, "route integration unavailable"
    elseif cmd.action == "hold_train" then
      send_cmd(self.network, train_node_id(cmd.train_id), "hold_position", { train_id = cmd.train_id, reason = cmd.reason or "manual hold" })
      if self.train_registry then self.train_registry.update_status(cmd.train_id, { state = "WAITING_DEPARTURE" }) end
      return true
    elseif cmd.action == "authorize_train" then
      -- Reserve the route in the dispatcher before authorizing the train.
      -- Without this, sensor events for unreserved blocks would cause FAULT.
      if self.dispatcher and cmd.route_id then
        local ok, err = self.dispatcher.reserve_route(cmd.train_id, cmd.route_id)
        if not ok then
          audit("manual_authorize_failed", { src = src, train_id = cmd.train_id, route_id = cmd.route_id, error = err })
          if self.logger then self.logger.warn("manual authorize_train: reserve_route failed", { error = err }) end
          return false, "reserve_route failed: " .. tostring(err)
        end
      end
      send_cmd(self.network, train_node_id(cmd.train_id), "depart_authorized", { train_id = cmd.train_id, route_id = cmd.route_id, destination = cmd.destination })
      if self.train_registry then self.train_registry.update_status(cmd.train_id, { state = "ROUTE_ASSIGNED", route_id = cmd.route_id, destination = cmd.destination }) end
      return true
    elseif cmd.action == "emergency_stop" then
      send_cmd(self.network, train_node_id(cmd.train_id), "emergency_stop", { train_id = cmd.train_id, reason = cmd.reason or "manual emergency stop" })
      if self.train_registry then self.train_registry.update_status(cmd.train_id, { state = "FAULT", error = cmd.reason or "manual emergency stop" }) end
      return true
    elseif cmd.action == "set_signal" then
      if not self.dispatcher or not self.dispatcher.set_signal then return false, "signal control unavailable" end
      return self.dispatcher.set_signal(cmd.signal_id, cmd.aspect or "RED")
    elseif cmd.action == "set_switch" then
      if not self.dispatcher or not self.dispatcher.set_switch then return false, "switch control unavailable" end
      return self.dispatcher.set_switch(cmd.switch_id, cmd.position)
    elseif cmd.action == "ota_push" then
      if not self.ota then return false, "ota manager unavailable" end
      local targets = cmd.node_id and { cmd.node_id } or nil
      local results = self.ota.push_runtime({ nodes = targets, version = cmd.version })
      local ok_count, fail_count = 0, 0
      for _, r in pairs(results or {}) do
        if r.ok then ok_count = ok_count + 1 else fail_count = fail_count + 1 end
      end
      if self.logger then self.logger.info("OTA push triggered", { ok = ok_count, targets = targets }) end
      return true, "OTA push sent to " .. ok_count .. " nodes"
    end
    return false, "unknown manual action: " .. tostring(cmd.action)
  end

  return self
end

return manual_control
