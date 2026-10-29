--[[
Purpose: Eine Ansicht auf einem Ausgabegeraet (Terminal oder Monitor): zeichnet Kopfzeile, Navigation, Arbeitsbereich, Hinweis und Aktionen nach dem Layout der aktuellen Groesse, nimmt Beruehrung, Maus und Tastatur entgegen und gibt Aktionen an die Seite weiter. Jede Ansicht hat ihren eigenen Zustand (aktuelle Seite, Auswahl, Eingabe); mehrere Ansichten zeigen dieselben Daten.
API: view.new{ target, name, ctx, pages } -> v; v.render(); v.handle(event) -> true wenn verarbeitet; v.set_page(id); v.hint; v.page_state(id) -> Tabelle
Notes: ctx = { title() -> Text, status() -> { text, kind }, on_action(v, id) }. Seite = { id, title, render(v, rect), actions(v) -> Liste { id, label, kind, enabled, reason, side = "rechts" fuer die feste Gruppe rechts }, on_action(v, id) -> true wenn behandelt, on_key(v, name), visible(v) }; sonst geht die Aktion an ctx.on_action. Nach einer Groessenaenderung werden Layout und Klickbereiche neu berechnet; Eingaben bleiben erhalten. Eine gesperrte Taste sendet nichts und zeigt ihren Grund im Hinweis.
]]

local palette = require("ui.palette")
local canvaslib = require("ui.canvas")
local layout = require("ui.layout")
local touchlib = require("ui.touch")
local keymap = require("ui.keymap")
local W = require("ui.widgets")
local S = palette.SLOT

local M = {}

