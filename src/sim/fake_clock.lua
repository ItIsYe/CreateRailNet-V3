--[[
Purpose: Deterministic fake clock for offline simulations.
Public API: new(start) -> clock with now(), now_ms(), advance(seconds), set(seconds).
]]

local fake_clock = {}

function fake_clock.new(start)
  local self = { t = start or 0 }

  function self.now()
    return self.t
  end

  function self.now_ms()
    return math.floor(self.t * 1000)
  end

  function self.advance(seconds)
    self.t = self.t + (seconds or 0)
    return self.t
  end

  function self.set(seconds)
    self.t = seconds or 0
    return self.t
  end

  return self
end

return fake_clock
