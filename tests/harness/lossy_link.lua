--[[
Purpose: In-memory network between modems with seeded loss, duplication and delay, on a virtual clock.
Public API: new(rng, opts) -> link with modem(id), advance(ms), now(), set_receiver(id, fn(msg)).
  opts: drop (0..1), duplicate (0..1), delay_max_ms, drop_acks (extra loss for messages of type "ack").
Notes: replaces os.clock with the link's clock until close() so time.now_ms() follows the virtual time.
]]

local link_mod = {}

function link_mod.new(rng, opts)
  local options = opts or {}
  local self = { clock_ms = 0, in_flight = {}, receivers = {}, stats = { sent = 0, dropped = 0, duplicated = 0, delivered = 0 } }
  local real_clock = os.clock
  os.clock = function() return self.clock_ms / 1000 end

  function self.close()
    if real_clock then os.clock = real_clock; real_clock = nil end
  end

  function self.now() return self.clock_ms end

  function self.set_receiver(id, fn) self.receivers[id] = fn end

  local function enqueue(msg)
    local copy = {}
    for k, v in pairs(msg) do copy[k] = v end
    self.in_flight[#self.in_flight + 1] = { due = self.clock_ms + rng.int(0, options.delay_max_ms or 0), msg = copy }
  end

  local function transmit(msg)
    self.stats.sent = self.stats.sent + 1
    local drop = options.drop or 0
    if msg.type == "ack" then drop = math.max(drop, options.drop_acks or 0) end
    if rng.chance(drop) then self.stats.dropped = self.stats.dropped + 1; return true end
    enqueue(msg)
    if rng.chance(options.duplicate or 0) then self.stats.duplicated = self.stats.duplicated + 1; enqueue(msg) end
    return true
  end

  function self.modem(id)
    return {
      id = id,
      open = function() return true end,
      send = function(_, _, _, msg) return transmit(msg) end,
      broadcast = function(_, _, msg) return transmit(msg) end
    }
  end

  -- moves the clock forward and hands every due message to its receiver
  function self.advance(ms)
    self.clock_ms = self.clock_ms + ms
    local due, later = {}, {}
    for _, entry in ipairs(self.in_flight) do
      if entry.due <= self.clock_ms then due[#due + 1] = entry else later[#later + 1] = entry end
    end
    self.in_flight = later
    table.sort(due, function(a, b) return a.due < b.due end)
    for _, entry in ipairs(due) do
      local receiver = self.receivers[entry.msg.dst]
      if receiver then self.stats.delivered = self.stats.delivered + 1; receiver(entry.msg) end
    end
  end

  return self
end

return link_mod
