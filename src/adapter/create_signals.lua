--[[
Purpose: Create signal adapter.
Public API: new(peripherals), setAspect(signal_id, aspect).
]]
local create_signals = {}
local function has(methods, name) for _,m in ipairs(methods or {}) do if m==name then return true end end return false end
function create_signals.new(peripherals)
  local self = {}
  function self.setAspect(signal_id, aspect)
    local device, err = peripherals.wrap(signal_id)
    if not device then return false, err end
    local methods = peripherals.methods(signal_id)
    if not has(methods, "setAspect") or not device.setAspect then
      return false, "signal missing setAspect; available=" .. table.concat(methods, ",")
    end
    local ok, e = pcall(device.setAspect, aspect)
    if not ok then return false, "signal set failed: " .. tostring(e) end
    return true
  end
  return self
end
return create_signals
