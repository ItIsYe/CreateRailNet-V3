--[[
Purpose: Cargo / Güterverkehr domain.
Manages freight orders (Frachtaufträge), loading/unloading, cargo types.

Public API:
  new(config) -> cargo_system
  create_order(opts) -> order_id
  get_order(order_id) -> order
  assign_train(order_id, train_id) -> ok, err
  start_loading(order_id) -> ok, err
  finish_loading(order_id) -> ok, err
  start_unloading(order_id) -> ok, err
  finish_unloading(order_id) -> ok, err
  cancel_order(order_id) -> ok
  list_orders(filter) -> [orders]
  get_track_cargo(track_id) -> cargo info
]]

local time = require("src.shared.time")

local cargo = {}

local ORDER_STATES = {
  PENDING   = "PENDING",    -- order created, no train assigned
  ASSIGNED  = "ASSIGNED",   -- train assigned, waiting to depart
  EN_ROUTE  = "EN_ROUTE",   -- train travelling to pickup
  LOADING   = "LOADING",    -- train at loading site
  LOADED    = "LOADED",     -- cargo loaded, en route to delivery
  UNLOADING = "UNLOADING",  -- train at delivery site
  DELIVERED = "DELIVERED",  -- order complete
  CANCELLED = "CANCELLED",
}
cargo.ORDER_STATES = ORDER_STATES

-- Standard cargo types
cargo.TYPES = {
  COAL    = "coal",
  ORE     = "ore",
  STONE   = "stone",
  GRAIN   = "grain",
  GOODS   = "goods",
  LOGS    = "logs",
  OIL     = "oil",
  LIQUID  = "liquid",
  MAIL    = "mail",
  GENERAL = "general",
}

function cargo.new(config)
  local self = {}
  local orders = {}
  local order_seq = 0

  -- Industry/loading points from config
  local industries = {}
  for _, ind in ipairs((config and config.industries) or {}) do
    industries[ind.id] = ind
  end

  local function next_id()
    order_seq = order_seq + 1
    return "ORD-" .. string.format("%04d", order_seq)
  end

  -- Create a new freight order
  -- opts: { cargo_type, amount, from_industry, to_industry, priority, train_class }
  function self.create_order(opts)
    local o = opts or {}
    local id = o.id or next_id()
    orders[id] = {
      id           = id,
      cargo_type   = o.cargo_type or cargo.TYPES.GENERAL,
      amount       = o.amount or 1,
      from_industry= o.from_industry,
      to_industry  = o.to_industry,
      from_track   = o.from_track,   -- specific loading track
      to_track     = o.to_track,     -- specific unloading track
      train_class  = o.train_class or "freight",
      priority     = o.priority or 5,
      state        = ORDER_STATES.PENDING,
      train_id     = nil,
      created_at   = time.now_s(),
      assigned_at  = nil,
      loaded_at    = nil,
      delivered_at = nil,
      notes        = o.notes,
    }
    return id
  end

  function self.get_order(order_id)
    return orders[order_id]
  end

  function self.assign_train(order_id, train_id)
    local order = orders[order_id]
    if not order then return false, "order not found: " .. tostring(order_id) end
    if order.state ~= ORDER_STATES.PENDING then
      return false, "order not in PENDING state: " .. tostring(order.state)
    end
    order.train_id   = train_id
    order.state      = ORDER_STATES.ASSIGNED
    order.assigned_at= time.now_s()
    return true
  end

  function self.start_loading(order_id)
    local order = orders[order_id]
    if not order then return false, "order not found" end
    if order.state ~= ORDER_STATES.ASSIGNED and order.state ~= ORDER_STATES.EN_ROUTE then
      return false, "cannot start loading from state: " .. tostring(order.state)
    end
    order.state = ORDER_STATES.LOADING
    order.loading_started_at = time.now_s()
    return true
  end

  function self.finish_loading(order_id)
    local order = orders[order_id]
    if not order then return false, "order not found" end
    if order.state ~= ORDER_STATES.LOADING then
      return false, "not in LOADING state"
    end
    order.state    = ORDER_STATES.LOADED
    order.loaded_at= time.now_s()
    return true
  end

  function self.start_unloading(order_id)
    local order = orders[order_id]
    if not order then return false, "order not found" end
    if order.state ~= ORDER_STATES.LOADED then
      return false, "train not loaded — cannot unload"
    end
    order.state = ORDER_STATES.UNLOADING
    order.unloading_started_at = time.now_s()
    return true
  end

  function self.finish_unloading(order_id)
    local order = orders[order_id]
    if not order then return false, "order not found" end
    if order.state ~= ORDER_STATES.UNLOADING then
      return false, "not in UNLOADING state"
    end
    order.state        = ORDER_STATES.DELIVERED
    order.delivered_at = time.now_s()
    return true
  end

  function self.set_en_route(order_id)
    local order = orders[order_id]
    if not order then return false, "not found" end
    order.state = ORDER_STATES.EN_ROUTE
    return true
  end

  function self.cancel_order(order_id)
    local order = orders[order_id]
    if not order then return false, "not found" end
    order.state       = ORDER_STATES.CANCELLED
    order.cancelled_at= time.now_s()
    return true
  end

  -- Train can only depart if loaded (for freight trains with an order)
  function self.can_depart(train_id)
    for _, order in pairs(orders) do
      if order.train_id == train_id and
         (order.state == ORDER_STATES.ASSIGNED or order.state == ORDER_STATES.EN_ROUTE) then
        -- Train has an order but cargo not yet loaded
        return false, "train has pending order " .. order.id .. " — must load first"
      end
    end
    return true
  end

  -- List orders with optional filter
  function self.list_orders(filter)
    local f = filter or {}
    local out = {}
    for _, order in pairs(orders) do
      local match = true
      if f.state and order.state ~= f.state then match = false end
      if f.train_id and order.train_id ~= f.train_id then match = false end
      if f.cargo_type and order.cargo_type ~= f.cargo_type then match = false end
      if match then table.insert(out, order) end
    end
    table.sort(out, function(a,b)
      return (a.priority or 5) > (b.priority or 5)
    end)
    return out
  end

  -- Pending orders that need a train
  function self.pending_orders()
    return self.list_orders({ state = ORDER_STATES.PENDING })
  end

  function self.get_train_order(train_id)
    for _, order in pairs(orders) do
      if order.train_id == train_id and
         order.state ~= ORDER_STATES.DELIVERED and
         order.state ~= ORDER_STATES.CANCELLED then
        return order
      end
    end
    return nil
  end

  return self
end

return cargo
