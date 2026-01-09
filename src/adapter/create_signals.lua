--[[
Purpose: Create signal adapter.
Public API: new(peripherals), setAspect(signal_id, aspect).
]]

local create_signals = {}

function create_signals.new(peripherals)
  local self = {}

  function self.setAspect(signal_id, aspect)
    local device = peripherals.wrap(signal_id)
    if device and device.setAspect then
      local ok, err = pcall(device.setAspect, aspect)
      if not ok then
        return false, "signal set failed: " .. tostring(err)
      end
      return true
    end
    return false, "signal adapter missing"
  end

  return self
end

return create_signals
