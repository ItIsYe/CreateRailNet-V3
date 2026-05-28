--[[
Purpose: Integrate train/station/depot events with dispatcher route requests and node commands.
Public API: new(context) -> integration with handle_train_request, handle_depot_request, handle_station_ready.
]]

local route_integration = {}

local function send_cmd(network, dst, cmd, payload)
  local body = payload or {}
  body.cmd = cmd
  return network.send("cmd", dst, body)
end

local function reserve_or_queue(dispatcher, train_id, route_id, priority)
  if not dispatcher or not route_id then
    return false, "missing dispatcher or route_id"
  end
  return dispatcher.request_route(train_id, route_id, { priority = priority })
end

function route_integration.new(context)
  local self = {
    dispatcher = context.dispatcher,
    network = context.network,
    logger = context.logger,
    train_registry = context.train_registry,
    station_registry = context.station_registry,
    depot_registry = context.depot_registry
  }

  local function resolve_train_node(train_id)
    local train = self.train_registry and self.train_registry.get(train_id)
    return (train and train.node_id) or train_id
  end

  function self.handle_train_request(payload, src)
    local train_id = payload.train_id or src
    local route_id = payload.route_id
    local ok, status = reserve_or_queue(self.dispatcher, train_id, route_id, payload.priority)

    if self.train_registry then
      self.train_registry.update_status(train_id, {
        state = ok and "ROUTE_ASSIGNED" or "WAITING_FOR_ROUTE",
        route_id = route_id,
        destination = payload.to or payload.destination
      })
    end

    if ok then
      send_cmd(self.network, resolve_train_node(train_id), "depart_authorized", {
        train_id = train_id,
        route_id = route_id,
        destination = payload.to or payload.destination
      })
    else
      send_cmd(self.network, resolve_train_node(train_id), "hold_position", {
        train_id = train_id,
        route_id = route_id,
        reason = status
      })
    end

    return ok, status
  end

  function self.handle_depot_request(payload, src)
    local train_id = payload.train_id
    local route_id = payload.route_id
    local ok, status = reserve_or_queue(self.dispatcher, train_id, route_id, payload.priority)

    if self.depot_registry then
      self.depot_registry.enqueue(payload.depot_id or src, payload)
      if payload.track_id then
        self.depot_registry.update_track(payload.depot_id or src, payload.track_id, {
          state = ok and "DEPARTING" or "READY",
          train_id = train_id,
          route_id = route_id,
          destination = payload.destination
        })
      end
    end

    if train_id then
      if ok then
        send_cmd(self.network, resolve_train_node(train_id), "depart_authorized", {
          train_id = train_id,
          route_id = route_id,
          destination = payload.destination
        })
      else
        send_cmd(self.network, resolve_train_node(train_id), "hold_position", {
          train_id = train_id,
          route_id = route_id,
          reason = status
        })
      end
    end

    return ok, status
  end

  function self.handle_station_ready(payload, src)
    local train_id = payload.train_id
    local route_id = payload.route_id
    if not train_id or not route_id then
      return false, "station ready missing train_id or route_id"
    end

    local ok, status = reserve_or_queue(self.dispatcher, train_id, route_id, payload.priority)

    if self.station_registry then
      self.station_registry.update_platform(payload.station_id or src, payload.platform_id, {
        state = ok and "DEPARTING" or "READY_TO_DEPART",
        train_id = train_id,
        route_id = route_id,
        destination = payload.destination
      })
    end

    if ok then
      send_cmd(self.network, resolve_train_node(train_id), "depart_authorized", {
        train_id = train_id,
        route_id = route_id,
        destination = payload.destination
      })
    else
      send_cmd(self.network, resolve_train_node(train_id), "hold_position", {
        train_id = train_id,
        route_id = route_id,
        reason = status
      })
    end

    return ok, status
  end

  function self.process_queue()
    return self.dispatcher and self.dispatcher.process_queue(3) or {}
  end

  return self
end

return route_integration
