--[[
Purpose: Mock modem with deterministic routing and optional latency.
Public API: new(), attach(node_id, handler), send(channel, dst, msg), broadcast.
]]

local mock_modem = {}

function mock_modem.new(latency)
  local self = { handlers = {}, latency = latency or 0, queue = {} }

  function self.attach(node_id, handler)
    self.handlers[node_id] = handler
  end

  local function deliver(dst, msg)
    local handler = self.handlers[dst]
    if handler then
      handler(msg)
    end
  end

  function self.send(channel, dst, msg)
    if self.latency > 0 then
      table.insert(self.queue, { dst = dst, msg = msg, ticks = self.latency })
    else
      deliver(dst, msg)
    end
  end

  function self.broadcast(channel, msg)
    for id, _ in pairs(self.handlers) do
      self.send(channel, id, msg)
    end
  end

  function self.tick()
    for i = #self.queue, 1, -1 do
      local item = self.queue[i]
      item.ticks = item.ticks - 1
      if item.ticks <= 0 then
        deliver(item.dst, item.msg)
        table.remove(self.queue, i)
      end
    end
  end

  return self
end

return mock_modem
