--[[
Purpose: The cargo ledger of the fleet: orders, shipments and the proven quantities (Gesamtkonzept Kap. 10, 24.2, S-13).
Public API: new({ may_check(person) -> boolean }) -> ledger.
  ledger.create_order(spec) -> ok | false, err      spec: id, cargo_type, unit, target_qty, source, destination, load_track, unload_track, train_class, min_load, departure_rule (FULL | MIN_PARTIAL | TIME),
                                                    deadline, allow_empty_run, proof_mode (lowest accepted quality, default MANUAL_AUTH)
  ledger.report(event) -> ok, "duplicate"? | false, err    event: { order_id, shipment_id, kind = "loaded" | "unloaded", qty, quality, ref, by? }
  ledger.summary(order_id) -> { target, loaded, delivered, open, in_transit_or_unresolved, discrepancies }
  ledger.shipment(id) / ledger.shipments(order_id) -> { shipment_id, loaded_proven, unloaded_proven, unresolved, excess, evidence_refs }
  ledger.may_depart(order_id, now) -> true | false, why ; ledger.close(order_id); ledger.snapshot() / restore(); rule_for(order, line_default)
Quality (best first): AUTO_INVENTORY (a clear inventory or transfer measurement), EXTERNAL_AUTH (an authenticated external loading message), MANUAL_AUTH (a logged manual check by someone who may do it).
Notes: time and the arrival of the train are no proof of goods. Only unloaded quantities count as delivered; what was loaded and not shown to have arrived stays in_transit_or_unresolved, attributable to
  its shipment. The same report (same ref) twice changes nothing. Goods received without a proof of loading are delivered but counted as a discrepancy to explain.
]]

local cargo_ledger = {}

local QUALITY = { AUTO_INVENTORY = 3, EXTERNAL_AUTH = 2, MANUAL_AUTH = 1 }
local RULES = { FULL = true, MIN_PARTIAL = true, TIME = true }

function cargo_ledger.rule_for(order, line_default)
  return (order and order.departure_rule) or (line_default and line_default.departure_rule) or "FULL"
end

