--[[
Purpose: Node registry with capabilities and heartbeat tracking.
Public API: new(), register(node_id, role, caps), heartbeat(node_id).
]]

local registry = {}

function registry.new()
  local reg = { nodes = {} }

  function reg.register(node_id, role, caps)
    reg.nodes[node_id] = {
      id = node_id,
      role = role,
      caps = caps or {},
      last_seen = os.time(),
      status = "UP"
    }
  end

  function reg.heartbeat(node_id)
    local node = reg.nodes[node_id]
    if node then
      node.last_seen = os.time()
      node.status = "UP"
    end
  end

  function reg.mark_down(node_id)
    local node = reg.nodes[node_id]
    if node then
      node.status = "DOWN"
    end
  end

  function reg.get(node_id)
    return reg.nodes[node_id]
  end

  function reg.all()
    return reg.nodes
  end

  return reg
end

return registry

