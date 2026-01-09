--[[
Purpose: Time helper for milliseconds.
Public API: now_ms().
]]

local time = {}

function time.now_ms()
  return math.floor(os.clock() * 1000)
end

return time
