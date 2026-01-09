--[[
Purpose: Safe peripheral wrapper with caching and inspection.
Public API: new(backend), wrap(name), list(), methods(name).
]]

local peripherals = {}

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

  return self
end

return peripherals
