--[[
Purpose: Priority queue of the fleet orders (Gesamtkonzept Kap. 8.3).
Public API: new({ aging_s (600), max_promotion (2), now }) -> queue.
  queue.push(order) -> ok | false, err         order = { id, kind, manual?, ... }; kind is one of KINDS
  queue.next(filter) -> order | nil            the best order the filter accepts (filter(order) -> boolean); an order that cannot start stays queued
  queue.get(id), queue.remove(id), queue.size(), queue.list(), queue.snapshot(), queue.restore(snapshot)
  order.rank = the class (1..6), order.effective = rank after aging
Classes: 1 REPLACEMENT_PASSENGER, 2 SCHEDULED_PASSENGER, 3 REPLACEMENT_FREIGHT, 4 SCHEDULED_FREIGHT, 5 EXTRA_PASSENGER, 6 EXTRA_FREIGHT.
Notes: inside a class first come, first served. Anti-starvation: for every aging_s seconds an order waits, its effective rank improves by one, at most max_promotion steps; among equal effective ranks the
  better class goes first, then the older order. Manual does not mean higher: a manual order has the rank of its class. Priority lifts neither safety nor a hardware limit: the filter says what can start, the rest waits.
]]

local priority = {}

priority.KINDS = { "REPLACEMENT_PASSENGER", "SCHEDULED_PASSENGER", "REPLACEMENT_FREIGHT", "SCHEDULED_FREIGHT", "EXTRA_PASSENGER", "EXTRA_FREIGHT" }

local RANK = {}
for i, kind in ipairs(priority.KINDS) do RANK[kind] = i end

function priority.new(opts)
  opts = opts or {}
  local now = opts.now or function() return 0 end
  local aging_s = opts.aging_s or 600
  local max_promotion = opts.max_promotion
  if max_promotion == nil then max_promotion = 2 end
  local self = {}
  local orders, seq = {}, 0

  local function effective(order)
    local steps = 0
    if aging_s > 0 and max_promotion > 0 then steps = math.min(max_promotion, math.floor((now() - order.queued_at) / aging_s)) end
    return math.max(1, order.rank - steps)
  end

  local function refresh(order) order.effective = effective(order); return order end

  function self.push(order)
    if type(order) ~= "table" or type(order.id) ~= "string" or order.id == "" then return false, "order needs an id" end
    if not RANK[order.kind] then return false, "unknown kind " .. tostring(order.kind) end
    if orders[order.id] then return false, "order " .. order.id .. " already exists" end
    seq = seq + 1
    local stored = {}
    for k, v in pairs(order) do stored[k] = v end
    stored.rank, stored.seq, stored.queued_at = RANK[order.kind], seq, now()
    orders[order.id] = stored
    return true
  end

  function self.get(id)
    local order = orders[id]
    return order and refresh(order) or nil
  end

  function self.remove(id)
    if not orders[id] then return false end
    orders[id] = nil
    return true
  end

  function self.size()
    local n = 0
    for _ in pairs(orders) do n = n + 1 end
    return n
  end

  function self.list()
    local out = {}
    for _, order in pairs(orders) do out[#out + 1] = refresh(order) end
    table.sort(out, function(a, b)
      if a.effective ~= b.effective then return a.effective < b.effective end
      if a.rank ~= b.rank then return a.rank < b.rank end
      return a.seq < b.seq
    end)
    return out
  end

  function self.next(filter)
    for _, order in ipairs(self.list()) do
      if not filter or filter(order) then return order end
    end
    return nil
  end

  function self.snapshot()
    local out = { seq = seq, orders = {} }
    for id, order in pairs(orders) do
      local c = {}
      for k, v in pairs(order) do c[k] = v end
      out.orders[id] = c
    end
    return out
  end

  function self.restore(snap)
    orders, seq = {}, (snap and snap.seq) or 0
    for id, order in pairs((snap and snap.orders) or {}) do
      local c = {}
      for k, v in pairs(order) do c[k] = v end
      orders[id] = c
    end
  end

  return self
end

return priority
