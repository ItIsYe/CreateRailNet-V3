--[[
Purpose: Station panel with interactive platform control.
Touch a platform: Mark Ready to Depart / Clear / Reserve.
]]

local ui_utils = require("src.master.ui.ui_utils")
local stations_panel = {}

local PLAT_LABELS = {
  EMPTY="FREI", DWELLING="DWELL", READY_TO_DEPART="ABFAHRT",
  RESERVED="RESERV", FAULT="STOER", UNKNOWN="?", OCCUPIED="BESETZT"
}

function stations_panel.new(station_registry, manual_control_ref, network_ref, master_id_fn)
  local self = { offset=0, selected=nil, sel_station=nil, action_result=nil, action_ts=0 }
  local C = ui_utils.colors

  local function get_sorted()
    local stations = station_registry and station_registry.list() or {}
    local sorted = {}
    for id, s in pairs(stations) do table.insert(sorted, {id=id, s=s}) end
    table.sort(sorted, function(a,b) return a.id < b.id end)
    return sorted
  end

  local function exec_platform_action(action, station_id, platform_id)
    if not network_ref then self.action_result = "Kein Netz"; self.action_ts = os.clock(); return end
    local master = master_id_fn and master_id_fn() or "MASTER-1"
    if action == "mark_ready" then
      network_ref.send_reliable("cmd", station_id, { cmd="mark_ready_departure", platform_id=platform_id })
      self.action_result = "Abfahrt freigegeben: " .. tostring(platform_id)
    elseif action == "clear" then
      network_ref.send_reliable("cmd", station_id, { cmd="clear_platform", platform_id=platform_id })
      self.action_result = "Plattform geleert: " .. tostring(platform_id)
    elseif action == "deselect" then
      self.selected = nil; self.sel_station = nil; self.action_result = nil; return
    end
    self.action_ts = os.clock()
  end

  local PLAT_ACTIONS = {
    { x=1,  label="[ABFAHRT  ]", key="mark_ready", fg=function() return C.lime end },
    { x=13, label="[ LEEREN  ]", key="clear",       fg=function() return C.yellow end },
    { x=25, label="[  ZURUECK]", key="deselect",    fg=function() return C.lightGray end },
  }

  function self.draw(monitor)
    if not monitor then return end
    local u = ui_utils.new(monitor)
    local w, h = u.size()
    u.clear(C.black)
    u.header(1, "BAHNHOEFE", nil, w)

    local sorted = get_sorted()
    if #sorted == 0 then
      u.write_at(3, 4, "Keine Bahnhoefe registriert.", C.lightGray)
      u.footer(h, "Warte auf Station-Verbindung...", w)
      return
    end

    u.fill_line(2, C.gray, w)
    u.write_at(1, 2, string.format("%-18s %-9s %-14s", "STATION/GLEIS", "ZUSTAND", "ZUG"), C.white, C.gray)

    local row = 3
    local start = self.offset + 1

    for i = start, #sorted do
      if row > h - 5 then break end
      local entry = sorted[i]
      local s = entry.s
      local is_sel_station = (self.sel_station == entry.id)

      -- Station header
      local st_online = (s.state == "ONLINE")
      u.fill_line(row, is_sel_station and C.blue or C.black, w)
      u.write_at(1, row, (st_online and "■" or "□") .. " ", st_online and C.lime or C.gray, is_sel_station and C.blue or C.black)
      u.write_at(3, row, tostring(entry.id):sub(1,15), C.white, is_sel_station and C.blue or C.black)
      u.write_at(19, row, tostring(s.state or "-"):sub(1,8), st_online and C.lime or C.gray, is_sel_station and C.blue or C.black)
      local stype = tostring(s.station_type or "?"):sub(1,6)
      u.write_at(w-#stype, row, stype, C.lightGray, is_sel_station and C.blue or C.black)
      row = row + 1

      -- Platforms
      local plats = {}
      for pid, p in pairs(s.platforms or {}) do table.insert(plats, {id=pid, p=p, sid=entry.id}) end
      table.sort(plats, function(a,b) return a.id < b.id end)

      for _, pe in ipairs(plats) do
        if row > h - 5 then break end
        local p = pe.p
        local is_sel = (self.selected == pe.id and self.sel_station == entry.id)
        local row_bg = is_sel and C.purple or C.black
        local state_col = (ui_utils.STATE_COLORS[tostring(p.state)] or {fg=C.lightGray}).fg
        local plat_label = PLAT_LABELS[tostring(p.state)] or tostring(p.state or "?")

        u.fill_line(row, row_bg, w)
        u.write_at(3, row, "  " .. tostring(pe.id):sub(1,5), C.lightGray, row_bg)
        u.state_badge(9, row, p.state)
        u.write_at(14, row, plat_label:sub(1,8), state_col, row_bg)

        local train_str = tostring(p.train_name or p.train_id or ""):sub(1,13)
        if train_str ~= "" then u.write_at(23, row, train_str, C.yellow, row_bg) end

        -- Dwell progress bar
        if p.state == "DWELLING" and p.occupied_since then
          local elapsed = math.floor(os.clock() - (p.occupied_since or os.clock()))
          local dwell = p.dwell_seconds or 15
          local pct = math.min(1.0, elapsed / math.max(1, dwell))
          local bar_w = math.min(12, w - 38)
          local filled = math.floor(pct * bar_w)
          local bar = "[" .. string.rep("=", filled) .. string.rep("-", bar_w-filled) .. "]"
          local bar_col = pct >= 1.0 and C.lime or C.cyan
          u.write_at(w - #bar - 1, row, bar, bar_col, row_bg)
        end
        row = row + 1
      end

      if row <= h - 5 and i < #sorted then
        u.fill_line(row, C.black, w)
        u.write_at(1, row, string.rep("-", w), C.gray)
        row = row + 1
      end
    end

    -- Action bar
    if self.selected and self.sel_station then
      u.separator(h - 4, w)
      u.fill_line(h-3, C.purple, w)
      u.write_at(1, h-3, "GLEIs: " .. self.sel_station .. "/" .. self.selected, C.white, C.purple)
      for _, act in ipairs(PLAT_ACTIONS) do
        local fg = act.fg and act.fg() or C.white
        u.write_at(act.x, h-2, act.label, fg)
      end
      local result = self.action_result
      if result and (os.clock() - self.action_ts) < 5 then
        u.write_at(1, h-1, tostring(result):sub(1,w), C.lime)
      else
        u.write_at(1, h-1, "Aktion antippen", C.lightGray)
      end
    else
      u.separator(h-4, w)
      u.write_at(1, h-3, "Gleis antippen fuer Aktionen", C.lightGray)
    end

    u.footer(h, string.format("Scroll  %d/%d Bhf", math.min(self.offset+1, #sorted), #sorted), w)
  end

  function self.touch(x, y)
    local sorted = get_sorted()
    local _, h = 51, 19

    -- Action buttons
    if self.selected and y == h - 2 then
      for _, act in ipairs(PLAT_ACTIONS) do
        if x >= act.x and x < act.x + #act.label then
          exec_platform_action(act.key, self.sel_station, self.selected)
          return
        end
      end
    end

    -- Touch in list
    if y >= 3 and y <= h - 5 then
      -- Find which row was touched by iterating
      local row = 3
      local start = self.offset + 1
      for i = start, #sorted do
        if row > h - 5 then break end
        local entry = sorted[i]
        local plats = {}
        for pid, p in pairs(entry.s.platforms or {}) do table.insert(plats, {id=pid, p=p}) end
        table.sort(plats, function(a,b) return a.id < b.id end)

        if y == row then
          -- Station header tapped → select/deselect station
          if self.sel_station == entry.id then
            self.sel_station = nil; self.selected = nil
          else
            self.sel_station = entry.id; self.selected = nil
          end
          return
        end
        row = row + 1

        for _, pe in ipairs(plats) do
          if y == row then
            -- Platform tapped
            if self.selected == pe.id and self.sel_station == entry.id then
              self.selected = nil; self.sel_station = nil
            else
              self.selected = pe.id; self.sel_station = entry.id
            end
            self.action_result = nil
            return
          end
          row = row + 1
          if row > h - 5 then break end
        end
        row = row + 1 -- separator
      end
    end

    if y > h / 2 then self.offset = self.offset + 1
    else self.offset = math.max(0, self.offset - 1) end
  end

  return self
end

return stations_panel
