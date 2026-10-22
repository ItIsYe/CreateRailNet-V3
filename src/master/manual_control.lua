--[[
Purpose: Manual control helper for panel/operator commands with maintenance guard.
Public API: new(context) -> helper with handle(command, src).
]]

local errors = require("src.shared.error_codes")

local manual_control = {}

-- updates run in maintenance: their own checks (src/master/update_control.lua) decide, the maintenance lock does not block them
local SAFE_ACTIONS = { enter_maintenance = true, exit_maintenance = true, hold_train = true, emergency_stop = true, ota_push = true, update_release = true, update_unlock = true, replace_begin = true, replace_adopt = true, replace_key = true, replace_bindings = true, replace_finish = true, timetable_draft = true, timetable_publish = true, trip_cancel = true }

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
    audit_log = context.audit_log
  }
  -- ota, cargo and alerts are looked up when an action runs: the app builds this helper before those services exist, and
  -- reading them at construction left "ota manager unavailable" and "cargo system unavailable" on every call
  setmetatable(self, { __index = function(_, key)
    if key == "ota" or key == "config" or key == "update_control" or key == "replacement" or key == "signal_report" or key == "cargo" or key == "alerts" or key == "trace" then return context[key] end
    return nil
  end })

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
    elseif cmd.action == "trace_dump" then
      if not self.trace then return false, "trace recorder unavailable" end
      local path, err = self.trace.dump_slot("traces/trace_", 5)
      audit("trace_dumped", { src = src, path = path, error = err })
      if not path then return false, err end
      return true, path
    elseif cmd.action == "ack_alert" then
      if not self.alerts then return false, "alerts unavailable" end
      if cmd.all then
        local count = self.alerts.ack_all(src)
        audit("alert_acknowledged", { src = src, all = true, count = count })
        return true
      end
      local ok = self.alerts.ack(cmd.key, src)
      audit("alert_acknowledged", { src = src, key = cmd.key, ok = ok })
      if not ok then return false, "no such alert: " .. tostring(cmd.key) end
      return true
    elseif cmd.action == "clear_fault" then
      if not self.dispatcher or not self.dispatcher.clear_fault then return false, "fault repair unavailable" end
      local ok, err = self.dispatcher.clear_fault(cmd.block_id)
      audit("fault_cleared", { src = src, block_id = cmd.block_id, ok = ok, error = err })
      return ok, err
    elseif cmd.action == "release_train" then
      if not self.dispatcher or not self.dispatcher.release_route then return false, "release unavailable" end
      local ok, err = self.dispatcher.release_route(cmd.train_id, cmd.route_id)
      audit("train_released", { src = src, train_id = cmd.train_id, ok = ok, error = err })
      return ok, err
    elseif cmd.action == "set_signal" then
      if not self.dispatcher or not self.dispatcher.set_signal then return false, "signal control unavailable" end
      return self.dispatcher.set_signal(cmd.signal_id, cmd.aspect or "RED")
    elseif cmd.action == "set_switch" then
      if not self.dispatcher or not self.dispatcher.set_switch then return false, "switch control unavailable" end
      return self.dispatcher.set_switch(cmd.switch_id, cmd.position)
    elseif cmd.action == "cargo_order" then
      -- Create a freight order
      if not self.cargo then return false, "cargo system unavailable" end
      local order_id = self.cargo.create_order({
        cargo_type    = cmd.cargo_type,
        amount        = cmd.amount or 1,
        from_industry = cmd.from_industry or cmd.from,
        to_industry   = cmd.to_industry or cmd.to,
        from_track    = cmd.from_track,
        to_track      = cmd.to_track,
        priority      = cmd.priority,
        train_class   = cmd.train_class or "freight",
      })
      audit("cargo_order_created", { order_id=order_id, src=src, cargo_type=cmd.cargo_type })
      return true, "order created: " .. tostring(order_id)
    elseif cmd.action == "cargo_assign" then
      if not self.cargo then return false, "cargo system unavailable" end
      local ok, err = self.cargo.assign_train(cmd.order_id, cmd.train_id)
      audit("cargo_assign", { order_id=cmd.order_id, train_id=cmd.train_id, ok=ok })
      return ok, err
    elseif cmd.action == "cargo_loaded" then
      if not self.cargo then return false, "cargo system unavailable" end
      self.cargo.start_loading(cmd.order_id)
      local ok, err = self.cargo.finish_loading(cmd.order_id)
      audit("cargo_loaded", { order_id=cmd.order_id, ok=ok })
      return ok, err
    elseif cmd.action == "cargo_delivered" then
      if not self.cargo then return false, "cargo system unavailable" end
      self.cargo.start_unloading(cmd.order_id)
      local ok, err = self.cargo.finish_unloading(cmd.order_id)
      audit("cargo_delivered", { order_id=cmd.order_id, ok=ok })
      return ok, err
    elseif cmd.action == "cargo_cancel" then
      if not self.cargo then return false, "cargo system unavailable" end
      local ok, err = self.cargo.cancel_order(cmd.order_id)
      audit("cargo_cancel", { order_id=cmd.order_id })
      return ok, err
    elseif cmd.action == "update_release" then
      if not self.update_control then return false, "update control unavailable" end
      local ok_release, why = self.update_control.release_node(cmd.node_id, cmd.operator, cmd.evidence)
      audit("update_release", { node_id = cmd.node_id, ok = ok_release == true, by = cmd.operator })
      return ok_release, why
    elseif cmd.action == "replace_begin" or cmd.action == "replace_adopt" or cmd.action == "replace_key" or cmd.action == "replace_bindings" or cmd.action == "replace_finish" then
      -- the replacement of a computer (src/master/replacement.lua): the key goes to a disk and never into a message, the signals are bound again on the new computer and read back from its heartbeat
      local setup = self.replacement
      if not setup then return false, "replacement unavailable: this master has no master key or list of keys" end
      local wizard, operator, node_id = setup.wizard, cmd.operator or src, cmd.node_id
      local ok, result
      if cmd.action == "replace_begin" then ok, result = wizard.begin(node_id, operator)
      elseif cmd.action == "replace_adopt" then
        local record, fingerprint = wizard.adopt(node_id, operator, cmd.new_id)
        if not record then ok, result = nil, fingerprint
        else
          local handed, where = setup.handover(record)
          if not handed then
            wizard.confirm_key(node_id, operator, false)
            ok, result = nil, "Schluessel nicht ausgegeben und zurueckgenommen: " .. tostring(where)
          else
            ok, result = true, "Schluessel auf der Diskette (" .. where .. "), Pruefsumme " .. fingerprint
          end
        end
      elseif cmd.action == "replace_key" then ok, result = wizard.confirm_key(node_id, operator, cmd.matches)
      elseif cmd.action == "replace_bindings" then
        local state = wizard.state_of(node_id)
        local report = state and self.signal_report and self.signal_report(state.new_id)
        local confirmed = {}
        for signal_id, status in pairs(report and report.signals or {}) do if status == "OK" then confirmed[#confirmed + 1] = signal_id end end
        ok, result = wizard.bindings_confirmed(node_id, confirmed, operator)
      else
        ok, result = wizard.finish(node_id, operator, { ok = cmd.test_ok == true, source = "Betreiber " .. tostring(operator) .. " hat den Funktionstest am Signal gesehen" })
      end
      audit(cmd.action, { node_id = node_id, ok = ok == true, by = operator, reason = (ok == nil) and result or nil })
      if ok == nil then return false, result end
      return true, result
    elseif cmd.action == "timetable_draft" or cmd.action == "timetable_publish" or cmd.action == "trip_cancel" then
      -- what the operator changes in the fleet is forwarded to the active node of the pair (src/nodes/fleet_node.lua checks and answers); the answer comes back as fleet_admin_result
      local pair
      for _, candidate in ipairs((self.config and self.config.fleet and self.config.fleet.pairs) or {}) do
        if candidate.id == cmd.pair_id then pair = candidate end
      end
      if not pair or not pair.nodes or not pair.nodes[1] then return false, "unknown fleet pair " .. tostring(cmd.pair_id) end
      self.admin_sequence = (self.admin_sequence or 0) + 1
      -- the panel may name its request (to find the answer again); a name that is not plain is ignored
      local request_id = "REQ-" .. tostring(self.admin_sequence) .. "-" .. tostring(cmd.pair_id)
      if type(cmd.request_id) == "string" and #cmd.request_id <= 48 and cmd.request_id:match("^[%w%-_]+$") then request_id = cmd.request_id end
      local sent = send_cmd(self.network, pair.nodes[1], "fleet_admin", {
        request_id = request_id, op = cmd.action, line = cmd.line, line_id = cmd.line_id, version = cmd.version, base_version = cmd.base_version, trip_id = cmd.trip_id, who = cmd.operator or src
      })
      audit(cmd.action, { pair_id = cmd.pair_id, request_id = request_id, by = cmd.operator or src, line_id = cmd.line_id or (cmd.line and cmd.line.id), trip_id = cmd.trip_id })
      if not sent then return false, "the fleet node cannot be reached" end
      return true, request_id
    elseif cmd.action == "update_unlock" then
      if not self.update_control then return false, "update control unavailable" end
      local ok_unlock, why = self.update_control.unlock(cmd.node_id, cmd.operator, cmd.proof)
      audit("update_unlock", { node_id = cmd.node_id, ok = ok_unlock == true, by = cmd.operator })
      return ok_unlock, why
    elseif cmd.action == "ota_push" then
      if not self.ota then return false, "ota manager unavailable" end
      local targets = cmd.node_id and { cmd.node_id } or nil
      -- with the update control every target needs the operator confirmation and, if critical, its release; a refused target is not touched
      if self.update_control then
        if not targets then return false, "update control: a target node is needed (no blind broadcast of production updates)" end
        for _, node_id in ipairs(targets) do
          local rec = self.update_control.state_of(node_id)
          if not rec or rec.state ~= "PREPARED" then
            local ok_prepare, why = self.update_control.prepare(node_id, { release = cmd.version or "runtime", rollback_to = "previous" })
            if not ok_prepare then return false, "update not prepared for " .. node_id .. ": " .. tostring(why) end
          end
          local ok_check, reasons = self.update_control.check(node_id, { confirm = cmd.confirm == true })
          if not ok_check then
            audit("ota_refused", { node_id = node_id, reasons = reasons, by = cmd.operator })
            return false, "update refused for " .. node_id .. ": " .. table.concat(reasons, "; ")
          end
        end
        for _, node_id in ipairs(targets) do self.update_control.begin(node_id, cmd.operator) end
      end
      local results, start_err = self.ota.push_runtime({ nodes = targets, version = cmd.version })
      if start_err then return false, "OTA not started: " .. tostring(start_err) end
      local ok_count, fail_count = 0, 0
      for _, r in pairs(results or {}) do
        if r.ok then ok_count = ok_count + 1 else fail_count = fail_count + 1 end
      end
      if self.logger then self.logger.info("OTA push triggered", { ok = ok_count, failed = fail_count, targets = targets }) end
      return true, "OTA started for " .. ok_count .. " nodes"
    end
    return false, "unknown manual action: " .. tostring(cmd.action)
  end

  return self
end

return manual_control
