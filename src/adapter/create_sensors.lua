--[[
Purpose: Create sensor adapter.
Public API: new(peripherals), readOccupied(sensor_id).
]]

local method_helper = require("src.adapter.methods")

local create_sensors = {}

function create_sensors.new(peripherals)
  local self = {}

  function self.readOccupied(sensor_id)
    local ok, result = method_helper.call(peripherals, sensor_id, "isOccupied")
    if not ok then
      return false, "sensor " .. tostring(result)
    end
    return true, result and true or false
  end

  return self
end

return create_sensors
