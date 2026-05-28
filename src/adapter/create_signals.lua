--[[
Purpose: Signal adapter with Create peripheral method support and redstone fallback.
Public API: new(peripherals, opts), setAspect(signal_id, aspect).
]]

local method_helper = require("src.adapter.methods")
local redstone = require("src.adapter.redstone")

local create_signals = {}

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

  function self.setAspect(signal_id, aspect)
    if adapter_for(signal_id) == "redstone" then
      local side = side_for(signal_id)
      local active = aspect == "GREEN" or aspect == "YELLOW"
      return rs.set_output(side, active)
    end

    local ok, err = method_helper.call(peripherals, target_for(signal_id), "setAspect", aspect)
    if not ok then
      return false, "signal " .. tostring(err)
    end
    return true
  end

  return self
end

return create_signals
