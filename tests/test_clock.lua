--[[
Purpose: Betriebsuhr (src/core/clock.lua) und Aufgabenplaner (src/core/ticker.lua): Fortsetzen nach Neustart, Boot-Kennung, kein Nachholen, Reihenfolge, Fehlerisolierung, verlorene Timer.
]]

local t = dofile("tests/lib/t.lua")
local cc = dofile("tests/fakes/cc.lua")
local storelib = require("core.store")
local clocklib = require("core.clock")
local tickerlib = require("core.ticker")

local P = "/crn_data/clock.lua"

-- os.clock des Computers beginnt bei jedem Start bei 0
local function boot(fs, raw_start)
  local raw = { v = raw_start or 0 }
  local store = storelib.new(fs)
  local c = clocklib.new({ raw = function() return raw.v end, store = store, path = P })
  return c, raw
end

local function fresh()
  local fs = cc.fs()
  fs.makeDir("/crn_data")
  return fs
end

return {
  { "erster Start: Uhr bei 0, nicht fortgesetzt, Boot 1", function()
    local fs = fresh()
    local c, raw = boot(fs)
    t.eq(c.now(), 0)
    t.eq(c.resumed(), false)
    t.eq(c.boot_id(), 1)
    raw.v = 12.5
    t.eq(c.now(), 12.5)
  end },
  { "nach Neustart geht die Uhr beim gespeicherten Stand weiter, Boot zaehlt hoch", function()
    local fs = fresh()
    local c, raw = boot(fs)
    raw.v = 100
    c.save()
    local c2, raw2 = boot(fs)   -- neuer Start: os.clock wieder bei 0
    t.eq(c2.resumed(), true)
    t.eq(c2.boot_id(), 2)
    t.eq(c2.now(), 100, "kein Nachholen und kein Zuruecksetzen")
    raw2.v = 5
    t.eq(c2.now(), 105)
    local c3 = boot(fs)
    t.eq(c3.boot_id(), 3)
  end },
  { "nicht gespeicherte Zeit vor dem Absturz geht verloren, die Uhr springt nie zurueck hinter den Speicherstand", function()
    local fs = fresh()
    local c, raw = boot(fs)
    raw.v = 50
    c.save()
    raw.v = 80   -- danach kein Speichern, Absturz
    local c2 = boot(fs)
    t.eq(c2.now(), 50)
  end },
  { "beschaedigter Zeitstand: Neustart bei 0, aber lauffaehig", function()
    local fs = fresh()
    local c = boot(fs)
    c.save()
    local fh = fs.open(P, "w"); fh.write("muell"); fh.close()
    fs.delete(P .. ".prev")
    local c2 = boot(fs)
    t.eq(c2.resumed(), false)
    t.eq(c2.now(), 0)
  end },
  { "Aufgaben: wiederkehrend, einmalig, Reihenfolge nach Faelligkeit", function()
    local fs = fresh()
    local c, raw = boot(fs)
    local k = tickerlib.new(c)
    local log = {}
    k.every("a", 10, function() log[#log + 1] = "a" end)
    k.after("b", 5, function() log[#log + 1] = "b" end)
    k.every("c", 5, function() log[#log + 1] = "c" end)
    t.eq(k.poll(), 0)
    raw.v = 5
    t.eq(k.poll(), 2)
    t.eq(table.concat(log, ""), "bc", "gleiche Faelligkeit nach Namen")
    raw.v = 10
    k.poll()
    t.eq(table.concat(log, ""), "bcac", "b war einmalig")
  end },
  { "nach langer Pause wird einmal ausgefuehrt, nicht nachgeholt", function()
    local fs = fresh()
    local c, raw = boot(fs)
    local k = tickerlib.new(c)
    local n = 0
    k.every("x", 1, function() n = n + 1 end)
    raw.v = 1000
    k.poll()
    k.poll()
    t.eq(n, 1)
    raw.v = 1001
    k.poll()
    t.eq(n, 2)
  end },
  { "Fehler in einer Aufgabe stoppt weder die anderen noch sich selbst", function()
    local fs = fresh()
    local c, raw = boot(fs)
    local k = tickerlib.new(c)
    local good, calls = 0, 0
    k.every("kaputt", 1, function() calls = calls + 1; error("bumm") end)
    k.every("gut", 1, function() good = good + 1 end)
    raw.v = 1; k.poll()
    raw.v = 2; k.poll()
    t.eq(good, 2)
    t.eq(calls, 2)
    t.eq(#k.errors(), 2)
    t.contains(k.errors()[1].error, "bumm")
  end },
  { "Aufgaben laufen nach Faelligkeit, nicht nach Namen", function()
    local fs = fresh()
    local c, raw = boot(fs)
    local k = tickerlib.new(c)
    local log = {}
    k.after("a", 7, function() log[#log + 1] = "a" end)
    k.after("z", 3, function() log[#log + 1] = "z" end)
    raw.v = 10
    k.poll()
    t.eq(table.concat(log, ""), "za")
  end },
  { "next_delay und cancel", function()
    local fs = fresh()
    local c, raw = boot(fs)
    local k = tickerlib.new(c)
    t.eq(k.next_delay(), nil)
    k.every("a", 10, function() end)
    k.every("b", 4, function() end)
    t.eq(k.next_delay(), 4)
    raw.v = 3
    t.eq(k.next_delay(), 1)
    raw.v = 9
    t.eq(k.next_delay(), 0)
    k.cancel("b")
    raw.v = 0
    t.eq(k.next_delay(), 10)
  end },
  { "Aufgabe, die sich selbst abbricht oder neu anlegt, verwirrt den Planer nicht", function()
    local fs = fresh()
    local c, raw = boot(fs)
    local k = tickerlib.new(c)
    local n = 0
    k.every("selbst", 1, function() n = n + 1; k.cancel("selbst") end)
    raw.v = 1; k.poll()
    raw.v = 2; k.poll()
    t.eq(n, 1)
    k.after("neu", 1, function() k.after("neu", 1, function() n = n + 10 end) end)
    raw.v = 3; k.poll()
    raw.v = 4; k.poll()
    t.eq(n, 11)
  end },
}
