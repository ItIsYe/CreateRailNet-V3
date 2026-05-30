--[[
Purpose: Integrate train/station/depot events with dispatcher route requests, service plans, dwell timers, and node commands.
Public API: new(context) -> integration with send_service_plan, handle_train_request, handle_train_arrival, handle_depot_request, handle_station_ready, process_due, process_queue, resolve_route.
]]

local create_train_schedule = require("src.adapter.create_train_schedule")

local route_integration = {}

local function send_cmd(network, dst, cmd, payload)
  local body = payload or {}
  body.cmd = cmd
  return network.send("cmd", dst, body)
end

local function reserve_or_queue(dispatcher, train_id, route_id, priority)
  if not dispatcher or not route_id then return false, "missing dispatcher or route_id" end
  return dispatcher.request_route(train_id, route_id, { priority = priority })
end

local function copy_stops(stops)
  local out = {}
  for i, stop in ipairs(stops or {}) do
    out[i] = { index = stop.index or i, from = stop.from, to = stop.to or stop.destination, route_id = stop.route_id, kind = stop.kind, dwell_seconds = stop.dwell_seconds or 0, state = stop.state }
  end
  return out
end

function route_integration.new(context)
  local self = {
    dispatcher = context.dispatcher,
    route_resolver = context.route_resolver,
    service_plan_registry = context.service_plan_registry,
    maintenance = context.maintenance,
    audit_log = context.audit_log,
    network = context.network,
    logger = context.logger,
    train_registry = context.train_registry,
    station_registry = context.station_registry,
    depot_registry = context.depot_registry,
    pending_departures = {}
  }

  local function audit(kind, data)
    if self.audit_log then self.audit_log.record(kind, data) end
  end

  local function is_locked()
    if not self.maintenance then return false end
    if self.maintenance.is_locked then return self.maintenance.is_locked() end
    return self.maintenance.enabled == true
  end

  local function resolve_train_node(train_id)
    local train = self.train_registry and self.train_registry.get(train_id)
    return (train and train.node_id) or train_id
  end

  local function reject_locked(train_id, route_id)
    audit("route_rejected", { train_id = train_id, route_id = route_id, reason = "maintenance" })
    send_cmd(self.network, resolve_train_node(train_id), "hold_position", { train_id = train_id, route_id = route_id, reason = "maintenance locked" })
    if self.train_registry then self.train_registry.update_status(train_id, { state = "WAITING_DEPARTURE", route_id = route_id }) end
    return false, "maintenance locked"
  end

  local function enrich_from_service_plan(train_id, payload)
    local request = {}
    for k, v in pairs(payload or {}) do request[k] = v end
    if request.route_id or request.to or request.destination then return request, nil end
    if not self.service_plan_registry then return request, nil end
    local stop = self.service_plan_registry.current_stop(train_id)
    if not stop then return request, nil end
    request.route_id = stop.route_id
    request.from = request.from or stop.from
    request.to = request.to or stop.to
    request.destination = request.destination or stop.to
    request.kind = request.kind or stop.kind
    request.priority = request.priority or stop.priority
    request.service_stop_index = stop.index
    return request, stop
  end

  local function schedule_departure(train_id, stop)
    if not stop then return false end
    local dwell = stop.dwell_seconds or 0
    self.pending_departures[train_id] = { train_id = train_id, due_at = os.clock() + dwell, route_id = stop.route_id, from = stop.from, to = stop.to, kind = stop.kind, priority = stop.priority, service_stop_index = stop.index }
    audit("departure_scheduled", { train_id = train_id, route_id = stop.route_id, dwell_seconds = dwell })
    send_cmd(self.network, resolve_train_node(train_id), "hold_position", { train_id = train_id, route_id = stop.route_id, destination = stop.to, service_stop_index = stop.index, reason = "dwell " .. tostring(dwell) .. "s" })
    return true
  end

  local function reserve_station_platform(station_id, payload, route_id, destination)
    if not self.station_registry or not station_id then return nil end
    if payload.platform_id then
      return self.station_registry.update_platform(station_id, payload.platform_id, { state = "RESERVED", train_id = payload.train_id, route_id = route_id, destination = destination })
    end
    local platform = self.station_registry.reserve_platform and self.station_registry.reserve_platform(station_id, { train_id = payload.train_id, route_id = route_id, destination = destination, kind = payload.kind })
    return platform
  end

  local function reserve_depot_track(depot_id, payload, route_id, destination)
    if not self.depot_registry or not depot_id then return nil end
    if payload.track_id then
      return self.depot_registry.update_track(depot_id, payload.track_id, { state = "RESERVED", train_id = payload.train_id, route_id = route_id, destination = destination })
    end
    local track = self.depot_registry.reserve_track and self.depot_registry.reserve_track(depot_id, { train_id = payload.train_id, route_id = route_id, destination = destination, kind = payload.kind })
    return track
  end

  function self.send_service_plan(train_id)
    if not self.service_plan_registry then return false, "service plan registry unavailable" end
    local plan = self.service_plan_registry.for_train(train_id)
    if not plan then return false, "no service plan assigned" end
    local stops = copy_stops(plan.stops)
    local schedule, schedule_err = create_train_schedule.build_schedule(stops)
    if not schedule then
      audit("service_plan_rejected", { train_id = train_id, service_plan = plan.id, error = schedule_err })
      send_cmd(self.network, resolve_train_node(train_id), "update_display", { train_id = train_id, message = "Schedule build failed: " .. tostring(schedule_err) })
      return false, schedule_err
    end
    send_cmd(self.network, resolve_train_node(train_id), "set_schedule", { train_id = train_id, service_plan = plan.id, service_stop_index = plan.current_index, route_id = stops[plan.current_index] and stops[plan.current_index].route_id, destination = stops[plan.current_index] and stops[plan.current_index].to, stops = stops, schedule = schedule })
    audit("service_plan_sent", { train_id = train_id, service_plan = plan.id })
    return true, plan
  end

  function self.resolve_route(payload)
    local request = payload or {}
    if request.route_id then return { id = request.route_id, from = request.from, to = request.to or request.destination }, "route_id" end
    if not self.route_resolver then return nil, "route resolver unavailable" end
    return self.route_resolver.resolve(request)
  end

  local function route_id_for(payload)
    local route, source = self.resolve_route(payload)
    if not route then return nil, source end
    return route.id, nil, route, source
  end

  function self.handle_train_request(payload, src)
    local train_id = payload.train_id or src
    local request, stop = enrich_from_service_plan(train_id, payload)
    local route_id, resolve_err, route = route_id_for(request)
    if is_locked() then return reject_locked(train_id, route_id) end
    audit("route_request", { train_id = train_id, route_id = route_id, src = src })
    local ok, status = reserve_or_queue(self.dispatcher, train_id, route_id, request.priority)
    if not route_id then ok, status = false, resolve_err end

    local destination = (route and route.to) or request.to or request.destination
    if self.service_plan_registry and stop then self.service_plan_registry.mark_current(train_id, ok and "AUTHORIZED" or "REQUESTED") end
    if self.train_registry then self.train_registry.update_status(train_id, { state = ok and "ROUTE_ASSIGNED" or "WAITING_FOR_ROUTE", route_id = route_id, destination = destination }) end

    if ok then
      audit("route_authorized", { train_id = train_id, route_id = route_id })
      send_cmd(self.network, resolve_train_node(train_id), "depart_authorized", { train_id = train_id, route_id = route_id, destination = destination, service_stop_index = request.service_stop_index })
    else
      audit("route_queued", { train_id = train_id, route_id = route_id, reason = status })
      send_cmd(self.network, resolve_train_node(train_id), "hold_position", { train_id = train_id, route_id = route_id, reason = status, service_stop_index = request.service_stop_index })
    end
    return ok, status, route
  end

  function self.handle_train_arrival(payload, src)
    local train_id = payload.train_id or src
    audit("train_arrival", { train_id = train_id, station = payload.station, route_id = payload.route_id })
    if self.train_registry then self.train_registry.update_status(train_id, { state = "ARRIVED", destination = payload.station or payload.destination, route_id = payload.route_id }) end
    if payload.station and payload.platform_id and self.station_registry then
      self.station_registry.update_platform(payload.station, payload.platform_id, { state = "DWELLING", train_id = train_id, route_id = payload.route_id, destination = payload.destination })
    end
    if self.service_plan_registry then
      self.service_plan_registry.mark_current(train_id, "ARRIVED")
      local next_stop = self.service_plan_registry.advance(train_id)
      if next_stop then
        send_cmd(self.network, resolve_train_node(train_id), "set_destination", { train_id = train_id, destination = next_stop.to, route_id = next_stop.route_id, service_stop_index = next_stop.index })
        schedule_departure(train_id, next_stop)
      else
        self.pending_departures[train_id] = nil
        send_cmd(self.network, resolve_train_node(train_id), "update_display", { train_id = train_id, message = "Service complete" })
      end
    end
    return true
  end

  function self.handle_depot_request(payload, src)
    local train_id = payload.train_id
    local request, stop = enrich_from_service_plan(train_id, payload)
    local route_id, resolve_err, route = route_id_for(request)
    if is_locked() then return reject_locked(train_id, route_id) end
    audit("depot_dispatch_request", { train_id = train_id, route_id = route_id, src = src })
    local ok, status = reserve_or_queue(self.dispatcher, train_id, route_id, request.priority)
    if not route_id then ok, status = false, resolve_err end

    local destination = (route and route.to) or request.destination or request.to
    if self.service_plan_registry and stop then self.service_plan_registry.mark_current(train_id, ok and "AUTHORIZED" or "REQUESTED") end
    if self.depot_registry then
      if not ok then self.depot_registry.enqueue(payload.depot_id or src, request) end
      local track = reserve_depot_track(payload.depot_id or src, payload, route_id, destination)
      if track then track.state = ok and "DEPARTING" or "READY" end
    end

    if train_id then
      if ok then send_cmd(self.network, resolve_train_node(train_id), "depart_authorized", { train_id = train_id, route_id = route_id, destination = destination })
      else send_cmd(self.network, resolve_train_node(train_id), "hold_position", { train_id = train_id, route_id = route_id, reason = status }) end
    end
    return ok, status, route
  end

  function self.handle_station_ready(payload, src)
    local train_id = payload.train_id
    if not train_id then return false, "station ready missing train_id" end
    local request, stop = enrich_from_service_plan(train_id, payload)
    local route_id, resolve_err, route = route_id_for(request)
    if is_locked() then return reject_locked(train_id, route_id) end
    audit("station_departure_request", { train_id = train_id, route_id = route_id, src = src })
    local ok, status = reserve_or_queue(self.dispatcher, train_id, route_id, request.priority)
    if not route_id then ok, status = false, resolve_err end

    local destination = (route and route.to) or request.destination or request.to
    if self.service_plan_registry and stop then self.service_plan_registry.mark_current(train_id, ok and "AUTHORIZED" or "REQUESTED") end
    if self.station_registry then
      local platform = reserve_station_platform(payload.station_id or src, payload, route_id, destination)
      if platform then platform.state = ok and "DEPARTING" or "READY_TO_DEPART" end
    end

    if ok then send_cmd(self.network, resolve_train_node(train_id), "depart_authorized", { train_id = train_id, route_id = route_id, destination = destination })
    else send_cmd(self.network, resolve_train_node(train_id), "hold_position", { train_id = train_id, route_id = route_id, reason = status }) end
    return ok, status, route
  end

  function self.process_queue()
    if is_locked() then return {} end
    local processed = self.dispatcher and self.dispatcher.process_queue(3) or {}
    for _, item in ipairs(processed) do
      if item.ok then
        local route = self.dispatcher.routes and self.dispatcher.routes[item.route_id]
        audit("queue_authorized", { train_id = item.train_id, route_id = item.route_id })
        send_cmd(self.network, resolve_train_node(item.train_id), "depart_authorized", { train_id = item.train_id, route_id = item.route_id, destination = route and route.to })
        if self.train_registry then self.train_registry.update_status(item.train_id, { state = "ROUTE_ASSIGNED", route_id = item.route_id, destination = route and route.to }) end
      end
    end
    return processed
  end

  function self.process_due(now)
    if is_locked() then return {} end
    local clock = now or os.clock()
    local fired = {}
    for train_id, pending in pairs(self.pending_departures) do
      if clock >= pending.due_at then
        self.pending_departures[train_id] = nil
        local ok, status = self.handle_train_request({ train_id = train_id, route_id = pending.route_id, from = pending.from, to = pending.to, kind = pending.kind, priority = pending.priority, service_stop_index = pending.service_stop_index }, train_id)
        table.insert(fired, { train_id = train_id, ok = ok, status = status })
      end
    end
    return fired
  end

  function self.get_pending_departures()
    local out = {}
    for train_id, pending in pairs(self.pending_departures) do out[train_id] = pending end
    return out
  end

  return self
end

return route_integration
