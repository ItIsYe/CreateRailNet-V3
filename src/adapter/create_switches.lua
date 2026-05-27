--[[
Purpose: Create switch adapter.
Public API: new(peripherals), setPosition(switch_id, position).
]]

local method_helper = require("src.adapter.methods")

local create_switches = {}

function create_switches.new(peripherals)
  local self = {}

  function self.setPosition(switch_id, position)
    local ok, err = method_helper.call(peripherals, switch_id, "setPosition", position)
    if not ok then
      return false, "switch " .. tostring(err)
    end
    return true
  end

  return self
end

return create_switches
