--[[
Purpose: Create switch adapter.
Public API: new(peripherals), setPosition(switch_id, position).
]]

local create_switches = {}

function create_switches.new(peripherals)
  local self = {}

  function self.setPosition(switch_id, position)
    local device = peripherals.wrap(switch_id)
    if device and device.setPosition then
      local ok, err = pcall(device.setPosition, position)
      if not ok then
        return false, "switch set failed: " .. tostring(err)
      end
      return true
    end
    return false, "switch adapter missing"
  end

  return self
end

return create_switches
