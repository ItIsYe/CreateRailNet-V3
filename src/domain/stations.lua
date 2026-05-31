--[[
Purpose: Domain registry for stations and their platforms/tracks.
Public API: new(config) -> registry with register, update_platform, update_status, resolve_create_destination, find_available_platform, reserve_platform, release_platform, list, get.
]]

local stations = {}

local STATION_TYPES = { passenger = true, freight = true, mixed = true }

local PLATFORM_STATES = {
  EMPTY = "EMPTY",
  RESERVED = "RESERVED",
  ARRIVING = "ARRIVING",
  OCCUPIED = "OCCUPIED",
  DWELLING = "DWELLING",
  READY_TO_DEPART = "READY_TO_DEPART",
  DEPARTING = "DEPARTING",
  FAULT = "FAULT"
}

local FREE_STATES = { EMPTY = true }

local function shallow_copy(src)
  local dst = {}
  for k, v in pairs(src or {}) do dst[k] = v end
  return dst
end

local function kind_matches(platform_kind, requested_kind)
  local pk = platform_kind or "mixed"
  local rk = requested_kind or "mixed"
  return pk == "mixed" or rk == "mixed" or pk == rk
end

local function normalize_platform(platform)
  local id = platform.id or platform.track_id or platform.name
  return {
    id = id,
    track_id = platform.track_id or id,
    kind = platform.kind or platform.type or "mixed",
    block_id = platform.block_id,
    sensor_id = platform.sensor_id,
    state = platform.state or PLATFORM_STATES.EMPTY,
    train_id = platform.train_id,
    route_id = platform.route_id,
    destination = platform.destination,
    priority = platform.priority or 0,
    capacity = platform.capacity or 1
  }
end

local function create_name_for(node, station_id)
  return node.create_station_name or node.create_destination or node.schedule_destination or node.create_name or station_id
end

local function platform_sort(a, b)
  if (a.priority or 0) ~= (b.priority or 0) then return (a.priority or 0) > (b.priority or 0) end
  return tostring(a.id) < tostring(b.id)
end

function stations.new(config)
  local by_id = {}
  local self = {}

  for _, node in ipairs((config and config.nodes) or {}) do
    if node.role == "station" then
      local station_id = node.station_id or node.id
      local station = {
        id = station_id,
        node_id = node.id,
        display_name = node.display_name or station_id,
        create_station_name = create_name_for(node, station_id),
        create_destination = node.create_destination,
        schedule_destination = node.schedule_destination,
        station_type = STATION_TYPES[node.station_type or node.type] and (node.station_type or node.type) or "mixed",
        state = node.state or "ONLINE",
        last_seen = 0,
        platforms = {}
      }
      for _, platform in ipairs(node.platforms or node.tracks or {}) do
        local normalized = normalize_platform(platform)
        if normalized.id then station.platforms[normalized.id] = normalized end
      end
      by_id[station_id] = station
    end
  end

  function self.register(station_id, node_id, info)
    local id = station_id or node_id
    if not by_id[id] then
      by_id[id] = { id = id, node_id = node_id, display_name = (info and info.display_name) or id, create_station_name = (info and (info.create_station_name or info.create_destination or info.schedule_destination)) or id, station_type = (info and info.station_type) or "mixed", state = "ONLINE", last_seen = os.clock(), platforms = {} }
    end
    local station = by_id[id]
    station.node_id = node_id or station.node_id
    station.display_name = (info and info.display_name) or station.display_name
    station.create_station_name = (info and (info.create_station_name or info.create_destination or info.schedule_destination)) or station.create_station_name
    station.create_destination = (info and info.create_destination) or station.create_destination
    station.schedule_destination = (info and info.schedule_destination) or station.schedule_destination
    station.station_type = (info and info.station_type) or station.station_type
    station.state = (info and info.state) or station.state or "ONLINE"
    station.last_seen = os.clock()
    return station
  end

  function self.resolve_create_destination(station_id, fallback)
    local station = by_id[station_id]
    if not station then return fallback or station_id end
    return station.create_station_name or station.create_destination or station.schedule_destination or fallback or station_id
  end

  function self.update_status(station_id, status)
    local station = self.register(station_id, station_id, status)
    station.state = status.state or station.state
    station.message = status.message
    station.last_seen = os.clock()
    return station
  end

  function self.update_platform(station_id, platform_id, patch)
    local station = self.register(station_id, station_id, {})
    if not station.platforms[platform_id] then station.platforms[platform_id] = normalize_platform({ id = platform_id }) end
    local platform = station.platforms[platform_id]
    for k, v in pairs(patch or {}) do platform[k] = v end
    station.last_seen = os.clock()
    return platform
  end

  function self.find_available_platform(station_id, opts)
    local station = by_id[station_id]
    if not station or station.state == "OFFLINE" or station.state == "FAULT" then return nil, "station unavailable" end
    local options = opts or {}
    local candidates = {}
    for _, platform in pairs(station.platforms or {}) do
      if FREE_STATES[platform.state or PLATFORM_STATES.EMPTY] and kind_matches(platform.kind, options.kind) then table.insert(candidates, platform) end
    end
    table.sort(candidates, platform_sort)
    if not candidates[1] then return nil, "no available platform" end
    return candidates[1]
  end

  function self.reserve_platform(station_id, opts)
    local platform, err = self.find_available_platform(station_id, opts)
    if not platform then return nil, err end
    local options = opts or {}
    platform.state = PLATFORM_STATES.RESERVED
    platform.train_id = options.train_id
    platform.route_id = options.route_id
    platform.destination = options.destination
    platform.reserved_at = os.clock()
    return platform
  end

  function self.release_platform(station_id, platform_id)
    local station = by_id[station_id]
    if not station or not station.platforms[platform_id] then return false, "platform not found" end
    local platform = station.platforms[platform_id]
    platform.state = PLATFORM_STATES.EMPTY
    platform.train_id = nil
    platform.route_id = nil
    platform.destination = nil
    platform.reserved_at = nil
    station.last_seen = os.clock()
    return true
  end

  function self.mark_offline(station_id)
    if by_id[station_id] then by_id[station_id].state = "OFFLINE" end
  end

  function self.get(station_id) return by_id[station_id] end

  function self.list()
    local out = {}
    for id, station in pairs(by_id) do
      local copy = shallow_copy(station)
      copy.platforms = {}
      for platform_id, platform in pairs(station.platforms or {}) do copy.platforms[platform_id] = shallow_copy(platform) end
      out[id] = copy
    end
    return out
  end

  return self
end

stations.PLATFORM_STATES = PLATFORM_STATES
stations.STATION_TYPES = STATION_TYPES
stations.kind_matches = kind_matches

return stations
