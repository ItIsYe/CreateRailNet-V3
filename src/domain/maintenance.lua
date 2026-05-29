--[[
Purpose: Maintenance/lockdown state for safe operator control.
Public API: new() -> mode with enable, disable, is_locked, status.
]]

local maintenance = {}

function maintenance.new()
  local state = {
    enabled = false,
    reason = nil,
    changed_by = nil,
    changed_at = nil
  }
  local self = {}

  function self.enable(reason, actor)
    state.enabled = true
    state.reason = reason or "maintenance"
    state.changed_by = actor
    state.changed_at = os.clock()
    return true
  end

  function self.disable(actor)
    state.enabled = false
    state.reason = nil
    state.changed_by = actor
    state.changed_at = os.clock()
    return true
  end

  function self.is_locked()
    return state.enabled
  end

  function self.status()
    return {
      enabled = state.enabled,
      reason = state.reason,
      changed_by = state.changed_by,
      changed_at = state.changed_at
    }
  end

  return self
end

return maintenance
