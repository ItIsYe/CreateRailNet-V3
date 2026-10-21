--[[
Purpose: Signal and switch adapters of a master with a partner: restrictive calls pass at once, calls that give movement wait in the commit barrier, and a master that does not lead touches nothing (Kap. 5.1, 5.2).
Public API: guard(adapter, opts) -> adapter with the same methods. opts: barrier, ha (is_leader), kind ("signals" | "switches"), logger.
Notes: for signals setAspect(id, "RED" | "STOP" | false) is restrictive: it removes a waiting green of that signal and goes through immediately; every other aspect waits for the barrier. For switches
  setPosition always waits (moving a turnout under a train is not something to rush). A call that waits answers true ("accepted"), as the real adapter would; if the standby never confirms, the queue
  is dropped when the leadership is lost and the new leader restores the committed state, so the dispatcher's view and the hardware cannot drift apart for good. getState and other reads pass
  through on both masters. A master that does not lead answers false, "not the active leader" to every call that would change hardware.
]]

local guarded_adapters = {}

local RESTRICTIVE_ASPECTS = { RED = true, STOP = true }

function guarded_adapters.guard(adapter, opts)
  local barrier, ha, kind = opts.barrier, opts.ha, opts.kind
  local proxy = setmetatable({}, { __index = function(_, name) return adapter[name] end })

  if kind == "signals" then
    function proxy.setAspect(signal_id, aspect)
      if ha and not ha.is_leader() then return false, "not the active leader" end
      if RESTRICTIVE_ASPECTS[aspect] or aspect == false then
        barrier.cancel("signal:" .. tostring(signal_id))
        return adapter.setAspect(signal_id, aspect)
      end
      barrier.hold("signal:" .. tostring(signal_id), function() adapter.setAspect(signal_id, aspect) end)
      return true
    end
  elseif kind == "switches" then
    function proxy.setPosition(switch_id, position)
      if ha and not ha.is_leader() then return false, "not the active leader" end
      barrier.hold("switch:" .. tostring(switch_id), function() adapter.setPosition(switch_id, position) end)
      return true
    end
  end
  return proxy
end

return guarded_adapters
