--[[
Purpose: Measures what moved at a loading or unloading point from the inventory next to the track, and says nothing when it cannot be sure (Gesamtkonzept Kap. 10, 24.2; Pruefplan G-05 bis G-10).
Public API: new({ peripheral (the CC api), now () -> seconds, tries (4) }) -> meter.
  meter.total(name, item) -> number | nil, err        the number of items in the inventory (of one kind, or all when item is nil)
  meter.begin(key, name, item) -> ok | false, err      the count when the train arrives
  meter.finish(key, kind) -> { ok = true, qty, quality = "AUTO_INVENTORY", ref } | { ok = false, reason }      kind = "loaded" (the inventory lost items) | "unloaded" (it gained items)
  meter.pending(key) -> boolean
Notes: a measurement is only taken when two readings in a row agree (an inventory that still moves is not read); a peripheral that is gone or answers nonsense is no measurement and not a zero. The change has to go the way
  the kind says: items that appeared in a loading chest are not "loaded". Zero is a result (nothing moved) and is returned as qty 0: the caller books nothing for it. The reference is made of the key and a counter, so the
  same report twice is recognised by the ledger. Nothing here invents a quantity: no start reading, no end reading, no booking.
]]

local cargo_meter = {}

function cargo_meter.new(opts)
  local api = opts.peripheral
  local now = opts.now or function() return 0 end
  local tries = opts.tries or 4
  local self = {}
  local started = {}   -- key -> { name, item, total, at }
  local counter = 0

  function self.total(name, item)
    if not (api and api.call) then return nil, "no peripheral api" end
    local ok, list = pcall(api.call, name, "list")
    if not ok or type(list) ~= "table" then return nil, "inventory " .. tostring(name) .. " cannot be read" end
    local total = 0
    for _, stack in pairs(list) do
      if type(stack) ~= "table" or type(stack.count) ~= "number" or stack.count < 0 then return nil, "inventory " .. tostring(name) .. " answers nonsense" end
      if item == nil or stack.name == item then total = total + stack.count end
    end
    return total
  end

  function self.begin(key, name, item)
    local total, err = self.total(name, item)
    if not total then started[key] = nil; return false, err end
    started[key] = { name = name, item = item, total = total, at = now() }
    return true
  end

  function self.pending(key) return started[key] ~= nil end

  function self.finish(key, kind)
    local s = started[key]
    started[key] = nil
    if not s then return { ok = false, reason = "no start reading" } end
    if kind ~= "loaded" and kind ~= "unloaded" then return { ok = false, reason = "unknown kind " .. tostring(kind) } end
    local previous
    for _ = 1, tries do
      local total, err = self.total(s.name, s.item)
      if not total then return { ok = false, reason = err } end
      if previous ~= nil and total == previous then
        local qty = (kind == "loaded") and (s.total - total) or (total - s.total)
        if qty < 0 then return { ok = false, reason = "the inventory moved the wrong way for '" .. kind .. "' (" .. s.total .. " -> " .. total .. ")" } end
        counter = counter + 1
        return { ok = true, qty = qty, quality = "AUTO_INVENTORY", ref = tostring(key) .. "#" .. counter .. "@" .. tostring(math.floor(now())) }
      end
      previous = total
    end
    return { ok = false, reason = "the inventory does not hold still" }
  end

  return self
end

return cargo_meter
