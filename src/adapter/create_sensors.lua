--[[
Purpose: Create sensor adapter.
Public API: new(peripherals), readOccupied(sensor_id).
]]

local create_sensors = {}

function create_sensors.new(peripherals)
  local self = {}

  function self.readOccupied(sensor_id)
    local device = peripherals.wrap(sensor_id)
    if device and device.isOccupied then
      local ok, res = pcall(device.isOccupied)
      if ok then
        return true, res
      end
      return false, "sensor read failed"
    end
    return false, "sensor adapter missing"
  end

  return self
end

return create_sensors
