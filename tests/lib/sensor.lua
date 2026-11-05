--[[
Purpose: Fuehler fuer die Darstellung: waehrend ein Ablauf laeuft, werden an Zeichenflaeche und Beruehrungsflaechen Auffaelligkeiten notiert: Text, der abgeschnitten oder mit ~ gekuerzt wird; Text, der anderen Text uebermalt; eine Flaeche, die Text verdeckt; zwei Beruehrungsflaechen, die sich ueberlappen (Tasten uebereinander). Der Quelltext der Oberflaeche bleibt unveraendert.
API: sensor.collect(fn, filter) -> Liste { kind, detail, screen }; filter(rows) -> true, wenn das Bild gezaehlt werden soll (zum Beispiel nur Einrichtungsbilder)
Notes: Greift in ui.canvas.new und ui.touch.new ein, solange fn laeuft, und stellt beides danach wieder her (auch bei einem Fehler in fn). Jede Auffaelligkeit wird je Art und Text einmal gemeldet.
]]

local canvas = require("ui.canvas")
local touch = require("ui.touch")

local M = {}

function M.collect(fn, filter)
  local found, seen = {}, {}
  local function emit(kind, detail, rows, always)
    if filter and not always and not filter(rows or {}) then return end
    local key = kind .. "|" .. detail
    if seen[key] then return end
    seen[key] = true
    found[#found + 1] = { kind = kind, detail = detail, screen = table.concat(rows or {}, "\n") }
  end

  local orig_canvas, orig_touch = canvas.new, touch.new

  canvas.new = function(w, h, opts)
    local c = orig_canvas(w, h, opts)
    local written, anoms, framing = {}, {}, false
    local o_clear, o_fill, o_text, o_flush = c.clear, c.fill, c.text, c.flush
    function c.clear(back) written, anoms, framing = {}, {}, true; return o_clear(back) end
    function c.fill(x, y, fw, fh, back)
      if framing then
        local lost
        for yy = math.max(1, y), math.min(h, y + fh - 1) do
          for xx = math.max(1, x), math.min(w, x + fw - 1) do
            local ch = written[yy .. ":" .. xx]
            if ch and ch ~= " " then lost = (lost or "") .. ch end
          end
        end
        if lost then anoms[#anoms + 1] = { "Flaeche verdeckt Text", "'" .. lost:sub(1, 30) .. "'" } end
      end
      return o_fill(x, y, fw, fh, back)
    end
    function c.text(x, y, text, fore, back, maxw)
      text = tostring(text)
      local limit = math.min(maxw or (w - x + 1), w - x + 1)
      if y >= 1 and y <= h and limit > 0 then
        if #text > limit then anoms[#anoms + 1] = { "abgeschnitten", "'" .. text:sub(1, 60) .. "'" } end
        -- schon vom Programm mit "~" gekuerzt (W.fit): im Arbeitsbereich und im Hinweis ist auch das ein Fehler, nur die Kopfzeile darf kuerzen
        if y >= 3 and #text > 3 and text:sub(-1) == "~" and text:sub(-2, -2):match("[%w%.%)%(,]") then anoms[#anoms + 1] = { "gekuerzt", "'" .. text:sub(1, 60) .. "'" } end
        local clash
        for i = 1, math.min(#text, limit) do
          local key = y .. ":" .. (x + i - 1)
          local ch = text:sub(i, i)
          if written[key] and written[key] ~= " " and ch ~= " " then clash = true end
          written[key] = ch
        end
        if clash then anoms[#anoms + 1] = { "Text ueberschreibt Text", "'" .. text:sub(1, 40) .. "' (Zeile " .. y .. ")" } end
      end
      return o_text(x, y, text, fore, back, maxw)
    end
    function c.flush(target)
      if #anoms > 0 and framing then
        local rows = c.rows()
        for _, a in ipairs(anoms) do emit(a[1], a[2], rows) end
      end
      return o_flush(target)
    end
    return c
  end

  touch.new = function()
    local tc = orig_touch()
    local o_add = tc.add
    function tc.add(id, x, y, w, h, opts)
      for _, a in ipairs(tc.areas) do
        if x < a.x + a.w and a.x < x + w and y < a.y + a.h and a.y < y + h then
          emit("Flaechen ueberlappen", tostring(id) .. " und " .. tostring(a.id), {}, true)
        end
      end
      return o_add(id, x, y, w, h, opts)
    end
    return tc
  end

  local ok, err = pcall(fn)
  canvas.new, touch.new = orig_canvas, orig_touch
  if not ok then error(err, 0) end
  return found
end

return M
