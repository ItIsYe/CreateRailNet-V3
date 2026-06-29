--[[
Purpose: Depot panel with interactive track control — dispatch, stage, clear.
]]

local ui_utils = require("src.master.ui.ui_utils")
local depots_panel = {}

local TRACK_LABELS = {
  EMPTY="FREI", OCCUPIED="BESETZT", STAGING="STAGING",
  READY="BEREIT", DEPARTING="ABFAHRT", FAULT="STOERUNG"
}

function depots_panel.new(depot_registry, manual_control_ref, network_ref)
  local self = { offset=0, selected=nil, sel_depot=nil, action_result=nil, action_ts=0 }
  local C = ui_utils.colors

  local function get_sorted()
    local depots = depot_registry and depot_registry.list() or {}
    local sorted = {}
    for id, d in pairs(depots) do table.insert(sorted, {id=id, d=d}) end
    table.sort(sorted, function(a,b) return a.id < b.id end)
    return sorted
  end

  local function exec_action(action, depot_id, track_id)
    if not network_ref then self.action_result = "Kein Netz"; self.action_ts = os.clock(); return end
    if action == "dispatch" then
      network_ref.send_reliable("cmd", depot_id, { cmd="dispatch_train", track_id=track_id })
      self.action_result = "Abgefahren: " .. tostring(track_id)
    elseif action == "stage" then
      network_ref.send_reliable("cmd", depot_id, { cmd="stage_train", track_id=track_id })
      self.action_result = "Staging: " .. tostring(track_id)
    elseif action == "clear" then
      network_ref.send_reliable("cmd", depot_id, { cmd="clear_track", track_id=track_id })
      self.action_result = "Geleert: " .. tostring(track_id)
    elseif action == "ready" then
      network_ref.send_reliable("cmd", depot_id, { cmd="mark_ready", track_id=track_id })
      self.action_result = "Bereit markiert: " .. tostring(track_id)
    elseif action == "deselect" then
      self.selected = nil; self.sel_depot = nil; self.action_result = nil; return
    end
    self.action_ts = os.clock()
  end

  local TRACK_ACTIONS = {
    { x=1,  label="[ABFAHREN ]", key="dispatch", fg=function() return C.lime end },
    { x=13, label="[ BEREIT  ]", key="ready",    fg=function() return C.cyan end },
    { x=25, label="[STAGING  ]", key="stage",    fg=function() return C.yellow end },
    { x=37, label="[ LEEREN  ]", key="clear",    fg=function() return C.orange end },
    { x=49, label="[X]",         key="deselect", fg=function() return C.lightGray end },
  }

  function self.draw(monitor)
    if not monitor then return end
    local u = ui_utils.new(monitor)
    local w, h = u.size()
    u.clear(C.black)
    u.header(1, "ABSTELLANLAGEN", nil, w)

    local sorted = get_sorted()
    if #sorted == 0 then
      u.write_at(3, 4, "Kein Depot registriert.", C.lightGray)
      u.footer(h, "Warte auf Depot-Verbindung...", w)
      return
    end

    u.fill_line(2, C.gray, w)
    u.write_at(1, 2, string.format("%-18s %-10s %-14s", "DEPOT/GLEIS", "ZUSTAND", "ZUG"), C.white, C.gray)

    local row = 3
    local start = self.offset + 1

    for i = start, #sorted do
      if row > h - 5 then break end
      local entry = sorted[i]
      local d = entry.d
      local d_online = (d.state == "ONLINE")
      local is_sel_depot = (self.sel_depot == entry.id)

      u.fill_line(row, is_sel_depot and C.blue or C.black, w)
      u.write_at(1, row, (d_online and "■" or "□") .. " ", d_online and C.lime or C.gray, is_sel_depot and C.blue or C.black)
      u.write_at(3, row, tostring(entry.id):sub(1,15), C.white, is_sel_depot and C.blue or C.black)
      u.write_at(19, row, tostring(d.state or "-"):sub(1,8), d_online and C.lime or C.gray, is_sel_depot and C.blue or C.black)
      local qlen = #(d.queue or {})
      if qlen > 0 then u.write_at(w-7, row, "Q:" .. qlen, C.yellow, is_sel_depot and C.blue or C.black) end
      row = row + 1

      local tracks = {}
      for tid, t in pairs(d.tracks or {}) do table.insert(tracks, {id=tid, t=t, did=entry.id}) end
      table.sort(tracks, function(a,b) return a.id < b.id end)

      for _, te in ipairs(tracks) do
        if row > h - 5 then break end
        local t = te.t
        local is_sel = (self.selected == te.id and self.sel_depot == entry.id)
        local row_bg = is_sel and C.purple or C.black
        local state_col = (ui_utils.STATE_COLORS[tostring(t.state)] or {fg=C.lightGray}).fg
        local track_label = TRACK_LABELS[tostring(t.state)] or tostring(t.state or "?")

        u.fill_line(row, row_bg, w)
        u.write_at(3, row, "  " .. tostring(te.id):sub(1,5), C.lightGray, row_bg)
        u.state_badge(9, row, t.state)
        u.write_at(14, row, track_label:sub(1,8), state_col, row_bg)
        local train_str = tostring(t.train_name or t.train_id or ""):sub(1,13)
        if train_str ~= "" then u.write_at(23, row, train_str, C.yellow, row_bg) end
        local route = tostring(t.route_id or ""):sub(1,8)
        if route ~= "" then u.write_at(w-#route-1, row, route, C.cyan, row_bg) end
        row = row + 1
      end

      if row <= h - 5 and i < #sorted then
        u.fill_line(row, C.black, w); u.write_at(1, row, string.rep("-", w), C.gray); row = row + 1
      end
    end

    -- Action bar
    if self.selected and self.sel_depot then
      u.separator(h-4, w)
      u.fill_line(h-3, C.purple, w)
      u.write_at(1, h-3, "GLEIS: " .. self.sel_depot .. "/" .. self.selected, C.white, C.purple)
      for _, act in ipairs(TRACK_ACTIONS) do
        if act.x + #act.label <= w + 1 then
          u.write_at(act.x, h-2, act.label, act.fg())
        end
      end
      if self.action_result and (os.clock() - self.action_ts) < 5 then
        u.write_at(1, h-1, tostring(self.action_result):sub(1,w), C.lime)
      else
        u.write_at(1, h-1, "Aktion antippen", C.lightGray)
      end
    else
      u.separator(h-4, w)
      u.write_at(1, h-3, "Gleis antippen fuer Steuerung", C.lightGray)
    end

    u.footer(h, string.format("Scroll  %d/%d Depots", math.min(self.offset+1, #sorted), #sorted), w)
  end

  function self.touch(x, y)
    local sorted = get_sorted()
    local _, h = 51, 19

    if self.selected and y == h-2 then
      for _, act in ipairs(TRACK_ACTIONS) do
        if x >= act.x and x < act.x + #act.label then
          exec_action(act.key, self.sel_depot, self.selected)
          return
        end
      end
    end

    if y >= 3 and y <= h-5 then
      local row = 3
      local start = self.offset + 1
      for i = start, #sorted do
        if row > h - 5 then break end
        local entry = sorted[i]
        if y == row then
          if self.sel_depot == entry.id then self.sel_depot = nil; self.selected = nil
          else self.sel_depot = entry.id; self.selected = nil end
          return
        end
        row = row + 1
        local tracks = {}
        for tid, t in pairs(entry.d.tracks or {}) do table.insert(tracks, {id=tid}) end
        table.sort(tracks, function(a,b) return a.id < b.id end)
        for _, te in ipairs(tracks) do
          if y == row then
            if self.selected == te.id and self.sel_depot == entry.id then
              self.selected = nil; self.sel_depot = nil
            else
              self.selected = te.id; self.sel_depot = entry.id
            end
            self.action_result = nil; return
          end
          row = row + 1
          if row > h-5 then break end
        end
        row = row + 1
      end
    end
    if y > 10 then self.offset = self.offset + 1 else self.offset = math.max(0, self.offset-1) end
  end

  return self
end

return depots_panel
