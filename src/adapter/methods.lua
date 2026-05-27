--[[
Purpose: Shared helper for peripheral method lookup and protected calls.
Public API: has(methods, name), require_method(peripherals, id, method_name), call(peripherals, id, method_name, ...).
]]

local methods = {}

function methods.has(list, name)
  for _, item in ipairs(list or {}) do
    if item == name then
      return true
    end
  end
  return false
end

function methods.require_method(peripherals, id, method_name)
  local device, wrap_err = peripherals.wrap(id)
  if not device then
    return nil, wrap_err
  end

  local available = peripherals.methods(id)
  if not methods.has(available, method_name) or not device[method_name] then
    return nil, tostring(id) .. " missing " .. method_name .. "; available=" .. table.concat(available, ",")
  end

  return device[method_name], nil, device
end

function methods.call(peripherals, id, method_name, ...)
  local fn, err, device = methods.require_method(peripherals, id, method_name)
  if not fn then
    return false, err
  end

  local ok, result = pcall(fn, ...)
  if not ok then
    return false, tostring(id) .. "." .. method_name .. " failed: " .. tostring(result)
  end

  return true, result
end

return methods
