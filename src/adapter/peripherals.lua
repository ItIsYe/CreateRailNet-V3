--[[
Purpose: Safe peripheral wrapper with caching, guarded calls, and monitor scale helpers.
Public API: new(backend), wrap(name), list(), methods(name), call(obj, method, ...), normalize_scale(v), set_monitor_scale(monitor, scale).
]]

local peripherals = {}

local function clamp(value, min_value, max_value)
  if value < min_value then
    return min_value
  end
  if value > max_value then
    return max_value
  end
  return value
end

function peripherals.new(backend)
  local api = backend or _G.peripheral or {}
  local cache = {}

  local self = {}

  function self.wrap(name)
    if cache[name] then
      return cache[name]
    end
    if api.wrap then
      local ok, wrapped = pcall(api.wrap, name)
      if ok and wrapped then
        cache[name] = wrapped
        return wrapped
      end
    end
    return {
      clear = function() end,
      setCursorPos = function() end,
      write = function() end
    }
  end

  function self.list()
    if api.getNames then
      local ok, names = pcall(api.getNames)
      if ok then
        return names
      end
    end
    return {}
  end

  function self.methods(name)
    if api.getMethods then
      local ok, methods = pcall(api.getMethods, name)
      if ok then
        return methods
      end
    end
    return {}
  end

  function self.call(obj, method, ...)
    if type(obj) ~= "table" then
      return false, "call target is not a table"
    end
    local fn = obj[method]
    if type(fn) ~= "function" then
      return false, "missing method: " .. tostring(method)
    end
    return pcall(fn, obj, ...)
  end

  function self.normalize_scale(value)
    if type(value) ~= "number" then
      return 1
    end
    local normalized = clamp(value, 0.5, 5)
    normalized = math.floor((normalized * 2) + 0.5) / 2
    return normalized
  end

  function self.set_monitor_scale(monitor, scale)
    local normalized = self.normalize_scale(scale)
    if type(monitor) ~= "table" then
      return false, normalized, "monitor unavailable"
    end
    if monitor.__crn_last_scale == normalized then
      return true, normalized
    end
    local ok, err = self.call(monitor, "setTextScale", normalized)
    if not ok then
      return false, normalized, err
    end
    monitor.__crn_last_scale = normalized
    return true, normalized
  end

  return self
end

return peripherals
