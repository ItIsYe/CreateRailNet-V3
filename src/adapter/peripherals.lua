--[[
Purpose: Safe peripheral wrapper with caching and inspection.
Public API: new(backend), wrap(name), list(), methods(name), get_type(name).
]]

local peripherals = {}

function peripherals.new(backend)
  local api = backend or _G.peripheral or {}
  local cache = {}
  local self = {}

  function self.wrap(name)
    -- Re-validate cached peripheral: check it still has methods (not disconnected)
    if cache[name] then
      local ok, methods = pcall(function()
        return api.getMethods and api.getMethods(name)
      end)
      if not ok or not methods then
        cache[name] = nil  -- Invalidate stale cache entry
      else
        return cache[name]
      end
    end
    if api.wrap then
      local ok, wrapped = pcall(api.wrap, name)
      if ok and wrapped then cache[name] = wrapped; return wrapped end
    end
    return nil, "peripheral not found: " .. tostring(name)
  end

  -- Explicit cache invalidation for peripheral_detach event handler
  function self.invalidate(name)
    if name then cache[name] = nil
    else cache = {} end
  end

  function self.list() if api.getNames then local ok,v=pcall(api.getNames); if ok then return v end end return {} end
  function self.methods(name) if api.getMethods then local ok,v=pcall(api.getMethods,name); if ok then return v end end return {} end
  function self.get_type(name) if api.getType then local ok,v=pcall(api.getType,name); if ok then return v end end return nil end
  return self
end

return peripherals
