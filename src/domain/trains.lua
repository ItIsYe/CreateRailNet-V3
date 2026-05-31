--[[
Purpose: Domain registry for onboard train nodes and train state.
Public API: new(config) -> registry with register, update_status, assign_route, list, get.
]]

local trains = {}

local STATES = {
  BOOTING = "BOOTING",
  REGISTERING = "REGISTERING",
  IDLE = "IDLE",
  WAITING_FOR_ROUTE = "WAITING_FOR_ROUTE",
  ROUTE_ASSIGNED = "ROUTE_ASSIGNED",
  WAITING_DEPARTURE = "WAITING_DEPARTURE",
  DEPART_AUTHORIZED = "DEPART_AUTHORIZED",
  RUNNING = "RUNNING",
  ARRIVED = "ARRIVED",
  SCHEDULE_FAILED = "SCHEDULE_FAILED",
  FAULT = "FAULT",
  OFFLINE = "OFFLINE"
}

local function copy(src)
  local dst = {}
  for k, v in pairs(src or {}) do dst[k] = v end
  return dst
end

function trains.new(config)
  local by_id = {}
  local self = {}

  for _, node in ipairs((config and config.nodes) or {}) do
    if node.role == "train" then
      local train_id = node.train_id or node.id
      by_id[train_id] = {
        id = train_id,
        node_id = node.id,
        display_name = node.display_name or train_id,
        home_depot = node.home_depot,
        default_route = node.default_route,
        destination = node.default_destination,
        create_destination = node.default_create_destination or node.create_destination,
        route_id = nil,
        state = STATES.OFFLINE,
        last_seen = 0,
        status = {}
      }
    end
  end

  function self.register(train_id, node_id, info)
    local id = train_id or node_id
    if not by_id[id] then
      by_id[id] = { id = id, node_id = node_id, display_name = (info and info.display_name) or id, state = STATES.REGISTERING, last_seen = os.clock(), status = {} }
    end
    local train = by_id[id]
    train.node_id = node_id or train.node_id
    train.display_name = (info and info.display_name) or train.display_name
    train.home_depot = (info and info.home_depot) or train.home_depot
    train.default_route = (info and info.default_route) or train.default_route
    train.destination = (info and info.destination) or train.destination
    train.create_destination = (info and info.create_destination) or train.create_destination
    train.state = (info and info.state) or STATES.IDLE
    train.last_seen = os.clock()
    return train
  end

  function self.update_status(train_id, status)
    local train = self.register(train_id, train_id, status)
    train.status = copy(status)
    train.state = status.state or train.state
    train.route_id = status.route_id or train.route_id
    train.destination = status.destination or train.destination
    train.create_destination = status.create_destination or train.create_destination
    train.current_block = status.current_block or train.current_block
    train.schedule_state = status.schedule_state or train.schedule_state
    train.schedule_station = status.schedule_station or train.schedule_station
    train.service_plan = status.service_plan or train.service_plan
    train.service_stop_index = status.service_stop_index or train.service_stop_index
    train.message = status.message or train.message
    train.last_seen = os.clock()
    return train
  end

  function self.assign_route(train_id, route_id, destination, create_destination)
    local train = self.register(train_id, train_id, {})
    train.route_id = route_id
    train.destination = destination or train.destination
    train.create_destination = create_destination or train.create_destination
    train.state = STATES.ROUTE_ASSIGNED
    train.last_seen = os.clock()
    return train
  end

  function self.mark_offline(train_id)
    if by_id[train_id] then by_id[train_id].state = STATES.OFFLINE end
  end

  function self.get(train_id) return by_id[train_id] end

  function self.list()
    local out = {}
    for id, train in pairs(by_id) do out[id] = copy(train) end
    return out
  end

  return self
end

trains.STATES = STATES

return trains
