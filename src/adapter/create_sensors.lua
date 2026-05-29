--[[
Purpose: Sensor adapter with Create peripheral method support and optional redstone input mode.
Public API: new(peripherals, opts), readOccupied(sensor_id), readTrainName(sensor_id).
]]

local method_helper = require("src.adapter.methods")
local redstone = require("src.adapter.redstone")

local create_sensors = {}

function create_sensors.new(peripherals, opts)
  local options = opts or {}
  local hardware = options.hardware
  local rs = options.redstone or redstone.new()
  local self = {}

  local function mode_for(id)
    return hardware and hardware.adapter(id) or "peripheral"
  end

  local function target_for(id)
    return hardware and hardware.target(id) or id
  end

  local function side_for(id)
    return hardware and hardware.side(id) or nil
  end

  local function method_exists(target, method)
    if not peripherals or not peripherals.methods then return false end
    return method_helper.has(peripherals.methods(target), method)
  end

  function self.readOccupied(sensor_id)
    if mode_for(sensor_id) == "redstone" then
      return rs.get_input(side_for(sensor_id))
    end

    local target = target_for(sensor_id)
    if method_exists(target, "isTrainPassing") then
      local ok, result = method_helper.call(peripherals, target, "isTrainPassing")
      if not ok then return false, "sensor " .. tostring(result) end
      return true, result and true or false
    end

    if method_exists(target, "isOccupied") then
      local ok, result = method_helper.call(peripherals, target, "isOccupied")
      if not ok then return false, "sensor " .. tostring(result) end
      return true, result and true or false
    end

    return false, "sensor occupancy method unavailable"
  end

  function self.readTrainName(sensor_id)
    if mode_for(sensor_id) == "redstone" then return true, nil end
    local target = target_for(sensor_id)
    if method_exists(target, "getPassingTrainName") then return method_helper.call(peripherals, target, "getPassingTrainName") end
    return true, nil
  end

  return self
end

return create_sensors
