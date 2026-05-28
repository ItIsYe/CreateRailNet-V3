--[[
Purpose: Domain registry for depots and depot tracks/staging slots.
Public API: new(config) -> registry with register, update_track, update_status, enqueue, dequeue, list, get.
]]

local depots = {}

local TRACK_STATES = {
  EMPTY = "EMPTY",
  RESERVED = "RESERVED",
  OCCUPIED = "OCCUPIED",
  STAGING = "STAGING",
  READY = "READY",
  DEPARTING = "DEPARTING",
  LOCKED = "LOCKED",
  FAULT = "FAULT"
}

local function copy(src)
  local dst = {}
  for k, v in pairs(src or {}) do dst[k] = v end
  return dst
end

local function normalize_track(track)
  local id = track.id or track.track_id or track.name
  return {
    id = id,
    track_id = track.track_id or id,
    kind = track.kind or track.type or "mixed",
    block_id = track.block_id,
    sensor_id = track.sensor_id,
    state = track.state or TRACK_STATES.EMPTY,
    train_id = track.train_id,
    priority = track.priority or 0
  }
end

function depots.new(config)
  local by_id = {}
  local self = {}

  for _, node in ipairs((config and config.nodes) or {}) do
    if node.role == "depot" then
      local depot_id = node.depot_id or node.id
      local depot = {
        id = depot_id,
        node_id = node.id,
        display_name = node.display_name or depot_id,
        depot_type = node.depot_type or node.type or "mixed",
        state = node.state or "ONLINE",
        last_seen = 0,
        queue = {},
        tracks = {}
      }
      for _, track in ipairs(node.tracks or node.slots or {}) do
        local normalized = normalize_track(track)
        if normalized.id then depot.tracks[normalized.id] = normalized end
      end
      by_id[depot_id] = depot
    end
  end

  function self.register(depot_id, node_id, info)
    local id = depot_id or node_id
    if not by_id[id] then
      by_id[id] = {
        id = id,
        node_id = node_id,
        display_name = (info and info.display_name) or id,
        depot_type = (info and info.depot_type) or "mixed",
        state = "ONLINE",
        last_seen = os.clock(),
        queue = {},
        tracks = {}
      }
    end
    local depot = by_id[id]
    depot.node_id = node_id or depot.node_id
    depot.display_name = (info and info.display_name) or depot.display_name
    depot.depot_type = (info and info.depot_type) or depot.depot_type
    depot.state = (info and info.state) or depot.state or "ONLINE"
    depot.last_seen = os.clock()
    return depot
  end

  function self.update_status(depot_id, status)
    local depot = self.register(depot_id, depot_id, status)
    depot.state = status.state or depot.state
    depot.message = status.message
    depot.last_seen = os.clock()
    return depot
  end

  function self.update_track(depot_id, track_id, patch)
    local depot = self.register(depot_id, depot_id, {})
    if not depot.tracks[track_id] then depot.tracks[track_id] = normalize_track({ id = track_id }) end
    local track = depot.tracks[track_id]
    for k, v in pairs(patch or {}) do track[k] = v end
    depot.last_seen = os.clock()
    return track
  end

  function self.enqueue(depot_id, request)
    local depot = self.register(depot_id, depot_id, {})
    table.insert(depot.queue, copy(request or {}))
    depot.last_seen = os.clock()
    return #depot.queue
  end

  function self.dequeue(depot_id)
    local depot = self.register(depot_id, depot_id, {})
    depot.last_seen = os.clock()
    return table.remove(depot.queue, 1)
  end

  function self.mark_offline(depot_id)
    if by_id[depot_id] then by_id[depot_id].state = "OFFLINE" end
  end

  function self.get(depot_id)
    return by_id[depot_id]
  end

  function self.list()
    local out = {}
    for id, depot in pairs(by_id) do
      local depot_copy = copy(depot)
      depot_copy.tracks = {}
      depot_copy.queue = {}
      for track_id, track in pairs(depot.tracks or {}) do depot_copy.tracks[track_id] = copy(track) end
      for i, item in ipairs(depot.queue or {}) do depot_copy.queue[i] = copy(item) end
      out[id] = depot_copy
    end
    return out
  end

  return self
end

depots.TRACK_STATES = TRACK_STATES

return depots
