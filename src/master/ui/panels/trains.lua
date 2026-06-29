--[[
Purpose: Train control panel — live train states, routes, schedules, service plan progress.
]]

local ui_utils = require("src.master.ui.ui_utils")
local trains_panel = {}

local STATE_LABELS = {
  OFFLINE = "OFFLINE", REGISTERING = "ANMELDEN", QUEUED = "WARTEND",
  WAITING_FOR_ROUTE = "ROUTE?", ROUTE_ASSIGNED = "ZUGETEILT",
  RUNNING = "FAEHRT", ARRIVING = "ANKUNFT", ARRIVED = "AM ZUG",
  FAULT = "STOERUNG", MAINTENANCE = "WARTUNG", IDLE = "BEREIT",
  DEPART_AUTHORIZED = "ABFAHRT!", WAITING_DEPARTURE = "WARTE",
}

function trains_panel.new(train_registry)
  local self = { offset = 0, selected = nil }
  local C = ui_utils.colors

  function self.draw(monitor)
    if not monitor then return end
    local u = ui_utils.new(monitor)
    local w, h = u.size()

    u.clear(C.black)
    u.header(1, "ZUEGE", nil, w)

    local trains = train_registry and train_registry.list() or {}
    local sorted = {}
    for id, t in pairs(trains) do table.insert(sorted, {id=id, t=t}) end
    table.sort(sorted, function(a, b) return a.id < b.id end)

    if #sorted == 0 then
      u.write_at(3, 4, "Keine Zuege registriert.", C.lightGray)
      u.footer(h, "Warte auf Zug-Verbindung...", w)
      return
    end

    -- Column headers
    u.fill_line(2, C.gray, w)
    u.write_at(1, 2, string.format("%-12s %-12s %-12s %-8s", "ZUG-ID", "STATUS", "ROUTE", "ZIEL"), C.white, C.gray)

    local row = 3
    local start = self.offset + 1

    for i = start, #sorted do
      if row > h - 3 then break end
      local entry = sorted[i]
      local t = entry.t

      -- Highlight selected
      local row_bg = C.black
      if self.selected == entry.id then row_bg = C.blue end

      local state_str = STATE_LABELS[tostring(t.state)] or tostring(t.state or "?")
      local state_col = (ui_utils.STATE_COLORS[tostring(t.state)] or {fg=C.white}).fg

      -- Row 1: ID + state badge + route + destination
      u.fill_line(row, row_bg, w)
      u.state_badge(1, row, t.state)
      local train_name = tostring(t.display_name or entry.id):sub(1, 11)
      u.write_at(6, row, train_name, C.white, row_bg)
      u.write_at(18, row, state_str:sub(1,12), state_col, row_bg)
      local route = tostring(t.route_id or "-"):sub(1, 10)
      u.write_at(31, row, route, C.cyan, row_bg)
      local dest = tostring(t.destination or t.create_destination or "-"):sub(1, w-42)
      u.write_at(42, row, dest, C.yellow, row_bg)
      row = row + 1

      -- Row 2: service plan progress + schedule state
      if row <= h - 3 then
        u.fill_line(row, row_bg, w)
        local plan_str = ""
        if t.service_plan then
          plan_str = "SP:" .. tostring(t.service_plan):sub(1,8)
          if t.service_stop_index then
            plan_str = plan_str .. " #" .. tostring(t.service_stop_index)
          end
        end
        local sched = tostring(t.schedule_state or ""):sub(1, 12)
        local msg = tostring(t.message or ""):sub(1, w - #plan_str - #sched - 8)
        u.write_at(3, row, plan_str, C.purple, row_bg)
        if sched ~= "" then
          u.write_at(3 + #plan_str + 1, row, "Sch:" .. sched, C.lightBlue, row_bg)
        end
        if msg ~= "" then
          u.write_at(w - #msg, row, msg, C.orange, row_bg)
        end
        row = row + 1
      end

      -- Separator between trains
      if row <= h - 3 and i < #sorted then
        u.fill_line(row, C.black, w)
        pcall(monitor.setCursorPos, 1, row)
        pcall(monitor.write, string.rep("-", w))
        row = row + 1
      end
    end

    -- Scroll + touch footer
    u.footer(h, string.format("Antippen=auswaehlen  Oben/Unten scrolling  %d/%d", math.min(self.offset+1, #sorted), #sorted), w)
  end

  function self.touch(x, y)
    -- row 3+ = train rows (2 rows per train + 1 separator)
    if y >= 3 then
      self.offset = math.max(0, self.offset + (y > 11 and 1 or -1))
    end
  end

  return self
end

return trains_panel
