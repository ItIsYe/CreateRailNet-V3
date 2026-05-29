--[[
Purpose: Signal adapter with Create peripheral method support and redstone fallback.
Public API: new(peripherals, opts), setAspect(signal_id, aspect), getState(signal_id).
]]

local method_helper = require("src.adapter.methods")
local redstone = require("src.adapter.redstone")

local create_signals = {}

local function should_force_red(aspect)
  return aspect == "RED" or aspect == "STOP" or aspect == false
end

function create_signals.new(peripherals, opts)
  local options = opts or {}
  local hardware = options.hardware
  local rs = options.redstone or redstone.new()
  local self = {}

  local function adapter_for(id)
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

  function self.setAspect(signal_id, aspect)
    if adapter_for(signal_id) == "redstone" then
      local side = side_for(signal_id)
      local active = aspect == "GREEN" or aspect == "YELLOW"
      return rs.set_output(side, active)
    end

    local target = target_for(signal_id)
    if method_exists(target, "setForcedRed") then
      local ok, err = method_helper.call(peripherals, target, "setForcedRed", should_force_red(aspect))
      if not ok then return false, "signal " .. tostring(err) end
      return true
    end

    local ok, err = method_helper.call(peripherals, target, "setAspect", aspect)
    if not ok then return false, "signal " .. tostring(err) end
    return true
  end

  function self.getState(signal_id)
    if adapter_for(signal_id) == "redstone" then
      local ok, active = rs.get_input(side_for(signal_id))
      if not ok then return false, active end
      return true, active and "GREEN" or "RED"
    end

    local target = target_for(signal_id)
    if method_exists(target, "getState") then return method_helper.call(peripherals, target, "getState") end
    if method_exists(target, "isForcedRed") then
      local ok, forced = method_helper.call(peripherals, target, "isForcedRed")
      if not ok then return false, forced end
      return true, forced and "RED" or "UNKNOWN"
    end
    return false, "signal state method unavailable"
  end

  return self
end

return create_signals
