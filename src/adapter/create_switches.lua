--[[
Purpose: Create switch adapter.
Public API: new(peripherals), setPosition(switch_id, position).
]]
local create_switches = {}
local function has(methods, name) for _,m in ipairs(methods or {}) do if m==name then return true end end return false end
function create_switches.new(peripherals)
  local self = {}
  function self.setPosition(switch_id, position)
    local device, err = peripherals.wrap(switch_id)
    if not device then return false, err end
    local methods = peripherals.methods(switch_id)
    if not has(methods, "setPosition") or not device.setPosition then
      return false, "switch missing setPosition; available=" .. table.concat(methods, ",")
    end
    local ok, e = pcall(device.setPosition, position)
    if not ok then return false, "switch set failed: " .. tostring(e) end
    return true
  end
  return self
end
return create_switches
