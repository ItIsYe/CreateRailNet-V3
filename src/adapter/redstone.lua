--[[
Purpose: Redstone fallback adapter for ATM10/CC:Tweaked nodes.
Public API: new(backend) -> adapter with set_output(side, value), get_input(side).
]]

local redstone_adapter = {}

function redstone_adapter.new(backend)
  local api = backend or _G.redstone or _G.rs or {}
  local self = {}

  function self.set_output(side, value)
    if not side or side == "" then
      return false, "redstone side missing"
    end
    if not api.setOutput then
      return false, "redstone.setOutput unavailable"
    end
    local ok, err = pcall(api.setOutput, side, value and true or false)
    if not ok then
      return false, "redstone setOutput failed: " .. tostring(err)
    end
    return true
  end

  function self.get_input(side)
    if not side or side == "" then
      return false, "redstone side missing"
    end
    if not api.getInput then
      return false, "redstone.getInput unavailable"
    end
    local ok, value = pcall(api.getInput, side)
    if not ok then
      return false, "redstone getInput failed: " .. tostring(value)
    end
    return true, value and true or false
  end

  return self
end

return redstone_adapter
