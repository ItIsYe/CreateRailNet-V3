--[[
Purpose: Train control panel — touch a train to get action buttons.
Actions: Hold, Release, Emergency Stop, Request Route.
]]

local ui_utils = require("src.master.ui.ui_utils")
local trains_panel = {}

local STATE_LABELS = {
  OFFLINE="OFFLINE", REGISTERING="ANMELDEN", QUEUED="WARTEND",
  WAITING_FOR_ROUTE="ROUTE?", ROUTE_ASSIGNED="ZUGETEILT",
  RUNNING="FAEHRT", ARRIVING="ANKUNFT", ARRIVED="AM ZUG",
  FAULT="STOERUNG", MAINTENANCE="WARTUNG", IDLE="BEREIT",
  DEPART_AUTHORIZED="ABFAHRT!", WAITING_DEPARTURE="WARTE",
}

function trains_panel.new(train_registry, manual_control_ref)
  local self = { offset = 0, selected = nil, action_result = nil, action_result_ts = 0 }
  local C = ui_utils.colors

  local function get_sorted()
    local trains = train_registry and train_registry.list() or {}
    local sorted = {}
    for id, t in pairs(trains) do table.insert(sorted, {id=id, t=t}) end
    table.sort(sorted, function(a, b) return a.id < b.id end)
    return sorted
  end

  -- Execute an action on the selected train
  local function exec_action(action_name)
    if not self.selected then return end
    if not manual_control_ref then
      self.action_result = "Kein Manual-Control"; self.action_result_ts = os.clock(); return
    end
    local train = train_registry and train_registry.get(self.selected)
    local ok, err
    if action_name == "hold" then
      ok, err = manual_control_ref.handle({ action="hold_train", train_id=self.selected, reason="Manuell gehalten" }, "panel")
      self.action_result = ok and "Gehalten: " .. self.selected or ("Fehler: " .. tostring(err))
    elseif action_name == "release" then
      ok, err = manual_control_ref.handle({ action="authorize_train", train_id=self.selected, route_id=train and train.route_id }, "panel")
      self.action_result = ok and "Freigegeben: " .. self.selected or ("Fehler: " .. tostring(err))
    elseif action_name == "stop" then
      ok, err = manual_control_ref.handle({ action="emergency_stop", train_id=self.selected, reason="Notfallhalt Panel" }, "panel")
      self.action_result = ok and "NOTFALL: " .. self.selected or ("Fehler: " .. tostring(err))
    elseif action_name == "route" then
      ok, err = manual_control_ref.handle({ action="request_route", train_id=self.selected }, "panel")
      self.action_result = ok and "Route angefordert: " .. self.selected or ("Fehler: " .. tostring(err))
    elseif action_name == "deselect" then
      self.selected = nil; self.action_result = nil; return
    end
    self.action_result_ts = os.clock()
  end

  -- Action buttons shown when a train is selected
  local ACTIONS = {
    { x=1,  w=12, label="[  HALTEN  ]", key="hold",    fg=function(s) return C.yellow end },
    { x=14, w=12, label="[FREIGEBEN ]", key="release",  fg=function(s) return C.lime end },
    { x=27, w=12, label="[  NOTFALL ]", key="stop",     fg=function(s) return C.white end, bg=function(s) return C.red end },
    { x=40, w=12, label="][  ROUTE  ]", key="route",    fg=function(s) return C.cyan end },
  }

  function self.draw(monitor)
    if not monitor then return end
    local u = ui_utils.new(monitor)
    local w, h = u.size()
    u.clear(C.black)
    u.header(1, "ZUGSTEUERUNG", nil, w)

    local sorted = get_sorted()
    if #sorted == 0 then
      u.write_at(3, 4, "Keine Zuege registriert.", C.lightGray)
      u.footer(h, "Warte auf Zug-Verbindung...", w)
      return
    end

    -- Column headers
    u.fill_line(2, C.gray, w)
    u.write_at(1, 2, string.format("%-4s %-12s %-14s %-10s %-8s", " ", "ZUG", "STATUS", "ROUTE", "ZIEL"), C.white, C.gray)

    local row = 3
    local start = self.offset + 1
    local rows_per_train = 2

    -- Show train list
    for i = start, #sorted do
      if row > h - 6 then break end
      local entry = sorted[i]
      local t = entry.t
      local is_selected = (self.selected == entry.id)
      local row_bg = is_selected and C.blue or C.black
      local state_label = STATE_LABELS[tostring(t.state)] or tostring(t.state or "?")
      local state_col = (ui_utils.STATE_COLORS[tostring(t.state)] or {fg=C.white}).fg

      u.fill_line(row, row_bg, w)
      u.state_badge(1, row, t.state)
      u.write_at(6, row, tostring(t.display_name or entry.id):sub(1,11), is_selected and C.white or C.white, row_bg)
      u.write_at(18, row, state_label:sub(1,13), state_col, row_bg)
      u.write_at(32, row, tostring(t.route_id or "-"):sub(1,9), C.cyan, row_bg)
      u.write_at(42, row, tostring(t.destination or "-"):sub(1,w-42), C.yellow, row_bg)
      row = row + 1

      if row <= h - 6 then
        u.fill_line(row, row_bg, w)
        local plan_str = t.service_plan and ("SP:" .. tostring(t.service_plan):sub(1,8)) or ""
        local stop_str = t.service_stop_index and ("#" .. t.service_stop_index) or ""
        local msg_str = tostring(t.message or ""):sub(1, w-3-#plan_str-#stop_str-2)
        u.write_at(3, row, plan_str .. " " .. stop_str, C.purple, row_bg)
        if msg_str ~= "" then u.write_at(w-#msg_str, row, msg_str, C.orange, row_bg) end
        row = row + 1
      end
    end

    -- Action bar for selected train
    local action_row = h - 4
    if self.selected then
      u.separator(action_row, w)
      action_row = action_row + 1
      u.write_at(1, action_row, "ZUG: " .. tostring(self.selected):sub(1, w-6), C.white, C.blue)
      u.fill_line(action_row, C.blue, w)
      u.write_at(1, action_row, "AUSGEWAEHLT: " .. tostring(self.selected):sub(1, w-14), C.white, C.blue)
      action_row = action_row + 1
      for _, act in ipairs(ACTIONS) do
        local fg = act.fg and act.fg(self.selected) or C.white
        local bg = act.bg and act.bg(self.selected) or C.black
        u.write_at(act.x, action_row, act.label, fg, bg)
      end
      action_row = action_row + 1
      -- Action result
      if self.action_result and (os.clock() - self.action_result_ts) < 5 then
        u.write_at(1, action_row, tostring(self.action_result):sub(1,w), C.lime)
      else
        u.write_at(1, action_row, "Antippen=Aktion auswaehlen", C.lightGray)
      end
    else
      u.separator(action_row, w)
      u.write_at(1, action_row+1, "Zug antippen fuer Steuerungsoptionen", C.lightGray)
    end

    u.footer(h, string.format("Zeile antippen=auswaehlen  %d/%d Zuege", math.min(self.offset+1, #sorted), #sorted), w)
  end

  function self.touch(x, y)
    local _, h = u_size_or(51, 19)
    local sorted = get_sorted()

    -- Touch in action row area when train selected
    if self.selected and y >= h - 4 and y == h - 2 then
      -- Determine which button was pressed by x position
      for _, act in ipairs(ACTIONS) do
        if x >= act.x and x < act.x + act.w then
          exec_action(act.key)
          return
        end
      end
      -- Touch on selected train header → deselect
      if y == h - 3 then exec_action("deselect") end
      return
    end

    -- Touch in train list: each train = 2 rows starting from row 3
    if y >= 3 and y <= h - 5 then
      local start = self.offset + 1
      local idx = math.ceil((y - 2) / 2) + self.offset
      if idx >= 1 and idx <= #sorted then
        local entry = sorted[idx]
        if self.selected == entry.id then
          self.selected = nil  -- deselect if same train
        else
          self.selected = entry.id
          self.action_result = nil
        end
      end
      return
    end

    -- Scroll footer area
    if y == h then
      self.offset = math.max(0, self.offset - 1)
    end
  end

  -- Helper so touch can get size without monitor ref
  function u_size_or(dw, dh) return dw, dh end

  return self
end

return trains_panel