function M.new(opts)
  local v = { target = opts.target, name = opts.name, ctx = opts.ctx, pages = opts.pages, hint = "" }
  v.touch = touchlib.new()
  v.fields = {}
  v.lists = {}
  v.list_order = {}
  v.focus_list = {}
  local states = {}
  local page_id = opts.pages[1].id
  local size_w, size_h

  function v.page_state(id)
    states[id] = states[id] or { lists = {} }
    return states[id]
  end

  function v.current_page()
    for _, p in ipairs(v.pages) do if p.id == page_id then return p end end
    return v.pages[1]
  end

  function v.visible_pages()
    local out = {}
    for _, p in ipairs(v.pages) do
      if not p.visible or p.visible(v) then out[#out + 1] = p end
    end
    return out
  end

  function v.set_page(id)
    for _, p in ipairs(v.pages) do
      if p.id == id then
        page_id = id
        v.nav_free = false
        v.hint = ""
        v.input_id = nil
        return true
      end
    end
    return false
  end

  function v.add_focus(id, enabled)
    if enabled then v.focus_list[#v.focus_list + 1] = id end
  end

  -- Groesse pruefen; bei Aenderung Flaeche, Layout und Palette neu
  local function sync_size()
    local w, h = v.target.getSize()
    if w ~= size_w or h ~= size_h then
      size_w, size_h = w, h
      local colour = v.target.isColour or v.target.isColor
      local is_colour = colour and colour() or false
      v.canvas = canvaslib.new(w, h, { mono = not is_colour })
      v.layout = layout.compute(w, h)
      if is_colour then palette.apply(v.target) end
    end
  end

  local function draw_status_only()
    local c = v.canvas
    c.clear(S.hintergrund)
    local status = v.ctx.status()
    local lines = { "CRN", v.ctx.title(), status.text, "Zu klein fuer die Bedienung:", "Bediencomputer verwenden." }
    for i, line in ipairs(lines) do
      if i <= v.layout.h then c.text(1, i, line, i == 3 and S.hell or S.text, S.hintergrund, v.layout.w) end
    end
  end

  local function draw_header()
    local r, c = v.layout.header, v.canvas
    c.fill(r.x, r.y, r.w, r.h, S.kopf)
    local row = r.y + math.floor((r.h - 1) / 2)
    local status = v.ctx.status()
    local badge_w = #status.text + 2
    c.text(r.x + 1, row, v.ctx.title(), S.hell, S.kopf, r.w - badge_w - 3)
    W.badge(v, r.x + r.w - badge_w - 1, row, status.text, status.kind)
  end

  local function draw_nav()
    local r, c = v.layout.nav, v.canvas
    local custom = v.current_page().navigation and v.current_page().navigation(v)
    if custom then
      c.fill(r.x, r.y, r.w, r.h, S.navigation)
      if v.layout.mode == "gross" then
        for i, item in ipairs(custom) do
          local y = r.y + (i-1)*4
          c.fill(r.x,y,r.w,3,item.active and S.zeile or S.navigation)
          c.text(r.x+1,y+1,item.title,item.active and S.hell or S.gedaempft,nil,r.w-2)
          if item.active then c.fill(r.x,y,1,3,S.auswahl) end
        end
      else
        for _, item in ipairs(custom) do if item.active then c.text(r.x+1,r.y,item.title,S.hell,nil,r.w-2) end end
      end
      return
    end
    local pages = v.visible_pages()
    c.fill(r.x, r.y, r.w, r.h, S.navigation)
    if v.layout.mode == "gross" then
      for i, p in ipairs(pages) do
        local y = r.y + (i - 1) * v.layout.nav_row_h
        if y + v.layout.nav_row_h - 1 > r.y + r.h - 1 then break end
        local active = (p.id == page_id)
        c.fill(r.x, y, r.w, v.layout.nav_row_h, active and S.haupt or S.navigation)
        c.text(r.x + 2, y + 1, p.title, S.hell, active and S.haupt or S.navigation, r.w - 3)
        v.touch.add("nav:" .. p.id, r.x, y, r.w, v.layout.nav_row_h)
        v.add_focus("nav:" .. p.id, true)
      end
    else
      -- Reiter in einer Zeile; passen nicht alle, blaettern "<" und ">" (die aktuelle Seite bleibt sichtbar)
      local widths, total = {}, 0
      for i, p in ipairs(pages) do widths[i] = #p.title + 2; total = total + widths[i] end
      local first, last = 1, #pages
      if total > r.w then
        local current = 1
        for i, p in ipairs(pages) do if p.id == page_id then current = i end end
        v.nav_offset = math.max(1, math.min(v.nav_offset or 1, #pages))
        if not v.nav_free and current < v.nav_offset then v.nav_offset = current end
        local function fits(from, to)
          local sum = (from > 1 and 3 or 0) + (to < #pages and 3 or 0)
          for i = from, to do sum = sum + widths[i] end
          return sum <= r.w
        end
        while true do
          first = v.nav_offset
          last = first
          while last < #pages and fits(first, last + 1) do last = last + 1 end
          if not v.nav_free and current > last and first < current then v.nav_offset = v.nav_offset + 1 else break end
        end
      end
      local x = r.x
      if first > 1 then
        c.text(x, r.y, " < ", S.hell, S.haupt)
        v.touch.add("navscroll:prev", x, r.y, 3, 1)
        x = x + 3
      end
      for i = first, last do
        local p = pages[i]
        local label = " " .. p.title .. " "
        local active = (p.id == page_id)
        c.text(x, r.y, label, S.hell, active and S.haupt or S.navigation)
        v.touch.add("nav:" .. p.id, x, r.y, #label, 1)
        v.add_focus("nav:" .. p.id, true)
        x = x + #label
      end
      if last < #pages then
        c.text(r.x + r.w - 3, r.y, " > ", S.hell, S.haupt)
        v.touch.add("navscroll:next", r.x + r.w - 3, r.y, 3, 1)
      end
    end
  end

  local function draw_actions()
    local r = v.layout.actions
    local page = v.current_page()
    v.canvas.fill(r.x, r.y, r.w, r.h, S.hintergrund)
    if not page.actions then return end
    if page.id == "einrichtung" then
      local x,y=r.x+1,r.y
      local h=v.layout.action_row_h
      for _, a in ipairs(page.actions(v)) do
        local width=math.min(r.w-2,math.max(8,#a.label+2))
        if x > r.x+1 and x+width > r.x+r.w-1 then x=r.x+1; y=y+h end
        W.button(v,"act:"..a.id,x,y,width,h,a.label,{kind=a.kind or "primary",enabled=a.enabled,reason=a.reason})
        x=x+width+1
      end
      return
    end
    local left, right = {}, {}
    for _, a in ipairs(page.actions(v)) do
      if a.side == "rechts" then right[#right + 1] = a else left[#left + 1] = a end
    end
    local function widths(list, pad)
      local out, total = {}, 0
      for i, a in ipairs(list) do out[i] = math.max(8, #a.label + pad); total = total + out[i] + (i > 1 and 1 or 0) end
      return out, total
    end
    local pad = 4
    local lw, ltotal = widths(left, pad)
    local rw, rtotal = widths(right, pad)
    local gap = (#left > 0 and #right > 0) and 1 or 0
    local two_rows = false
    if ltotal + rtotal + gap + 2 > r.w then
      pad = 2
      lw, ltotal = widths(left, pad)
      rw, rtotal = widths(right, pad)
      if ltotal + rtotal + gap + 2 > r.w then two_rows = (r.h >= 2) end
    end
    local function place(list, w, x, y, h)
      for i, a in ipairs(list) do
        if x + w[i] - 1 > r.x + r.w - 1 then break end
        W.button(v, "act:" .. a.id, x, y, w[i], h, a.label, { kind = a.kind or "primary", enabled = a.enabled, reason = a.reason })
        x = x + w[i] + 1
      end
    end
    if two_rows then
      local h = math.floor(r.h / 2)
      place(left, lw, r.x + 1, r.y, h)
      local start = r.x + r.w - rtotal - 1
      place(right, rw, math.max(r.x + 1, start), r.y + h, h)
    else
      local h = math.min(v.layout.action_row_h, r.h)
      place(left, lw, r.x + 1, r.y, h)
      place(right, rw, math.max(r.x + 1 + ltotal + 1, r.x + r.w - rtotal - 1), r.y, h)
    end
  end

  function v.render()
    sync_size()
    v.touch.reset()
    v.focus_list = {}
    v.lists, v.list_order = {}, {}
    if v.layout.mode == "status" then
      draw_status_only()
    else
      v.layout = layout.compute(size_w, size_h)
      if v.current_page().id == "einrichtung" then
        local actions = v.current_page().actions and v.current_page().actions(v) or {}
        local row_w, rows = 0, 1
        for _, a in ipairs(actions) do
          local aw = math.min(v.layout.actions.w-2, math.max(8,#a.label+2))
          if row_w > 0 and row_w+aw+1 > v.layout.actions.w-2 then rows=rows+1; row_w=0 end
          row_w=row_w+aw+1
        end
        local height=rows*v.layout.action_row_h
        local delta=math.max(0,height-v.layout.actions.h)
        v.layout.actions.y=v.layout.actions.y-delta; v.layout.actions.h=v.layout.actions.h+delta
        v.layout.hint.y=v.layout.hint.y-delta; v.layout.work.h=v.layout.work.h-delta
      end
      local c = v.canvas
      c.clear(S.hintergrund)
      draw_header()
      draw_nav()
      local r = v.layout.work
      c.fill(r.x, r.y, r.w, r.h, S.arbeit)
      v.current_page().render(v, r)
      local hr = v.layout.hint
      c.fill(hr.x, hr.y, hr.w, hr.h, S.hintergrund)
      local text = v.hint
      if text == "" and v.current_page().hint then text = v.current_page().hint(v) or "" end
      for i, line in ipairs(W.wrap(text, hr.w - 2)) do
        if i <= hr.h then c.text(hr.x + 1, hr.y + i - 1, line, S.wartend, S.hintergrund, hr.w - 2) end
      end
      draw_actions()
    end
    if not v.focus_id or not (function() for _, id in ipairs(v.focus_list) do if id == v.focus_id then return true end end end)() then
      v.focus_id = v.focus_list[1]
    end
    v.canvas.flush(v.target)
  end

  local function move_focus(step)
    local n = #v.focus_list
    if n == 0 then return end
    local index = 1
    for i, id in ipairs(v.focus_list) do if id == v.focus_id then index = i end end
    index = ((index - 1 + step) % n) + 1
    v.focus_id = v.focus_list[index]
  end

  local function move_selection(step)
    local id = v.list_order[1]
    if not id then return false end
    local list = v.lists[id]
    local state = list.state
    local new_index = math.max(1, math.min(list.count, (state.index or 1) + step))
    state.index = new_index
    return true
  end

  local function dispatch(id)
    v.hint = ""
    if id:sub(1,4) == "act:" then
      local page = v.current_page()
      for _, action in ipairs(page.actions and page.actions(v) or {}) do
        if "act:" .. action.id == id and action.enabled == false then v.hint = action.reason or "Aktion nicht verfuegbar."; return end
      end
    end
    if id:sub(1, 4) == "nav:" then
      v.set_page(id:sub(5))
      return
    end
    if id == "navscroll:prev" or id == "navscroll:next" then
      v.nav_offset = math.max(1, (v.nav_offset or 1) + (id == "navscroll:next" and 1 or -1))
      v.nav_free = true      -- das Blaettern bleibt stehen, bis eine Seite gewaehlt wird
      return
    end
    local list_id, index = id:match("^sel:(.-):(%d+)$")
    if list_id then
      local list = v.lists[list_id]
      if list then list.state.index = tonumber(index) end
    end
    local pid, dir = id:match("^page:(.-):(%a+)$")
    if pid then
      local list = v.lists[pid]
      if list then
        local step = (dir == "next") and list.per_page or -list.per_page
        list.state.index = math.max(1, math.min(list.count, (list.state.index or 1) + step))
      end
      return
    end
    local field_id = id:match("^field:(.+)$")
    if field_id then
      v.input_id = field_id
      if v.fields[field_id] then v.fields[field_id].fresh = true end   -- das erste Zeichen ersetzt den alten Wert
      return
    end
    local page = v.current_page()
    if page.on_action and page.on_action(v, id) then return end
    if v.ctx.on_action then v.ctx.on_action(v, id) end
  end
  v.dispatch = dispatch

  local function press(x, y)
    local area = v.touch.hit(x, y)
    if not area then return false end
    if not area.enabled then
      v.hint = area.reason or "Diese Aktion ist gerade nicht moeglich."
      return true
    end
    dispatch(area.id)
    return true
  end

  function v.handle(ev)
    local kind = ev[1]
    if kind == "monitor_touch" then
      if v.name and ev[2] == v.name then return press(ev[3], ev[4]) end
      return false
    elseif kind == "mouse_click" then
      if not v.name then return press(ev[3], ev[4]) end
      return false
    elseif kind == "char" then
      local field = v.input_id and v.fields[v.input_id]
      if field then
        if ev[2]:match("^[%w _%.%-:;,/()]$") then
          if field.fresh then field.value = "" field.fresh = nil end
          if #tostring(field.value or "") < (field.max or 40) then field.value = (field.value or "") .. ev[2] end
        end
        return true
      end
      return false
    elseif kind == "key" then
      local name = keymap.name(ev[2])
      local field = v.input_id and v.fields[v.input_id]
      if field then
        if name == "backspace" then
          if field.fresh then field.value = "" field.fresh = nil else field.value = tostring(field.value or ""):sub(1, -2) end
          return true
        end
        if name == "enter" then
          local id = v.input_id
          field.fresh = nil
          v.input_id = nil
          dispatch("input:" .. id)
          return true
        end
        if name == "escape" then v.input_id = nil return true end
        return true
      end
      if name == "tab" then move_focus(1) return true end
      if name == "down" or name == "right" then
        if not move_selection(1) then move_focus(1) end
        return true
      end
      if name == "up" or name == "left" then
        if not move_selection(-1) then move_focus(-1) end
        return true
      end
      if name == "pageDown" or name == "pageUp" then
        local id = v.list_order[1]
        if id then
          local list = v.lists[id]
          local step = (name == "pageDown") and list.per_page or -list.per_page
          list.state.index = math.max(1, math.min(list.count, (list.state.index or 1) + step))
        end
        return true
      end
      if name == "enter" then
        if v.focus_id then dispatch(v.focus_id) return true end
        local id = v.list_order[1]
        if id then dispatch("sel:" .. id .. ":" .. (v.lists[id].state.index or 1)) return true end
        return false
      end
      if name == "escape" then dispatch("back") return true end
      local page = v.current_page()
      if page.on_key then return page.on_key(v, name) end
    end
    return false
  end

  return v
end

return M
