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
    if #bus.queue == 0 then return false end
    -- Peek first; only remove after all subscribers succeed
    local item = bus.queue[1]
    local subs = bus.subscribers[item.event] or {}
    local all_ok = true
    for _, fn in ipairs(subs) do
      local ok, err = pcall(fn, item.payload)
      if not ok then
        all_ok = false
        -- Keep the item in queue for retry on persistent failure?
        -- For now: remove and surface the error to avoid infinite loops
        if bus.on_error then bus.on_error(item.event, err) end
      end
    end
    table.remove(bus.queue, 1)
    return true, all_ok
  end

  return bus
end

return eventbus
