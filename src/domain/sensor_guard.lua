--[[
Purpose: Sensor guard — debouncing, direction detection, sequence plausibility.

Problems solved:
  - A single sensor bounce (vibration, lag) must not trigger a block state change
  - Direction must be verifiable (A→B vs B→A) using entry/exit sensor pairs
  - Block sequence must be plausible (can't jump non-adjacent blocks)
  - Sensor events arrive with a timestamp — old events are ignored

Public API:
  new(config) -> guard
  guard.validate_enter(block_id, sensor_id, ts) -> ok, err
  guard.validate_leave(block_id, sensor_id, ts, entered_at) -> ok, err
  guard.record_enter(block_id, ts)
  guard.record_leave(block_id, ts)
  guard.get_direction(block_id) -> "forward" | "backward" | "unknown"
]]

local sensor_guard = {}

-- Minimum milliseconds a sensor must stay active to be valid (debounce)
local DEBOUNCE_MS = 200
-- Maximum age of a sensor event before it's considered stale
local MAX_EVENT_AGE_MS = 10000
-- Minimum time a train must occupy a block before leave is plausible (ms)
-- Can be overridden via config.sensor_guard_min_occupy_ms (set to 0 to disable)
local DEFAULT_MIN_OCCUPY_MS = 100

function sensor_guard.new(config)
  local self = {}
  local cfg = config or {}
  local MIN_OCCUPY_MS = cfg.sensor_guard_min_occupy_ms
  if MIN_OCCUPY_MS == nil then MIN_OCCUPY_MS = DEFAULT_MIN_OCCUPY_MS end

  -- Track enter timestamps per block
  local enter_times = {}
  -- Track last direction per block (using sensor pair if available)
  local directions = {}
  -- Adjacent block map (built from route definitions)
  local adjacent = {}

  -- Build adjacency from routes
  for _, route in ipairs(cfg.routes or {}) do
    local blocks = route.blocks or {}
    for i = 1, #blocks - 1 do
      local a, b = blocks[i], blocks[i+1]
      adjacent[a] = adjacent[a] or {}
      adjacent[b] = adjacent[b] or {}
      adjacent[a][b] = true
      adjacent[b][a] = true
    end
  end

  -- Block config map for sensor pair lookup
  local block_cfg = {}
  for _, b in ipairs(cfg.blocks or {}) do
    block_cfg[b.id] = b
  end

  -- Use os.clock() for duration measurements (relative, not wall clock)
  -- This is intentional: debounce and min-occupy are about elapsed machine time
  local function now_ms()
    return math.floor(os.clock() * 1000)
  end

  -- Validate an enter event
  function self.validate_enter(block_id, sensor_id, ts)
    local event_time = ts or now_ms()
    local age = now_ms() - event_time

    -- Reject stale events (arrived too late)
    if age > MAX_EVENT_AGE_MS then
      return false, string.format("stale enter event for %s: age=%dms > max=%dms", block_id, age, MAX_EVENT_AGE_MS)
    end

    -- If we already have a very recent enter for this block, debounce it
    local last_enter = enter_times[block_id]
    if last_enter and (event_time - last_enter) < DEBOUNCE_MS then
      return false, string.format("debounce: enter for %s too soon after last enter (%dms)", block_id, event_time - last_enter)
    end

    return true
  end

  -- Validate a leave event
  function self.validate_leave(block_id, sensor_id, ts, entered_at)
    local event_time = ts or now_ms()
    local age = now_ms() - event_time

    if age > MAX_EVENT_AGE_MS then
      return false, string.format("stale leave event for %s: age=%dms", block_id, age)
    end

    -- Train must have occupied block for minimum time
    local occupy_start = entered_at or enter_times[block_id]
    if occupy_start then
      local occupy_duration = event_time - occupy_start
      if occupy_duration < MIN_OCCUPY_MS then
        return false, string.format("implausible leave for %s: occupied only %dms (min %dms)", block_id, occupy_duration, MIN_OCCUPY_MS)
      end
    end

    return true
  end

  function self.record_enter(block_id, ts)
    enter_times[block_id] = ts or now_ms()
  end

  function self.record_leave(block_id, ts)
    -- Keep enter_time for occupation duration calculation until overwritten
    enter_times[block_id] = nil
  end

  -- Detect direction using entry/exit sensor pairs if configured
  -- entry_sensor = sensor at block entry, exit_sensor = at exit
  function self.detect_direction(block_id, sensor_id)
    local bcfg = block_cfg[block_id]
    if not bcfg then return "unknown" end

    if bcfg.entry_sensor and bcfg.exit_sensor then
      if sensor_id == bcfg.entry_sensor then
        directions[block_id] = "forward"
      elseif sensor_id == bcfg.exit_sensor then
        directions[block_id] = "backward"
      end
    end

    return directions[block_id] or "unknown"
  end

  -- Validate that a block transition is plausible given previous block
  function self.validate_sequence(new_block_id, prev_block_id)
    if not prev_block_id then return true end  -- no previous, can't check
    if new_block_id == prev_block_id then return true end

    -- Check adjacency
    if adjacent[prev_block_id] and adjacent[prev_block_id][new_block_id] then
      return true
    end

    -- Not adjacent — suspicious but not necessarily impossible (train could skip)
    return false, string.format("non-adjacent block transition: %s -> %s", tostring(prev_block_id), tostring(new_block_id))
  end

  function self.get_direction(block_id)
    return directions[block_id] or "unknown"
  end

  function self.get_enter_time(block_id)
    return enter_times[block_id]
  end

  return self
end

return sensor_guard
