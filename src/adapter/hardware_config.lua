--[[
Purpose: Resolve node hardware configuration for adapters.
Public API: new(config) -> resolver with node(id), target(id), adapter(id), side(id), value(id, key).
]]

local hardware_config = {}

function hardware_config.new(config)
  local by_id = {}
  for _, node in ipairs((config and config.nodes) or {}) do
    if node.id then
      by_id[node.id] = node
    end
  end

  local self = {}

  function self.node(id)
    return by_id[id] or { id = id }
  end

  function self.adapter(id)
    local node = self.node(id)
    return node.adapter or "peripheral"
  end

  function self.target(id)
    local node = self.node(id)
    return node.peripheral or node.target or id
  end

  function self.side(id)
    local node = self.node(id)
    return node.side
  end

  function self.value(id, key)
    local node = self.node(id)
    return node[key]
  end

  return self
end

return hardware_config
