--[[
Purpose: Domain registry for stations and their platforms/tracks.
Public API: new(config) -> registry with register, update_platform, update_status, list, get.
]]

local stations = {}

local STATION_TYPES = {
  passenger = true,
  freight = true,
  mixed = true
}

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

local function shallow_copy(src)
  local dst = {}
  for k, v in pairs(src or {}) do
    dst[k] = v
  end
  return dst
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
    destination = platform.destination
  }
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
        station_type = STATION_TYPES[node.station_type or node.type] and (node.station_type or node.type) or "mixed",
        state = node.state or "ONLINE",
        last_seen = 0,
        platforms = {}
      }

      for _, platform in ipairs(node.platforms or node.tracks or {}) do
        local normalized = normalize_platform(platform)
        if normalized.id then
          station.platforms[normalized.id] = normalized
        end
      end

      by_id[station_id] = station
    end
  end

  function self.register(station_id, node_id, info)
    local id = station_id or node_id
    if not by_id[id] then
      by_id[id] = {
        id = id,
        node_id = node_id,
        display_name = (info and info.display_name) or id,
        station_type = (info and info.station_type) or "mixed",
        state = "ONLINE",
        last_seen = os.clock(),
        platforms = {}
      }
    end

    local station = by_id[id]
    station.node_id = node_id or station.node_id
    station.display_name = (info and info.display_name) or station.display_name
    station.station_type = (info and info.station_type) or station.station_type
    station.state = (info and info.state) or station.state or "ONLINE"
    station.last_seen = os.clock()
    return station
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
    if not station.platforms[platform_id] then
      station.platforms[platform_id] = normalize_platform({ id = platform_id })
    end
    local platform = station.platforms[platform_id]
    for k, v in pairs(patch or {}) do
      platform[k] = v
    end
    station.last_seen = os.clock()
    return platform
  end

  function self.mark_offline(station_id)
    if by_id[station_id] then
      by_id[station_id].state = "OFFLINE"
    end
  end

  function self.get(station_id)
    return by_id[station_id]
  end

  function self.list()
    local out = {}
    for id, station in pairs(by_id) do
      local copy = shallow_copy(station)
      copy.platforms = {}
      for platform_id, platform in pairs(station.platforms or {}) do
        copy.platforms[platform_id] = shallow_copy(platform)
      end
      out[id] = copy
    end
    return out
  end

  return self
end

stations.PLATFORM_STATES = PLATFORM_STATES
stations.STATION_TYPES = STATION_TYPES

return stations
