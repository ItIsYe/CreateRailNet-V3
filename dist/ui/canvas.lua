--[[
Purpose: Zeichenflaeche aus Zellen (Zeichen, Vordergrund, Hintergrund als Palettenplatz) und Ausgabe auf ein Terminal oder einen Monitor: nur geaenderte Zeilen werden geschrieben, mit blit (eine Anweisung je Zeile), sonst mit Farbwechseln. Lange Texte werden sichtbar gekuerzt ("~").
API: canvas.new(w, h, opts) -> c; c.clear(bg), c.fill(x, y, w, h, bg), c.text(x, y, text, fg, bg, maxw) -> Laenge, c.rows() -> Texte, c.cell(x, y), c.flush(target); opts.mono = true: Schwarz/Weiss
Notes: Nur ASCII (Konzept 28.2). Nach einer Groessenaenderung wird eine neue Flaeche angelegt. Auf Monochromgeraeten bleiben Texte und Auswahlmarkierungen erhalten; Hintergruende werden schwarz, Texte weiss.
]]

local palette = require("ui.palette")

local M = {}

local DARK_BG = { [1] = true, [2] = true, [3] = true, [4] = true, [13] = true, [14] = true, [8] = false }

function M.new(w, h, opts)
  opts = opts or {}
  local c = { w = w, h = h, mono = opts.mono }
  local ch, fg, bg = {}, {}, {}
  local sent = nil
  local default_bg, default_fg = palette.SLOT.hintergrund, palette.SLOT.text

  for y = 1, h do
    ch[y], fg[y], bg[y] = {}, {}, {}
    for x = 1, w do ch[y][x], fg[y][x], bg[y][x] = " ", default_fg, default_bg end
  end

  function c.clear(back)
    c.fill(1, 1, w, h, back or default_bg)
  end

  function c.fill(x, y, fw, fh, back)
    for yy = math.max(1, y), math.min(h, y + fh - 1) do
      for xx = math.max(1, x), math.min(w, x + fw - 1) do
        ch[yy][xx], bg[yy][xx] = " ", back
      end
    end
  end

  -- schreibt Text; ueber maxw hinaus wird mit "~" gekuerzt; liefert die geschriebene Laenge
  function c.text(x, y, text, fore, back, maxw)
    if y < 1 or y > h then return 0 end
    text = tostring(text)
    local limit = math.min(maxw or (w - x + 1), w - x + 1)
    if limit <= 0 then return 0 end
    if #text > limit then text = (limit > 1) and (text:sub(1, limit - 1) .. "~") or "~" end
    for i = 1, #text do
      local xx = x + i - 1
      if xx >= 1 and xx <= w then
        local b = text:byte(i)
        ch[y][xx] = (b >= 32 and b < 127) and text:sub(i, i) or "?"
        fg[y][xx] = fore or default_fg
        if back then bg[y][xx] = back end
      end
    end
    return #text
  end

  function c.cell(x, y) return ch[y][x], fg[y][x], bg[y][x] end

  function c.rows()
    local out = {}
    for y = 1, h do out[y] = table.concat(ch[y]) end
    return out
  end

  local function slot_fg(slot)
    if c.mono then return DARK_BG[slot] and 1 or 16 end   -- schwarz/weiss ueber Palettenplatz 1 (CC weiss) und 16 (CC schwarz)
    return slot
  end

  local function row_strings(y)
    local text = table.concat(ch[y])
    local f, b = {}, {}
    for x = 1, w do
      local fs, bs = fg[y][x], bg[y][x]
      if c.mono then
        -- Hintergrund: dunkle Plaetze schwarz, helle weiss; Text jeweils umgekehrt
        local dark = DARK_BG[bs] == true
        b[x] = dark and "f" or "0"
        f[x] = dark and "0" or "f"
        if not dark and DARK_BG[fs] then f[x] = "f" end
      else
        f[x], b[x] = palette.hex(fs), palette.hex(bs)
      end
    end
    return text, table.concat(f), table.concat(b)
  end

  -- schreibt geaenderte Zeilen auf das Ziel (term oder monitor)
  function c.flush(target)
    local resized = (sent == nil)
    for y = 1, h do
      local text, f, b = row_strings(y)
      local key = text .. "|" .. f .. "|" .. b
      if resized or sent[y] ~= key then
        target.setCursorPos(1, y)
        if target.blit then
          target.blit(text, f, b)
        else
          local x = 1
          while x <= w do
            local x2 = x
            while x2 < w and f:sub(x2 + 1, x2 + 1) == f:sub(x, x) and b:sub(x2 + 1, x2 + 1) == b:sub(x, x) do x2 = x2 + 1 end
            local setfg = target.setTextColour or target.setTextColor
            local setbg = target.setBackgroundColour or target.setBackgroundColor
            if setfg then setfg(2 ^ tonumber(f:sub(x, x), 16)) end
            if setbg then setbg(2 ^ tonumber(b:sub(x, x), 16)) end
            target.write(text:sub(x, x2))
            target.setCursorPos(x2 + 1, y)
            x = x2 + 1
          end
        end
        sent = sent or {}
        sent[y] = key
      end
    end
  end

  function c.invalidate() sent = nil end

  return c
end

return M
