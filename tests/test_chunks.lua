--[[
Purpose: Teilen und Zusammensetzen grosser Nachrichten (src/core/chunks.lua): Groessenanpassung, beliebige Reihenfolge, Duplikate, fremde und kaputte Teile, Grenzen, Pruefsumme, Verfall.
]]

local t = dofile("tests/lib/t.lua")
local ser = require("core.ser")
local adler = require("core.adler")
local chunks = require("core.chunks")

local function text_of(n) local out = {} for i = 1, n do out[i] = string.char(97 + (i * 7) % 26) end return table.concat(out) end

local function make_text(sum) return function(piece, i, n) return { kind = "konfig", part = i, parts = n, sum = sum, config = piece } end end

return {
  { "Text wird so geteilt, dass jede kodierte Nutzlast unter dem Limit bleibt, und setzt sich wieder zusammen", function()
    local text = text_of(20000)
    local parts = assert(chunks.parts_text(text, make_text(adler.hex(text)), 5000, ser))
    t.ok(#parts > 1, "mehrere Teile")
    local c = chunks.new({ now = function() return 0 end })
    local result
    for i, p in ipairs(parts) do
      t.ok(#ser.encode(p) <= 5000, "Teil " .. i .. " passt")
      local r, why = c.add("n", "1", p.part, p.parts, p.config, p.sum)
      if i < #parts then t.eq(r, nil); t.eq(why, "offen") else result = r end
    end
    t.eq(result, text)
  end },
  { "Text mit vielen Anfuehrungszeichen und Sonderzeichen wird kleiner geteilt (Maskierung vergroessert die Nachricht)", function()
    local text = string.rep('"\\\n\1', 3000)
    local parts = assert(chunks.parts_text(text, make_text(adler.hex(text)), 5000, ser))
    local c = chunks.new({ max_bytes = 100000, now = function() return 0 end })
    local result
    for _, p in ipairs(parts) do
      t.ok(#ser.encode(p) <= 5000)
      result = c.add("n", "1", p.part, p.parts, p.config, p.sum) or result
    end
    t.eq(result, text)
  end },
  { "Ein Text, der in kein Stueck passt, wird abgelehnt; ein kurzer Text bleibt ein Teil", function()
    local ok, why = chunks.parts_text("x", function(piece) return { config = piece, ballast = string.rep("b", 6000) } end, 5000, ser)
    t.eq(ok, nil); t.contains(why, "nicht in eine Nachricht")
    local one = assert(chunks.parts_text("kurz", make_text("s"), 5000, ser))
    t.eq(#one, 1); t.eq(one[1].parts, 1)
    local empty = assert(chunks.parts_text("", make_text("s"), 5000, ser))
    t.eq(#empty, 1)
  end },
  { "Listen werden geteilt und in der Reihenfolge der Teile zusammengesetzt, auch wenn sie durcheinander ankommen", function()
    local items = {}
    for i = 1, 41 do items[i] = { id = "S" .. i, track = "Gleis " .. (i % 4) } end
    local parts = assert(chunks.parts_list(items, function(piece, i, n) return { kind = "signale", part = i, parts = n, signals = piece } end, 5000, ser))
    t.ok(#parts >= 4)
    local c = chunks.new({ now = function() return 0 end })
    local order = {}
    for i = #parts, 1, -1 do order[#order + 1] = parts[i] end       -- rueckwaerts
    local result
    for _, p in ipairs(order) do result = c.add("n", 7, p.part, p.parts, p.signals) or result end
    t.eq(#result, 41)
    for i = 1, 41 do t.eq(result[i].id, "S" .. i, "Reihenfolge " .. i) end
    -- leere Liste: ein Teil
    local none = assert(chunks.parts_list({}, function(piece, i, n) return { part = i, parts = n, signals = piece } end, 5000, ser))
    t.eq(#none, 1)
    t.eq(#c.add("m", 1, 1, 1, {}), 0)
  end },
  { "Doppelte Teile zaehlen einmal; ein anderer Satz verwirft den angefangenen", function()
    local c = chunks.new({ now = function() return 0 end })
    t.eq(select(2, c.add("n", "a", 1, 3, "AA")), "offen")
    t.eq(select(2, c.add("n", "a", 1, 3, "AA")), "offen")
    t.eq(select(2, c.add("n", "a", 2, 3, "BB")), "offen")
    -- anderer Satz: alter Fortschritt ist weg
    t.eq(select(2, c.add("n", "b", 3, 3, "ZZ")), "offen")
    t.eq(select(2, c.add("n", "a", 3, 3, "CC")), "offen", "Satz a muss von vorn")
    t.eq(select(2, c.add("n", "a", 1, 3, "AA")), "offen")
    local r = c.add("n", "a", 2, 3, "BB")
    t.eq(r, "AABBCC")
    -- fertige Saetze sind abgeraeumt: noch einmal dasselbe Teil beginnt neu
    t.eq(select(2, c.add("n", "a", 1, 3, "AA")), "offen")
  end },
  { "Bei Listen gibt es keine Pruefsumme: eine mitgeschickte Summe wird ignoriert", function()
    local c = chunks.new({ now = function() return 0 end })
    t.eq(select(2, c.add("l", "1", 1, 2, { 1 }, "a")), "offen")
    local r = c.add("l", "1", 2, 2, { 2 }, "b")
    t.ok(r and #r == 2, "wechselnde Summen stoeren Listen nicht")
  end },
  { "Verschiedene Absender (Schluessel) stoeren sich nicht", function()
    local c = chunks.new({ now = function() return 0 end })
    c.add("x", "1", 1, 2, "x1"); c.add("y", "1", 1, 2, "y1")
    t.eq(c.add("x", "1", 2, 2, "x2"), "x1x2")
    t.eq(c.add("y", "1", 2, 2, "y2"), "y1y2")
  end },
  { "Ungueltige Teile werden abgelehnt: Nummern, Satz, Schluessel, Daten, Pruefsumme", function()
    local c = chunks.new({ now = function() return 0 end })
    local function bad(...) local r, why = c.add(...) t.eq(r, nil) t.ok(why and why ~= "offen", tostring(why)) end
    bad("n", "1", 0, 2, "x")
    bad("n", "1", 3, 2, "x")
    bad("n", "1", 1.5, 2, "x")
    bad("n", "1", 1, 0, "x")
    bad("n", "1", 1, 1000, "x")
    bad("n", "1", "1", 2, "x")
    bad("n", "1", 1, 2, 5)
    bad("n", "", 1, 2, "x")
    bad("", "1", 1, 2, "x")
    bad(string.rep("k", 81), "1", 1, 2, "x")
    bad("n", string.rep("s", 41), 1, 2, "x")
    bad("n", nil, 1, 2, "x")
    bad("n", "1", 1, 2, "x", 5)
    bad("n", "1", 1, 2, "x", string.rep("0", 17))
  end },
  { "Pruefsumme: ein verfaelschter Teil wird beim Zusammensetzen erkannt, der Satz ist danach weg", function()
    local c = chunks.new({ now = function() return 0 end })
    local good = adler.hex("AABB")
    c.add("n", "1", 1, 2, "AA", good)
    local r, why = c.add("n", "1", 2, 2, "BX", good)
    t.eq(r, nil); t.contains(why, "Pruefsumme")
    c.add("n", "1", 1, 2, "AA", good)
    t.eq(c.add("n", "1", 2, 2, "BB", good), "AABB", "neuer Versuch gelingt")
    -- wechselnde Summe innerhalb eines Satzes beginnt neu
    c.add("m", "1", 1, 2, "AA", good)
    t.eq(select(2, c.add("m", "1", 2, 2, "BB", adler.hex("anders"))), "offen")
  end },
  { "Grenzen: Bytes, Elemente und Zahl der Schluessel; Text und Liste lassen sich nicht mischen", function()
    local c = chunks.new({ max_bytes = 10, max_items = 3, max_keys = 2, now = function() return 0 end })
    c.add("n", "1", 1, 3, "12345")
    local r, why = c.add("n", "1", 2, 3, "1234567")
    t.eq(r, nil); t.contains(why, "zu gross")
    -- danach beginnt ein neuer Satz sauber
    t.eq(select(2, c.add("n", "1", 1, 3, "12345")), "offen")
    local l, why2 = c.add("l", "1", 1, 2, { 1, 2 })
    t.eq(l, nil); t.eq(why2, "offen")
    local l2, why3 = c.add("l", "1", 2, 2, { 3, 4 })
    t.eq(l2, nil); t.contains(why3, "zu gross")
    -- Schluesselgrenze: der aelteste angefangene Satz weicht
    local now = 0
    local d = chunks.new({ max_keys = 2, now = function() return now end })
    d.add("a", "1", 1, 2, "a1"); now = 1
    d.add("b", "1", 1, 2, "b1"); now = 2
    d.add("c", "1", 1, 2, "c1")
    t.eq(select(2, d.add("a", "1", 2, 2, "a2")), "offen", "a wurde verdraengt")
    t.eq(d.add("c", "1", 2, 2, "c2"), "c1c2")
    -- Text und Liste mischen: der zweite Satz ersetzt den ersten
    local e = chunks.new({ now = function() return 0 end })
    e.add("n", "1", 1, 2, "text")
    t.eq(select(2, e.add("n", "1", 2, 2, { 1 })), "offen")
    local mixed = e.add("n", "1", 1, 2, { 0 })
    t.eq(type(mixed), "table", "der Text von vorher ist verworfen, die Liste setzt sich aus den neuen Teilen zusammen")
    t.eq(#mixed, 2); t.eq(mixed[1], 0); t.eq(mixed[2], 1)
  end },
  { "Unvollstaendige Saetze verfallen nach der Frist", function()
    local now = 0
    local c = chunks.new({ ttl = 10, now = function() return now end })
    c.add("n", "1", 1, 2, "A")
    now = 11
    t.eq(select(2, c.add("n", "1", 2, 2, "B")), "offen", "der alte Teil ist verfallen")
    now = 12
    t.eq(c.add("n", "1", 1, 2, "A"), "AB")
  end },
  { "drop raeumt einen angefangenen Satz weg", function()
    local c = chunks.new({ now = function() return 0 end })
    c.add("n", "1", 1, 2, "A")
    c.drop("n")
    t.eq(select(2, c.add("n", "1", 2, 2, "B")), "offen")
    c.drop("unbekannt")
  end },
  { "fit: eine kurze Liste bleibt ganz, eine lange wird auf den laengsten passenden Anfang gekuerzt", function()
    local function make(part) return { rows = part, more = true } end
    local short = { { n = "a" }, { n = "b" } }
    local got, rest = chunks.fit(short, make, 5000, ser)
    t.eq(#got, 2); t.eq(rest, false)
    local items = {}
    for i = 1, 100 do items[i] = { id = "B" .. i, name = string.rep("x", 100) } end
    got, rest = chunks.fit(items, make, 2000, ser)
    t.eq(rest, true)
    t.ok(#got >= 10 and #got < 100, "gekuerzt: " .. #got)
    t.ok(#ser.encode(make(got)) <= 2000, "der gekuerzte Anfang passt")
    local one_more = {}
    for i = 1, #got + 1 do one_more[i] = items[i] end
    t.ok(#ser.encode(make(one_more)) > 2000, "ein Element mehr passt nicht (der laengste Anfang)")
    t.eq(got[1].id, "B1"); t.eq(got[#got].id, "B" .. #got, "ein Anfang der Liste, in Reihenfolge")
  end },
  { "fit: ein einzelnes zu grosses Element und eine leere Liste", function()
    local function make(part) return { rows = part } end
    local huge = { { name = string.rep("y", 3000) } }
    local got, why = chunks.fit(huge, make, 2000, ser)
    t.eq(got, nil); t.contains(why, "einzelnes Element")
    local empty, rest = chunks.fit({}, make, 2000, ser)
    t.eq(#empty, 0); t.eq(rest, false)
    local cyc = {}; cyc.self = cyc
    local g2, w2 = chunks.fit({ cyc }, make, 2000, ser)
    t.eq(g2, nil); t.ok(w2 ~= nil)
  end },
}
