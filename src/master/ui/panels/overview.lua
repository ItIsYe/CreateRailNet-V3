--[[
Purpose: Overview — live block map + node health + global controls (Maintenance, Emergency).
]]

local ui_utils = require("src.master.ui.ui_utils")
local overview = {}

function overview.new(dispatcher, registry, manual_control_ref)
  local panel = { action_result=nil, action_ts=0 }
  local C = ui_utils.colors

  local GLOBAL_ACTIONS = {
    { x=1,  label="[WARTUNG AN ]", key="maint_on",    fg=function() return C.yellow end },
    { x=14, label="[WARTUNG AUS]", key="maint_off",   fg=function() return C.lime end },
    { x=27, label="[NOTFALL ALL]", key="emerg_all",   fg=function() return C.white end, bg=function() return C.red end },
  }

  local function exec_global(action)
    if not manual_control_ref then panel.action_result="Kein Control"; panel.action_ts=os.clock(); return end
    if action == "maint_on" then
      local ok, err = manual_control_ref.handle({action="enter_maintenance", reason="Panel Taste"}, "panel")
      panel.action_result = ok and "Wartungsmodus AKTIV" or ("Fehler: " .. tostring(err))
    elseif action == "maint_off" then
      local ok, err = manual_control_ref.handle({action="exit_maintenance"}, "panel")
      panel.action_result = ok and "Wartungsmodus INAKTIV" or ("Fehler: " .. tostring(err))
    elseif action == "emerg_all" then
      local trains = dispatcher and dispatcher.get_trains and dispatcher.get_trains() or {}
      local count = 0
      for tid, _ in pairs(trains) do
        manual_control_ref.handle({action="emergency_stop", train_id=tid, reason="Globaler Notfall"}, "panel")
        count = count + 1
      end
      panel.action_result = "NOTFALL: " .. count .. " Zuege gestoppt"
    end
    panel.action_ts = os.clock()
  end

  function panel.draw(monitor)
    if not monitor then return end
    local u = ui_utils.new(monitor)
    local w, h = u.size()
    u.clear(C.black)
    u.header(1, "NETZWERK UEBERSICHT", nil, w)

    -- ── Block map ─────────────────────────────────────────────────
    local row = 3
    local bdata = dispatcher and dispatcher.get_overview and dispatcher.get_overview() or {}
    local blocks = {}
    for id, b in pairs(bdata) do table.insert(blocks, {id=id, b=b}) end
    table.sort(blocks, function(a,b) return a.id < b.id end)

    u.write_at(1, row, "BLOECKE", C.cyan); row = row + 1

    local col_w = math.floor(w/2) - 1
    local left, right = row, row
    for i, entry in ipairs(blocks) do
      local b = entry.b
      local tr, tc
      if i % 2 == 1 then tr=left; tc=1; left=left+1
      else tr=right; tc=col_w+2; right=right+1 end
      if tr > h - 8 then break end
      u.state_badge(tc, tr, b.state)
      local bid = tostring(entry.id):sub(1, col_w-6)
      u.write_at(tc+5, tr, bid, C.white)
      local owner = (b.occupied_by or b.reserved_by or ""):sub(1, col_w-#bid-6)
      if owner ~= "" then u.write_at(tc+5+#bid+1, tr, owner, C.yellow) end
    end
    row = math.max(left, right) + 1
    if row > h - 7 then row = h - 7 end

    -- ── Node summary ──────────────────────────────────────────────
    u.separator(row, w); row = row + 1
    local nodes = registry and registry.all and registry.all() or {}
    local up, dn, total = 0, 0, 0
    for _, n in pairs(nodes) do
      total = total + 1
      if n.status == "ONLINE" then up = up + 1 else dn = dn + 1 end
    end
    u.write_at(1, row, "NODES ", C.cyan)
    u.write_at(7, row, "Online:" .. up, C.lime)
    if dn > 0 then u.write_at(18, row, "Offline:" .. dn, C.red) end
    u.write_at(w-9, row, "Total:" .. total, C.lightGray)
    row = row + 1

    -- ── Global controls ───────────────────────────────────────────
    u.separator(row, w); row = row + 1
    u.write_at(1, row, "GLOBALE STEUERUNG", C.cyan); row = row + 1
    for _, act in ipairs(GLOBAL_ACTIONS) do
      local fg = act.fg and act.fg() or C.white
      local bg = act.bg and act.bg() or C.black
      u.write_at(act.x, row, act.label, fg, bg)
    end
    row = row + 1

    -- Action result
    if panel.action_result and (os.clock() - panel.action_ts) < 6 then
      u.write_at(1, row, tostring(panel.action_result):sub(1,w), C.lime)
    end

    u.footer(h, "< Vor | Zurueck >   Tasten antippen", w)
  end

  function panel.touch(x, y)
    local u_tmp = { size = function() return 51, 19 end }
    local _, h = 51, 19

    -- Global action buttons zone
    local btn_row = h - 5
    if y == btn_row then
      for _, act in ipairs(GLOBAL_ACTIONS) do
        if x >= act.x and x < act.x + #act.label then
          exec_global(act.key)
          return
        end
      end
    end
  end

  return panel
end

return overview
