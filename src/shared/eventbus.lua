--[[
Purpose: Simple event bus with queue; supports subscribe/publish.
Public API: new(), subscribe(event, fn), publish(event, payload), next().
]]

local eventbus = {}

function eventbus.new()
  local bus = { subscribers = {}, queue = {} }

  function bus.subscribe(event, fn)
    bus.subscribers[event] = bus.subscribers[event] or {}
    table.insert(bus.subscribers[event], fn)
  end

  function bus.publish(event, payload)
    table.insert(bus.queue, { event = event, payload = payload })
  end

  function bus.next()
    local item = table.remove(bus.queue, 1)
    if not item then
      return false
    end
    local subs = bus.subscribers[item.event] or {}
    for _, fn in ipairs(subs) do
      fn(item.payload)
    end
    return true
  end

  return bus
end

return eventbus
