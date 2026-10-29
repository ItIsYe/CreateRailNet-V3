--[[
Purpose: Die Pruefung tools/check.lua erkennt fehlende Kopfzeilen, Syntaxfehler und Lua-5.1-fremde Aufrufe.
]]

local t = dofile("tests/lib/t.lua")
local check = dofile("tools/check.lua")

local HEAD = "--[[\nPurpose: Test\n]]\n"

return {
  { "sauberer Text", function()
    t.eq(#check.scan_text("a.lua", HEAD .. "local x = 1\nreturn x\n"), 0)
  end },
  { "fehlende Kopfzeile", function()
    local problems = check.scan_text("a.lua", "local x = 1\n")
    t.eq(#problems, 1)
    t.contains(problems[1], "Purpose")
  end },
  { "Syntaxfehler", function()
    local problems = check.scan_text("a.lua", HEAD .. "local = =\n")
    t.eq(#problems, 1)
    t.contains(problems[1], "Syntaxfehler")
  end },
  { "Aufrufe, die Lua 5.1 nicht kennt", function()
    local t1 = check.scan_text("a.lua", HEAD .. "local a = table" .. ".unpack({1})\n")
    t.eq(#t1, 1)
    t.contains(t1[1], "unpack")
    t.eq(#check.scan_text("a.lua", HEAD .. "local a = math" .. ".type(1)\n"), 1)
  end },
  { "die Absicherung 'unpack = table.unpack or unpack' ist erlaubt", function()
    t.eq(#check.scan_text("a.lua", HEAD .. "local unpack = table" .. ".unpack or unpack\nreturn unpack\n"), 0)
  end },
  { "Kommentare werden nicht gemeldet", function()
    t.eq(#check.scan_text("a.lua", HEAD .. "-- table" .. ".unpack waere hier falsch\nreturn 1\n"), 0)
  end },
}
