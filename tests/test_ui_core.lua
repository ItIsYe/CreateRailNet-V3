--[[
Purpose: Zeichenkern der Oberflaeche (src/ui): Palette, Zeichenflaeche mit Kuerzung und Ausgabe, Layout nach Groesse, Beruehrungsbereiche.
]]

local t = dofile("tests/lib/t.lua")
local screenlib = dofile("tests/fakes/screen.lua")
local palette = require("ui.palette")
local canvaslib = require("ui.canvas")
local layout = require("ui.layout")
local touchlib = require("ui.touch")

return {
  { "Palette: 16 Plaetze, Farben gueltig, Hex-Zeichen und CC-Farbe passen zusammen", function()
    local count = 0
    for name, slot in pairs(palette.SLOT) do
      count = count + 1
      local rgb = palette.RGB[slot]
      t.ok(rgb, "Farbe fuer " .. name)
      for i = 1, 3 do t.ok(rgb[i] >= 0 and rgb[i] <= 1, "Wert fuer " .. name) end
    end
    t.eq(count, 16)
    t.eq(palette.hex(1), "0"); t.eq(palette.hex(16), "f")
    t.eq(palette.colour(1), 1); t.eq(palette.colour(16), 32768)
  end },
  { "Palette wird nur auf Farbgeraeten gesetzt", function()
    local colour = screenlib.new(10, 3)
    t.eq(palette.apply(colour), true)
    t.eq(colour.palette[1][1], palette.RGB[1][1])
    local mono = screenlib.new(10, 3, { colour = false })
    t.eq(palette.apply(mono), false)
    t.eq(next(mono.palette), nil)
    t.eq(palette.apply({}), false)
  end },
  { "Text, Kuerzung mit Hinweis, Begrenzung am Rand, Sonderzeichen", function()
    local c = canvaslib.new(10, 3)
    t.eq(c.text(1, 1, "Hallo", 6, 1), 5)
    t.eq(c.text(1, 2, "Ein langer Name", 6, 1, 8), 8)
    t.eq(c.text(8, 3, "ueberlauf", 6, 1), 3)
    t.eq(c.text(1, 9, "x", 6, 1), 0, "ausserhalb")
    t.eq(c.text(1, 1, "ae\200", 6, 1), 3)
    local rows = c.rows()
    t.eq(rows[1], "ae?lo     ")
    t.eq(rows[2], "Ein lan~  ")
    t.eq(rows[3], "       ue~")
  end },
  { "Flaeche fuellen, Zelle lesen", function()
    local c = canvaslib.new(6, 4)
    c.fill(2, 2, 3, 2, 8)
    local _, _, bg = c.cell(2, 2)
    t.eq(bg, 8)
    local _, _, outside = c.cell(1, 1)
    t.eq(outside, palette.SLOT.hintergrund)
    c.fill(-5, -5, 100, 100, 3)
    t.eq(select(3, c.cell(6, 4)), 3, "Fuellung wird am Rand begrenzt")
  end },
  { "flush: erst alles, dann nur geaenderte Zeilen", function()
    local c = canvaslib.new(10, 3)
    local s = screenlib.new(10, 3)
    c.text(1, 1, "Zeile eins", 7, 2)
    c.flush(s)
    t.eq(s.rows()[1], "Zeile eins")
    t.eq(s.writes, 3, "drei Zeilen mit blit")
    c.flush(s)
    t.eq(s.writes, 3, "nichts geaendert, nichts geschrieben")
    c.text(1, 3, "neu", 7, 2)
    c.flush(s)
    t.eq(s.writes, 4, "nur die geaenderte Zeile")
    t.eq(s.rows()[3]:sub(1, 3), "neu")
    c.invalidate()
    c.flush(s)
    t.eq(s.writes, 7)
  end },
  { "flush mit Farben: Palettenplatz kommt als CC-Farbe an", function()
    local c = canvaslib.new(4, 1)
    local s = screenlib.new(4, 1)
    c.fill(1, 1, 4, 1, palette.SLOT.haupt)
    c.text(1, 1, "ab", palette.SLOT.hell, palette.SLOT.haupt)
    c.flush(s)
    local ch, fg, bg = s.cell(1, 1)
    t.eq(ch, "a")
    t.eq(fg, palette.colour(palette.SLOT.hell))
    t.eq(bg, palette.colour(palette.SLOT.haupt))
  end },
  { "flush ohne blit: gleiche Farben werden zusammen geschrieben", function()
    local c = canvaslib.new(8, 1)
    local s = screenlib.new(8, 1, { blit = false })
    c.text(1, 1, "abcd", 7, 2)
    c.flush(s)
    t.eq(s.rows()[1], "abcd    ")
    t.ok(s.writes <= 3, "Farbwechsel statt Zeichen fuer Zeichen: " .. s.writes)
    local _, fg = s.cell(1, 1)
    t.eq(fg, palette.colour(7))
  end },
  { "Monochrom: dunkle Flaechen schwarz, helle weiss, Text bleibt lesbar", function()
    local c = canvaslib.new(6, 2, { mono = true })
    local s = screenlib.new(6, 2, { colour = false })
    c.fill(1, 1, 6, 1, palette.SLOT.navigation)
    c.text(1, 1, "Menu", palette.SLOT.hell, palette.SLOT.navigation)
    c.fill(1, 2, 6, 1, palette.SLOT.haupt)
    c.text(1, 2, "Los", palette.SLOT.hell, palette.SLOT.haupt)
    c.flush(s)
    t.eq(s.rows()[1]:sub(1, 4), "Menu")
    local _, fg1, bg1 = s.cell(1, 1)
    t.ok(fg1 ~= bg1, "Vordergrund und Hintergrund unterscheiden sich")
    local _, fg2, bg2 = s.cell(1, 2)
    t.ok(fg2 ~= bg2)
  end },
  { "Layout nach Groesse (Konzept 28.2 und 29.4)", function()
    local big = layout.compute(100, 40)
    t.eq(big.mode, "gross")
    t.eq(big.nav.w, 20); t.eq(big.action_row_h, 3); t.eq(big.nav_row_h, 3)
    t.eq(layout.compute(120, 50).mode, "gross")
    local compact = layout.compute(51, 19)
    t.eq(compact.mode, "kompakt")
    t.ok(compact.action_row_h >= 2)
    t.eq(layout.compute(99, 40).mode, "kompakt", "knapp unter 100 Spalten: kompakt")
    t.eq(layout.compute(100, 39).mode, "kompakt")
    t.eq(layout.compute(50, 19).mode, "status")
    t.eq(layout.compute(51, 18).mode, "status")
    t.eq(layout.compute(20, 5).mode, "status")
  end },
  { "Layout: Bereiche liegen innerhalb der Flaeche und ueberlappen nicht", function()
    for _, size in ipairs({ { 100, 40 }, { 120, 50 }, { 51, 19 }, { 80, 30 } }) do
      local l = layout.compute(size[1], size[2])
      local names = { "header", "nav", "work", "hint", "actions" }
      for _, n in ipairs(names) do
        local r = l[n]
        t.ok(r.x >= 1 and r.y >= 1 and r.x + r.w - 1 <= size[1] and r.y + r.h - 1 <= size[2], n .. " ausserhalb bei " .. size[1] .. "x" .. size[2])
      end
      for i = 1, #names do
        for j = i + 1, #names do
          local a, b = l[names[i]], l[names[j]]
          local overlap = a.x < b.x + b.w and b.x < a.x + a.w and a.y < b.y + b.h and b.y < a.y + a.h
          t.ok(not overlap, names[i] .. " ueberlappt " .. names[j] .. " bei " .. size[1] .. "x" .. size[2])
        end
      end
    end
  end },
  { "Beruehrung: Treffer, nichts, spaeter hinzugefuegt gewinnt, gesperrt mit Grund", function()
    local tc = touchlib.new()
    tc.add("a", 1, 1, 10, 3)
    tc.add("b", 5, 2, 3, 1)
    tc.add("gesperrt", 20, 1, 5, 2, { enabled = false, reason = "Zug fehlt" })
    t.eq(tc.hit(1, 1).id, "a")
    t.eq(tc.hit(5, 2).id, "b")
    t.eq(tc.hit(8, 2).id, "a")
    t.eq(tc.hit(11, 1), nil)
    t.eq(tc.hit(0, 0), nil)
    local g = tc.hit(21, 2)
    t.eq(g.enabled, false)
    t.eq(g.reason, "Zug fehlt")
    tc.reset()
    t.eq(tc.hit(1, 1), nil)
  end },
}
