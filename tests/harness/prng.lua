--[[
Purpose: Deterministic pseudo random numbers for property and chaos tests, identical on Lua 5.1, 5.4 and LuaJIT.
Public API: new(seed) -> rng with int(lo, hi), pick(list), chance(p), shuffle(list).
Notes: Park-Miller generator; every intermediate value stays below 2^53, so doubles and integers agree.
]]

local prng = {}

local MODULUS = 2147483647
local MULTIPLIER = 16807

function prng.new(seed)
  local state = math.floor(tonumber(seed) or 1) % MODULUS
  if state == 0 then state = 1 end
  local self = {}

  local function next_value()
    state = (state * MULTIPLIER) % MODULUS
    return state
  end

  function self.int(lo, hi)
    return lo + (next_value() % (hi - lo + 1))
  end

  function self.pick(list)
    return list[self.int(1, #list)]
  end

  function self.chance(p)
    return (next_value() % 10000) < p * 10000
  end

  function self.shuffle(list)
    for i = #list, 2, -1 do
      local j = self.int(1, i)
      list[i], list[j] = list[j], list[i]
    end
    return list
  end

  return self
end

return prng