function cargo_ledger.new(opts)
  opts = opts or {}
  local self = {}
  local orders, shipments, refs = {}, {}, {}

  function self.create_order(spec)
    if type(spec) ~= "table" or type(spec.id) ~= "string" or spec.id == "" then return false, "order needs an id" end
    if orders[spec.id] then return false, "order " .. spec.id .. " already exists" end
    if type(spec.target_qty) ~= "number" or spec.target_qty <= 0 then return false, "target_qty must be a number > 0" end
    if spec.departure_rule and not RULES[spec.departure_rule] then return false, "unknown departure rule " .. tostring(spec.departure_rule) end
    local stored = {}
    for k, v in pairs(spec) do stored[k] = v end
    stored.proof_mode = stored.proof_mode or "MANUAL_AUTH"
    stored.closed = false
    orders[spec.id] = stored
    return true
  end

  function self.close(order_id)
    if not orders[order_id] then return false end
    orders[order_id].closed = true
    return true
  end

  function self.report(event)
    local order = event and orders[event.order_id]
    if not order then return false, "unknown order " .. tostring(event and event.order_id) end
    if order.closed then return false, "order " .. order.id .. " is closed" end
    if event.kind ~= "loaded" and event.kind ~= "unloaded" then return false, "kind must be loaded or unloaded" end
    if type(event.qty) ~= "number" or event.qty <= 0 then return false, "qty must be a number > 0" end
    local rank = QUALITY[event.quality]
    if not rank then return false, "'" .. tostring(event.quality) .. "' is not a proof of goods" end
    if rank < QUALITY[order.proof_mode] then return false, "quality " .. event.quality .. " is lower than the " .. order.proof_mode .. " this order asks for (proof)" end
    if event.quality == "MANUAL_AUTH" then
      if type(event.by) ~= "string" or event.by == "" then return false, "a manual check needs the person who did it" end
      if opts.may_check and not opts.may_check(event.by) then return false, event.by .. " is not allowed to check cargo" end
    end
    if type(event.ref) ~= "string" or event.ref == "" then return false, "a report needs a reference" end
    local key = event.order_id .. "/" .. event.ref
    if refs[key] then return true, "duplicate" end
    local shipment_id = event.shipment_id or (event.order_id .. "-S1")
    local shipment = shipments[shipment_id]
    if not shipment then
      shipment = { shipment_id = shipment_id, order_id = event.order_id, loaded_proven = 0, unloaded_proven = 0, evidence_refs = {} }
      shipments[shipment_id] = shipment
    elseif shipment.order_id ~= event.order_id then
      return false, "shipment " .. shipment_id .. " belongs to another order"
    end
    refs[key] = true
    if event.kind == "loaded" then shipment.loaded_proven = shipment.loaded_proven + event.qty else shipment.unloaded_proven = shipment.unloaded_proven + event.qty end
    shipment.evidence_refs[#shipment.evidence_refs + 1] = { ref = event.ref, kind = event.kind, quality = event.quality, qty = event.qty, by = event.by }
    return true
  end

  local function view(shipment)
    local out = {}
    for k, v in pairs(shipment) do out[k] = v end
    out.unresolved = math.max(0, shipment.loaded_proven - shipment.unloaded_proven)
    out.excess = math.max(0, shipment.unloaded_proven - shipment.loaded_proven)
    return out
  end

  function self.shipment(id) return shipments[id] and view(shipments[id]) or nil end

  function self.shipments(order_id)
    local out = {}
    for _, shipment in pairs(shipments) do if shipment.order_id == order_id then out[#out + 1] = view(shipment) end end
    table.sort(out, function(a, b) return a.shipment_id < b.shipment_id end)
    return out
  end

  function self.summary(order_id)
    local order = orders[order_id]
    if not order then return nil end
    local s = { target = order.target_qty, loaded = 0, delivered = 0, in_transit_or_unresolved = 0, discrepancies = 0 }
    for _, shipment in ipairs(self.shipments(order_id)) do
      s.loaded = s.loaded + shipment.loaded_proven
      s.delivered = s.delivered + shipment.unloaded_proven
      s.in_transit_or_unresolved = s.in_transit_or_unresolved + shipment.unresolved
      if shipment.excess > 0 then s.discrepancies = s.discrepancies + 1 end
    end
    s.open = math.max(0, s.target - s.delivered)
    return s
  end

  function self.may_depart(order_id, now)
    local order = orders[order_id]
    if not order then return false, "unknown order" end
    local s = self.summary(order_id)
    local rule = cargo_ledger.rule_for(order)
    if rule == "FULL" then
      if s.loaded >= order.target_qty then return true end
      return false, "not fully loaded (" .. s.loaded .. " of " .. order.target_qty .. " proven)"
    elseif rule == "MIN_PARTIAL" then
      if s.loaded >= (order.min_load or order.target_qty) then return true end
      return false, "minimum load not proven (" .. s.loaded .. " of " .. tostring(order.min_load or order.target_qty) .. ")"
    end
    if not order.deadline or now < order.deadline then return false, "deadline not reached" end
    if s.loaded > 0 or order.allow_empty_run == true then return true end
    return false, "nothing proven loaded and an empty run is not allowed for this order"
  end

  function self.snapshot()
    local out = { orders = {}, shipments = {}, refs = {} }
    for id, o in pairs(orders) do local c = {}; for k, v in pairs(o) do c[k] = v end; out.orders[id] = c end
    for id, s in pairs(shipments) do
      local c = {}
      for k, v in pairs(s) do c[k] = v end
      c.evidence_refs = {}
      for i, e in ipairs(s.evidence_refs) do c.evidence_refs[i] = { ref = e.ref, kind = e.kind, quality = e.quality, qty = e.qty, by = e.by } end
      out.shipments[id] = c
    end
    for k in pairs(refs) do out.refs[k] = true end
    return out
  end

  function self.restore(snap)
    orders, shipments, refs = {}, {}, {}
    for id, o in pairs((snap and snap.orders) or {}) do local c = {}; for k, v in pairs(o) do c[k] = v end; orders[id] = c end
    for id, s in pairs((snap and snap.shipments) or {}) do
      local c = {}
      for k, v in pairs(s) do c[k] = v end
      c.evidence_refs = {}
      for i, e in ipairs(s.evidence_refs or {}) do c.evidence_refs[i] = { ref = e.ref, kind = e.kind, quality = e.quality, qty = e.qty, by = e.by } end
      shipments[id] = c
    end
    for k in pairs((snap and snap.refs) or {}) do refs[k] = true end
  end

  return self
end

return cargo_ledger
