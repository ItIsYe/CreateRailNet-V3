--[[
Purpose: Time helpers for CC:Tweaked with correct wall-clock semantics.
Public API:
  now_ms()  — milliseconds for relative timing (net retry, dwell). Uses os.clock()*1000.
              TPS-dependent but self-consistent within a session.
  now_s()   — wall-clock seconds for timeouts and timestamps.
              Uses os.epoch("utc")/1000 in CC:Tweaked (accurate regardless of TPS).
              Falls back to os.clock() in test environments (Lua 5.1).

NOTE: os.time() in CC:Tweaked returns in-game time (0..24 float), NOT unix seconds.
      os.clock() returns game-ticks * 0.05, NOT real seconds (TPS-dependent).
      os.epoch("utc") returns real milliseconds since epoch — always use this for timeouts.
]]

local time = {}

-- For net retry and dwell timing (relative, sub-second, TPS-dependent is acceptable)
function time.now_ms()
  return math.floor(os.clock() * 1000)
end

-- For heartbeat timeouts and all wall-clock timestamps.
-- In CC:Tweaked: os.epoch("utc") returns real milliseconds since epoch.
-- In Lua 5.1 test env: os.time() returns unix seconds (acceptable for tests).
function time.now_s()
  if os.epoch then
    return math.floor(os.epoch("utc") / 1000)
  end
  -- Fallback for test environments (Lua 5.1 os.time() = unix seconds)
  return os.time and os.time() or math.floor(os.clock())
end

return time
