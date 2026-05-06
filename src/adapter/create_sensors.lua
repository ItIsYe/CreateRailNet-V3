--[[
Purpose: Create sensor adapter.
Public API: new(peripherals), readOccupied(sensor_id).
]]
local create_sensors = {}
local function has(methods, name) for _,m in ipairs(methods or {}) do if m==name then return true end end return false end
function create_sensors.new(peripherals)
  local self = {}
  function self.readOccupied(sensor_id)
    local device, err = peripherals.wrap(sensor_id)
    if not device then return false, err end
    local methods = peripherals.methods(sensor_id)
    if not has(methods, "isOccupied") or not device.isOccupied then
      return false, "sensor missing isOccupied; available=" .. table.concat(methods, ",")
    end
    local ok, res = pcall(device.isOccupied)
    if not ok then return false, "sensor read failed: " .. tostring(res) end
    return true, res and true or false
  end
  return self
end
return create_sensors
