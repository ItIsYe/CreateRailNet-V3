--[[
Purpose: Domain registry for depots and depot tracks/staging slots.
Public API: new(config) -> registry with register, update_track, update_status, find_available_track, reserve_track, release_track, enqueue, dequeue, list, get.
]]

local time = require("src.shared.time")

local depots = {}

local TRACK_STATES = { EMPTY = "EMPTY", RESERVED = "RESERVED", OCCUPIED = "OCCUPIED", STAGING = "STAGING", READY = "READY", DEPARTING = "DEPARTING", LOCKED = "LOCKED", FAULT = "FAULT", UNKNOWN = "UNKNOWN" }
local FREE_STATES = { EMPTY = true, READY = true, STAGING = true }

local function copy(src) local dst = {}; for k, v in pairs(src or {}) do dst[k] = v end; return dst end
local function kind_matches(track_kind, requested_kind) local tk = track_kind or "mixed"; local rk = requested_kind or "mixed"; return tk == "mixed" or rk == "mixed" or tk == rk end
local function normalize_track(track) local id = track.id or track.track_id or track.name; return { id = id, track_id = track.track_id or id, kind = track.kind or track.type or "mixed", block_id = track.block_id, sensor_id = track.sensor_id, state = track.state or TRACK_STATES.EMPTY, train_id = track.train_id, route_id = track.route_id, destination = track.destination, priority = track.priority or 0 } end
local function track_sort(a, b) if (a.priority or 0) ~= (b.priority or 0) then return (a.priority or 0) > (b.priority or 0) end; return tostring(a.id) < tostring(b.id) end
local function queue_sort(a, b) if (a.priority or 0) ~= (b.priority or 0) then return (a.priority or 0) > (b.priority or 0) end; return (a.seq or 0) < (b.seq or 0) end

function depots.new(config)
  local by_id = {}
  local seq = 0
  local self = {}

  for _, node in ipairs((config and config.nodes) or {}) do
    if node.role == "depot" then
      local depot_id = node.depot_id or node.id
      local depot = { id = depot_id, node_id = node.id, display_name = node.display_name or depot_id, depot_type = node.depot_type or node.type or "mixed", state = node.state or "ONLINE", last_seen = 0, queue = {}, tracks = {} }
      for _, track in ipairs(node.tracks or node.slots or {}) do local normalized = normalize_track(track); if normalized.id then depot.tracks[normalized.id] = normalized end end
      by_id[depot_id] = depot
    end
  end

  function self.register(depot_id, node_id, info)
    local id = depot_id or node_id
    if not by_id[id] then by_id[id] = { id = id, node_id = node_id, display_name = (info and info.display_name) or id, depot_type = (info and info.depot_type) or "mixed", state = "ONLINE", last_seen = time.now_s(), queue = {}, tracks = {} } end
    local depot = by_id[id]
    depot.node_id = node_id or depot.node_id
    depot.display_name = (info and info.display_name) or depot.display_name
    depot.depot_type = (info and info.depot_type) or depot.depot_type
    depot.state = (info and info.state) or depot.state or "ONLINE"
    depot.reconnect_reason = info and info.reconnect_reason or depot.reconnect_reason
    depot.last_seen = time.now_s()
    return depot
  end

  function self.update_status(depot_id, status) local depot = self.register(depot_id, depot_id, status); depot.state = status.state or depot.state; depot.message = status.message; depot.last_seen = time.now_s(); return depot end
  function self.update_track(depot_id, track_id, patch)
    local depot = self.register(depot_id, depot_id, {})
    if not depot.tracks[track_id] then depot.tracks[track_id] = normalize_track({ id = track_id }) end
    local track = depot.tracks[track_id]
    for k, v in pairs(patch or {}) do track[k] = v end
    -- Clear recovery flag when a definitive state is provided
    if patch and patch.state and patch.state ~= "UNKNOWN" then track.recovery_required = false end
    depot.last_seen = time.now_s()
    return track
  end

  function self.find_available_track(depot_id, opts)
    local depot = by_id[depot_id]
    if not depot or depot.state == "OFFLINE" or depot.state == "FAULT" then return nil, "depot unavailable" end
    local options = opts or {}; local candidates = {}
    for _, track in pairs(depot.tracks or {}) do if FREE_STATES[track.state or TRACK_STATES.EMPTY] and kind_matches(track.kind, options.kind) then table.insert(candidates, track) end end
    table.sort(candidates, track_sort)
    if not candidates[1] then return nil, "no available depot track" end
    return candidates[1]
  end

  function self.reserve_track(depot_id, opts) local track, err = self.find_available_track(depot_id, opts); if not track then return nil, err end; local options = opts or {}; track.state = TRACK_STATES.RESERVED; track.train_id = options.train_id; track.route_id = options.route_id; track.destination = options.destination; track.reserved_at = time.now_s(); return track end
  function self.release_track(depot_id, track_id) local depot = by_id[depot_id]; if not depot or not depot.tracks[track_id] then return false, "track not found" end; local track = depot.tracks[track_id]; track.state = TRACK_STATES.EMPTY; track.train_id = nil; track.route_id = nil; track.destination = nil; track.reserved_at = nil; depot.last_seen = time.now_s(); return true end
  function self.enqueue(depot_id, request) local depot = self.register(depot_id, depot_id, {}); seq = seq + 1; local item = copy(request or {}); item.seq = item.seq or seq; item.queued_at = item.queued_at or time.now_s(); table.insert(depot.queue, item); table.sort(depot.queue, queue_sort); depot.last_seen = time.now_s(); return #depot.queue end
  function self.dequeue(depot_id) local depot = self.register(depot_id, depot_id, {}); depot.last_seen = time.now_s(); table.sort(depot.queue, queue_sort); return table.remove(depot.queue, 1) end

  function self.mark_offline(depot_id)
    local depot = by_id[depot_id]
    if depot then
      depot.state = "OFFLINE"; depot.message = "offline - track states unknown until reconnect"
      for _, track in pairs(depot.tracks or {}) do track.state = TRACK_STATES.UNKNOWN; track.recovery_required = true end
    end
  end

  function self.get(depot_id) return by_id[depot_id] end
  function self.list() local out = {}; for id, depot in pairs(by_id) do local depot_copy = copy(depot); depot_copy.tracks = {}; depot_copy.queue = {}; for track_id, track in pairs(depot.tracks or {}) do depot_copy.tracks[track_id] = copy(track) end; for i, item in ipairs(depot.queue or {}) do depot_copy.queue[i] = copy(item) end; out[id] = depot_copy end; return out end
  return self
end

depots.TRACK_STATES = TRACK_STATES
depots.kind_matches = kind_matches

return depots
