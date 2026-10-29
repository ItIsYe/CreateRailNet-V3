--[[
Purpose: Bausteine fuer Seiten: Beschriftung, Taste, Zustandsmarke, Liste mit Seiten (Auswahl bleibt beim Blaettern), Eingabefeld, Textumbruch. Jede Taste und jede Listenzeile bekommt einen Beruehrungsbereich; Zustaende stehen immer auch als Text.
API: W.label(v, x, y, text, kind, maxw); W.badge(v, x, y, text, kind) -> Breite; W.button(v, id, x, y, w, h, label, opts); W.list(v, id, rect, items, state, opts) -> sichtbare Zeilen; W.field(v, id, x, y, w, label, state); W.wrap(text, width) -> Zeilen
Notes: v ist eine Ansicht (ui/view.lua). kind: "text", "dim", "hell", "ok", "wait", "attention", "halt", "info". Listen: state = { index = 1, offset = 0 }; Zeilenhoehe 3 im grossen, 1 im kompakten Layout.
]]

local palette = require("ui.palette")
local S = palette.SLOT

local W = {}

local KIND_FG = { text = S.text, dim = S.gedaempft, hell = S.hell, ok = S.ok, wait = S.wartend, attention = S.achtung, halt = S.halt, info = S.auswahl }
local KIND_BG = { ok = S.ok, wait = S.wartend, attention = S.achtung, halt = S.halt, info = S.haupt, primary = S.haupt, secondary = S.trenner, danger = S.halt }

function W.label(v, x, y, text, kind, maxw)
  v.canvas.text(x, y, text, KIND_FG[kind or "text"] or S.text, nil, maxw)
end

function W.badge(v, x, y, text, kind)
  local label = " " .. text .. " "
  local bg = KIND_BG[kind or "info"] or S.haupt
  local fg = (kind == "wait") and S.hintergrund or S.hell
  return v.canvas.text(x, y, label, fg, bg)
end

function W.wrap(text, width)
  local lines = {}
  for paragraph in (tostring(text) .. "\n"):gmatch("(.-)\n") do
    local line = ""
    for word in paragraph:gmatch("%S+") do
      while #word > width do
        if line ~= "" then lines[#lines + 1] = line; line = "" end
        lines[#lines + 1] = word:sub(1, width)
        word = word:sub(width + 1)
      end
      if line == "" then line = word
      elseif #line + 1 + #word <= width then line = line .. " " .. word
      else lines[#lines + 1] = line; line = word end
    end
    lines[#lines + 1] = line
  end
  while #lines > 1 and lines[#lines] == "" do lines[#lines] = nil end
  return lines
end

-- Taste: gefuelltes Rechteck mit mittiger Beschriftung; gesperrte Tasten sind gedaempft und nennen ihren Grund
function W.button(v, id, x, y, w, h, label, opts)
  opts = opts or {}
  local enabled = opts.enabled ~= false
  local kind = opts.kind or "primary"
  local bg = enabled and (KIND_BG[kind] or S.haupt) or S.trenner
  if v.focus_id == id and enabled then bg = S.auswahl end
  v.canvas.fill(x, y, w, h, bg)
  local fg = enabled and S.hell or S.gedaempft
  local text = label
  if #text > w - 2 then text = text:sub(1, math.max(1, w - 3)) .. "~" end
  local tx = x + math.max(0, math.floor((w - #text) / 2))
  v.canvas.text(tx, y + math.floor((h - 1) / 2), text, fg, bg)
  v.touch.add(id, x, y, w, h, { enabled = enabled, reason = opts.reason })
  v.add_focus(id, enabled)
end

-- Liste: Auswahl bleibt sichtbar, Seitenwechsel ueber Tasten "<" und ">" am Fuss; items = { { text, detail, kind }, ... }
function W.list(v, id, rect, items, state, opts)
  opts = opts or {}
  local row_h = opts.row_h or (v.layout.mode == "gross" and 3 or 1)
  local footer = 1
  local per_page = math.max(1, math.floor((rect.h - footer) / row_h))
  state.index = math.max(1, math.min(state.index or 1, math.max(1, #items)))
  local page = math.floor((state.index - 1) / per_page)
  state.offset = page * per_page
  local pages = math.max(1, math.ceil(#items / per_page))
  v.lists[id] = { state = state, per_page = per_page, count = #items }
  v.list_order[#v.list_order + 1] = id
  v.canvas.fill(rect.x, rect.y, rect.w, rect.h, S.arbeit)
  if #items == 0 then
    v.canvas.text(rect.x + 1, rect.y, opts.empty or "(leer)", S.gedaempft, S.arbeit, rect.w - 2)
  end
  for row = 1, per_page do
    local i = state.offset + row
    local item = items[i]
    if not item then break end
    local y = rect.y + (row - 1) * row_h
    local selected = (i == state.index)
    local bg = selected and S.zeile or S.arbeit
    v.canvas.fill(rect.x, y, rect.w, row_h, bg)
    local mark = selected and "> " or "  "
    local title_y = y + math.floor((row_h - 1) / 2)
    local detail = item.detail
    local room = rect.w - 2
    if detail and row_h == 1 then
      local dw = math.min(#detail, math.floor(room / 2))
      v.canvas.text(rect.x + room - dw + 2, title_y, detail, KIND_FG[item.kind or "dim"] or S.gedaempft, bg, dw)
      room = room - dw - 1
      v.canvas.text(rect.x, title_y, mark .. item.text, selected and S.hell or S.text, bg, room + 2)
    else
      v.canvas.text(rect.x, title_y, mark .. item.text, selected and S.hell or S.text, bg, rect.w)
      if detail and row_h >= 2 then v.canvas.text(rect.x + 2, title_y + 1, detail, KIND_FG[item.kind or "dim"] or S.gedaempft, bg, rect.w - 2) end
    end
    v.touch.add("sel:" .. id .. ":" .. i, rect.x, y, rect.w, row_h)
  end
  local fy = rect.y + rect.h - 1
  v.canvas.fill(rect.x, fy, rect.w, 1, S.arbeit)
  v.canvas.text(rect.x + 2, fy, string.format("Seite %d/%d  (%d Eintraege)", page + 1, pages, #items), S.gedaempft, S.arbeit, rect.w - 4)
  if pages > 1 then
    v.canvas.text(rect.x + rect.w - 7, fy, " < > ", S.hell, S.haupt)
    v.touch.add("page:" .. id .. ":prev", rect.x + rect.w - 7, fy, 3, 1)
    v.touch.add("page:" .. id .. ":next", rect.x + rect.w - 4, fy, 3, 1)
  end
  return math.min(per_page, math.max(0, #items - state.offset)), per_page
end

-- Eingabefeld: state = { value = "", focused = false }
function W.field(v, id, x, y, w, label, state)
  local focused = v.input_id == id
  v.fields[id] = state
  v.canvas.text(x, y, label, focused and S.hell or S.gedaempft, S.arbeit, w)
  local fy = y + 1
  v.canvas.fill(x, fy, w, 1, focused and S.zeile or S.trenner)
  local shown = tostring(state.value or "")
  local room = w - 2
  if #shown > room then shown = "~" .. shown:sub(#shown - room + 2) end
  v.canvas.text(x + 1, fy, shown .. (focused and "_" or ""), S.hell, focused and S.zeile or S.trenner, w - 1)
  v.touch.add("field:" .. id, x, fy, w, 1)
end

return W
