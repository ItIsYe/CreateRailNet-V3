--[[
Purpose: Die Text-Darstellung von Tabellen (src/core/ser.lua): Rundlauf, feste Reihenfolge, Sonderzeichen, Fehlerfaelle, keine Zeilenumbrueche, kein Zugriff auf Funktionen beim Lesen.
]]

local t = dofile("tests/lib/t.lua")
local ser = require("core.ser")

local function same(a, b)
  if type(a) ~= type(b) then return false end
  if type(a) ~= "table" then return a == b end
  for k, v in pairs(a) do if not same(v, b[k]) then return false end end
  for k in pairs(b) do if a[k] == nil then return false end end
  return true
end

return {
  { "Rundlauf mit allen Typen", function()
    local value = { a = 1, b = "text", c = true, d = false, e = { 1, 2, { x = 0.5 } }, [7] = "sieben", f = -3 }
    local back = assert(ser.decode(ser.encode(value)))
    t.ok(same(value, back))
  end },
  { "gleicher Wert ergibt gleichen Text, egal wie eingefuegt", function()
    local a, b = {}, {}
    for _, k in ipairs({ "z", "a", "m", "b" }) do a[k] = k end
    for _, k in ipairs({ "b", "m", "a", "z" }) do b[k] = k end
    t.eq(ser.encode(a), ser.encode(b))
  end },
  { "Zeilenumbrueche, Anfuehrungszeichen und Bytes ueber 127 bleiben heil und der Text ist einzeilig", function()
    local text = "zeile1\nzeile2\r\n\"zitat\" \\ rueck \0 null \200\255 \t"
    local encoded = ser.encode({ text = text })
    t.ok(not encoded:find("[\r\n%z]"), "Sonderzeichen im Ergebnis")
    t.eq(ser.decode(encoded).text, text)
  end },
  { "Zahlen: ganz, gebrochen, negativ", function()
    local back = ser.decode(ser.encode({ 1, -2, 0.25, 1e15, 123456789012 }))
    t.eq(back[1], 1); t.eq(back[2], -2); t.eq(back[3], 0.25); t.eq(back[4], 1e15); t.eq(back[5], 123456789012)
  end },
  { "Fehlerfaelle beim Schreiben", function()
    t.raises(function() ser.encode({ f = print }) end, "Typ function")
    local cyc = {}; cyc.self = cyc
    t.raises(function() ser.encode(cyc) end, "Zyklus")
    t.raises(function() ser.encode({ 0 / 0 }) end, "nicht darstellbar")
    t.raises(function() ser.encode({ [true] = 1 }) end, "Schluessel")
  end },
  { "Lesen: Muell und Funktionsaufrufe liefern nil", function()
    t.eq(ser.decode("{{{"), nil)
    t.eq(ser.decode(nil), nil)
    local marker = false
    _G.__ser_probe = function() marker = true end
    t.eq(ser.decode("__ser_probe()"), nil)
    _G.__ser_probe = nil
    t.eq(marker, false, "Funktion darf nicht aufgerufen werden")
    t.eq(ser.decode("os.exit()"), nil)
  end },
  { "leere Tabelle und Verschachtelung", function()
    t.eq(ser.encode({}), "{}")
    t.ok(same(ser.decode("{[\"a\"]={[\"b\"]={},},}"), { a = { b = {} } }))
  end },
}
