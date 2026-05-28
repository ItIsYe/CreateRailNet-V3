--[[
Purpose: Lock table for route-owned switch positions.
Public API: new() -> locks with can_lock, lock_many, release_by_route, list.
]]

local switch_locks = {}

function switch_locks.new()
  local locks = {}
  local self = {}

  function self.can_lock(switch_id, position, owner)
    local existing = locks[switch_id]
    if not existing then return true end
    if existing.owner == owner and existing.position == position then return true end
    return false, "switch locked: " .. tostring(switch_id) .. " by " .. tostring(existing.owner)
  end

  function self.lock_many(requirements, owner)
    for _, req in ipairs(requirements or {}) do
      local ok, err = self.can_lock(req.id, req.position, owner)
      if not ok then return false, err end
    end
    for _, req in ipairs(requirements or {}) do
      locks[req.id] = { id = req.id, position = req.position, owner = owner }
    end
    return true
  end

  function self.release_by_route(owner)
    for id, lock in pairs(locks) do
      if lock.owner == owner then locks[id] = nil end
    end
  end

  function self.list()
    local out = {}
    for id, lock in pairs(locks) do
      out[id] = { id = lock.id, position = lock.position, owner = lock.owner }
    end
    return out
  end

  return self
end

return switch_locks
