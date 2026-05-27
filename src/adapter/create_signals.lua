--[[
Purpose: Create signal adapter.
Public API: new(peripherals), setAspect(signal_id, aspect).
]]

local method_helper = require("src.adapter.methods")

local create_signals = {}

function create_signals.new(peripherals)
  local self = {}

  function self.setAspect(signal_id, aspect)
    local ok, err = method_helper.call(peripherals, signal_id, "setAspect", aspect)
    if not ok then
      return false, "signal " .. tostring(err)
    end
    return true
  end

  return self
end

return create_signals
