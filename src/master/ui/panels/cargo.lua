--[[
Purpose: Cargo / Güterverkehr panel — freight orders, loading status, cargo types.
]]

local ui_utils = require("src.master.ui.ui_utils")
local cargo_panel = {}

local ORDER_STATE_COLORS = {
  PENDING    = 16,   -- yellow
  ASSIGNED   = 512,  -- cyan
  EN_ROUTE   = 32,   -- lime
  LOADING    = 2,    -- orange
  LOADED     = 32,   -- lime
  UNLOADING  = 2,    -- orange
  DELIVERED  = 256,  -- lightGray
  CANCELLED  = 128,  -- gray
}

local ORDER_LABELS = {
  PENDING   ="AUFTRAG", ASSIGNED  ="ZUGETEILT",
  EN_ROUTE  ="UNTERWEGS", LOADING ="LAEDT",
  LOADED    ="BELADEN", UNLOADING ="ENTLAEDT",
  DELIVERED ="GELIEFERT", CANCELLED="ABGEBROCH",
}

function cargo_panel.new(cargo_ref, manual_control_ref)
  local self = { offset=0, filter="active", selected=nil, action_result=nil, action_ts=0 }
  local C = ui_utils.colors

  local FILTERS = { "active", "pending", "delivered", "all" }
  local filter_idx = 1

  local function get_orders()
    if not cargo_ref then return {} end
    local f = self.filter
    local filter_state = nil
    if f == "pending" then filter_state = "PENDING"
    elseif f == "delivered" then filter_state = "DELIVERED" end
    local orders
    if f == "active" then
      orders = {}
      for _, o in ipairs(cargo_ref.list_orders() or {}) do
        if o.state ~= "DELIVERED" and o.state ~= "CANCELLED" then
          table.insert(orders, o)
        end
      end
    else
      orders = cargo_ref.list_orders(filter_state and {state=filter_state} or nil) or {}
    end
    table.sort(orders, function(a,b)
      return (a.priority or 5) > (b.priority or 5)
    end)
    return orders
  end

  local function exec(action, order)
    if not manual_control_ref or not order then return end
    local ok, err
    if action == "assign" then
      -- Would need train selection — show placeholder
      self.action_result = "Zug-Zuweisung: order=" .. order.id .. " (Zug im Trains-Panel auswaehlen)"
    elseif action == "loaded" then
      ok, err = manual_control_ref.handle({action="cargo_loaded", order_id=order.id}, "panel")
      self.action_result = ok and "Beladen: " .. order.id or ("Fehler: " .. tostring(err))
    elseif action == "delivered" then
      ok, err = manual_control_ref.handle({action="cargo_delivered", order_id=order.id}, "panel")
      self.action_result = ok and "Geliefert: " .. order.id or ("Fehler: " .. tostring(err))
    elseif action == "cancel" then
      ok, err = manual_control_ref.handle({action="cargo_cancel", order_id=order.id}, "panel")
      self.action_result = ok and "Abgebrochen: " .. order.id or ("Fehler: " .. tostring(err))
      self.selected = nil
    end
    self.action_ts = os.clock()
  end

  local ACTIONS = {
    { x=1,  label="[BELADEN  ]", key="loaded" },
    { x=13, label="[GELIEFERT]", key="delivered" },
    { x=25, label="[ABBRUCH  ]", key="cancel" },
  }

  function self.draw(monitor)
    if not monitor then return end
    local u = ui_utils.new(monitor)
    local w, h = u.size()
    u.clear(C.black)
    u.header(1, "GUETERVERKEHR  [" .. self.filter:upper() .. "]", nil, w)

    if not cargo_ref then
      u.write_at(3, 4, "Cargo-System nicht verfuegbar.", C.red)
      u.footer(h, "", w)
      return
    end

    local orders = get_orders()

    -- Filter bar
    u.fill_line(2, C.gray, w)
    u.write_at(1, 2, " Filter: ", C.white, C.gray)
    local fx = 10
    for _, f in ipairs(FILTERS) do
      local fc = f == self.filter and C.lime or C.lightGray
      local bg = f == self.filter and C.gray or C.gray
      u.write_at(fx, 2, "[" .. f:upper() .. "]", fc, bg)
      fx = fx + #f + 3
    end
    u.write_at(w-10, 2, "#" .. #orders, C.white, C.gray)

    if #orders == 0 then
      u.write_at(3, 4, "Keine Auftraege (" .. self.filter .. ").", C.lightGray)
      u.write_at(3, 6, "Frachtauftraege in Config unter", C.lightGray)
      u.write_at(3, 7, "cargo_orders definieren.", C.lightGray)
      u.footer(h, "Tippen=Filter wechseln", w)
      return
    end

    -- Column headers
    u.fill_line(3, C.gray, w)
    u.write_at(1, 3, string.format("%-10s %-9s %-10s %-8s %-10s", "AUFTRAG", "ZUSTAND", "VON", "NACH", "ZUG"), C.white, C.gray)

    local row = 4
    local start = self.offset + 1

    for i = start, #orders do
      if row > h - 5 then break end
      local order = orders[i]
      local is_sel = (self.selected == order.id)
      local row_bg = is_sel and C.blue or C.black
      local state_col = ORDER_STATE_COLORS[order.state] or C.white
      local state_label = ORDER_LABELS[order.state] or tostring(order.state)

      u.fill_line(row, row_bg, w)
      u.write_at(1, row, tostring(order.id):sub(1,9), C.white, row_bg)
      u.write_at(11, row, state_label:sub(1,8), state_col, row_bg)
      u.write_at(20, row, tostring(order.from_industry or order.from_track or "-"):sub(1,9), C.cyan, row_bg)
      u.write_at(30, row, tostring(order.to_industry or order.to_track or "-"):sub(1,7), C.cyan, row_bg)
      u.write_at(38, row, tostring(order.train_id or "-"):sub(1,10), C.yellow, row_bg)
      -- Cargo type + amount
      local cargo_str = tostring(order.cargo_type or "?"):sub(1,7)
      if order.amount then cargo_str = cargo_str .. "x" .. tostring(order.amount) end
      u.write_at(w-#cargo_str, row, cargo_str, C.orange, row_bg)
      row = row + 1
    end

    -- Action bar
    if self.selected then
      u.separator(h-4, w)
      u.fill_line(h-3, C.blue, w)
      u.write_at(1, h-3, "AUFTRAG: " .. tostring(self.selected), C.white, C.blue)
      for _, act in ipairs(ACTIONS) do
        u.write_at(act.x, h-2, act.label, C.white)
      end
      if self.action_result and (os.clock()-self.action_ts) < 5 then
        u.write_at(1, h-1, tostring(self.action_result):sub(1,w), C.lime)
      else
        u.write_at(1, h-1, "Aktion antippen", C.lightGray)
      end
    else
      u.separator(h-4, w)
      u.write_at(1, h-3, "Auftrag antippen fuer Aktionen", C.lightGray)
      u.write_at(1, h-2, "Filter oben antippen um zu wechseln", C.lightGray)
    end

    u.footer(h, string.format("Scroll  %d/%d Auftraege", math.min(self.offset+1,math.max(1,#orders)), #orders), w)
  end

  function self.touch(x, y)
    local _, h = 51, 19
    local orders = get_orders()

    -- Filter bar
    if y == 2 then
      filter_idx = (filter_idx % #FILTERS) + 1
      self.filter = FILTERS[filter_idx]
      self.offset = 0; self.selected = nil; return
    end

    -- Action buttons
    if self.selected and y == h-2 then
      local sel_order = nil
      for _, o in ipairs(orders) do if o.id == self.selected then sel_order = o; break end end
      for _, act in ipairs(ACTIONS) do
        if x >= act.x and x < act.x + #act.label then
          exec(act.key, sel_order); return
        end
      end
    end

    -- Order list
    if y >= 4 and y <= h-5 then
      local idx = y - 4 + self.offset + 1
      if idx >= 1 and idx <= #orders then
        local order = orders[idx]
        self.selected = (self.selected == order.id) and nil or order.id
        self.action_result = nil
      end
    end

    if y > h/2 then self.offset = self.offset + 1
    elseif y < 4 then self.offset = math.max(0, self.offset-1) end
  end

  return self
end

return cargo_panel
