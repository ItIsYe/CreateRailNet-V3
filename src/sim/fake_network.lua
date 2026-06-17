--[[
Purpose: In-memory fake network for offline simulations.
Public API: new() -> network with send, inbox, drain, sent.
]]

local fake_network = {}

function fake_network.new()
  local self = { sent = {}, inboxes = {} }

  function self.send(msg_type, dst, payload)
    local msg = { type = msg_type, dst = dst, payload = payload or {} }
    table.insert(self.sent, msg)
    self.inboxes[dst] = self.inboxes[dst] or {}
    table.insert(self.inboxes[dst], msg)
    return { id = "sim-" .. tostring(#self.sent) }
  end

  -- In simulation, reliable = regular send (no packet loss)
  function self.send_reliable(msg_type, dst, payload)
    return self.send(msg_type, dst, payload)
  end

  function self.receive() return "ok" end
  function self.ack_for() end
  function self.tick() end

  function self.inbox(id)
    self.inboxes[id] = self.inboxes[id] or {}
    return self.inboxes[id]
  end

  function self.drain(id)
    local messages = self.inbox(id)
    self.inboxes[id] = {}
    return messages
  end

  function self.last()
    return self.sent[#self.sent]
  end

  return self
end

return fake_network
