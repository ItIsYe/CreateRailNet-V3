--[[
Purpose: Sicheres Speichern (src/core/store.lua): Rundlauf, Beschaedigung, Abbruch an jeder Dateiaenderung (immer eine heile Fassung), Platzmangel, heal().
]]

local t = dofile("tests/lib/t.lua")
local cc = dofile("tests/fakes/cc.lua")
local storelib = require("core.store")

local P = "/crn_data/zustand.lua"

local function setup(opts)
  local fs = cc.fs(opts)
  fs.makeDir("/crn_data")
  return fs, storelib.new(fs)
end

return {
  { "speichern und laden", function()
    local fs, s = setup()
    t.eq(s.save(P, { n = 1, name = "x" }), true)
    local v, source = s.load(P)
    t.eq(v.n, 1); t.eq(source, "main")
    t.ok(not fs.exists(P .. ".tmp"))
  end },
  { "zweite Fassung: .prev bleibt, laden liefert die neue", function()
    local fs, s = setup()
    s.save(P, { n = 1 })
    s.save(P, { n = 2 })
    t.eq(s.load(P).n, 2)
    t.ok(fs.exists(P .. ".prev"))
  end },
  { "fehlende Datei", function()
    local fs, s = setup()
    local v, why = s.load(P)
    t.eq(v, nil); t.eq(why, "fehlt")
  end },
  { "beschaedigte Hauptdatei: .prev wird gelesen", function()
    local fs, s = setup()
    s.save(P, { n = 1 })
    s.save(P, { n = 2 })
    local fh = fs.open(P, "w"); fh.write("-- crn 00000000 5\nmuell"); fh.close()
    local v, source = s.load(P)
    t.eq(v.n, 1); t.eq(source, "prev")
  end },
  { "gekuerzte Datei wird erkannt", function()
    local fs, s = setup()
    s.save(P, { n = 1, text = string.rep("abc", 50) })
    local raw = fs.open(P, "r").readAll()
    local fh = fs.open(P, "w"); fh.write(raw:sub(1, -5)); fh.close()
    t.eq(s.load(P), nil)
  end },
  { "Schreibfehler wird beim Zuruecklesen erkannt, alte Fassung bleibt", function()
    local fs, s = setup()
    s.save(P, { n = 1 })
    fs._state.corrupt = function(path, text) if path:find(".tmp", 1, true) then return text:sub(1, -2) end return text end
    local ok, err = s.save(P, { n = 2 })
    t.eq(ok, nil)
    t.contains(err, "Schreiben fehlgeschlagen")
    fs._state.corrupt = nil
    t.eq(s.load(P).n, 1)
    t.ok(not fs.exists(P .. ".tmp"))
  end },
  { "nicht darstellbarer Wert", function()
    local fs, s = setup()
    local ok, err = s.save(P, { f = print })
    t.eq(ok, nil)
    t.contains(err, "nicht darstellbar")
  end },
  { "Abbruch an jeder Aenderung: immer eine heile Fassung, nie eine halbe", function()
    local checked = 0
    for _, first in ipairs({ false, true }) do
      local n = 1
      local finished = false
      while not finished do
        local fs, s = setup()
        if first then s.save(P, { n = 1 }) s.save(P, { n = 1 }) end
        fs._state.ops = 0
        fs._state.crash_at = n
        pcall(s.save, P, { n = 2 })
        local crashed = fs._state.crashed
        fs._state.crash_at = nil
        if not crashed then finished = true end
        local s2 = storelib.new(fs)
        local value = s2.load(P)
        if first then
          t.ok(value ~= nil, "nichts lesbar bei n=" .. n)
          t.ok(value.n == 1 or value.n == 2, "falscher Wert bei n=" .. n)
        else
          t.ok(value == nil or value.n == 2, "halber Wert bei n=" .. n)
        end
        -- heilen, danach ist die Hauptdatei da und der naechste Schreibvorgang gelingt
        s2.heal(P)
        if value ~= nil then
          t.ok(fs.exists(P), "Hauptdatei fehlt nach heal bei n=" .. n)
          t.ok(not fs.exists(P .. ".tmp"), "tmp bleibt bei n=" .. n)
          t.eq(s2.load(P).n, value.n, "heal veraendert den Wert bei n=" .. n)
        end
        t.eq(s2.save(P, { n = 3 }), true)
        t.eq(s2.load(P).n, 3)
        checked = checked + 1
        n = n + 1
        t.ok(n < 100)
      end
    end
    t.ok(checked >= 8, "geprueft: " .. checked)
  end },
  { "gleich lange, aber veraenderte Datei wird erkannt (Summe)", function()
    local fs, s = setup()
    s.save(P, { n = 1, text = "aaaa" })
    s.save(P, { n = 2, text = "bbbb" })
    local raw = fs.open(P, "r").readAll()
    local changed = raw:gsub("bbbb", "bbbc")
    t.eq(#changed, #raw)
    local fh = fs.open(P, "w"); fh.write(changed); fh.close()
    local v, source = s.load(P)
    t.eq(source, "prev")
    t.eq(v.n, 1)
  end },
  { "falsche Laengenangabe im Kopf wird erkannt", function()
    local fs, s = setup()
    s.save(P, { n = 1 })
    local raw = fs.open(P, "r").readAll()
    local sum, len, body = raw:match("^%-%- crn (%x+) (%d+)\n(.*)$")
    local fh = fs.open(P, "w"); fh.write("-- crn " .. sum .. " " .. (tonumber(len) + 1) .. "\n" .. body); fh.close()
    t.eq(s.load(P), nil)
  end },
  { "Abbruch vor dem letzten Umbenennen: fertige tmp-Fassung wird genutzt, wenn die Hauptdatei fehlt", function()
    local fs, s = setup()
    s.save(P, { n = 1 })
    s.save(P, { n = 1 })
    fs._state.ops = 0
    fs._state.crash_at = 4          -- move(tmp, path) scheitert: Hauptdatei fehlt, prev=1, tmp=2
    pcall(s.save, P, { n = 2 })
    fs._state.crash_at = nil
    t.ok(not fs.exists(P), "Hauptdatei fehlt")
    local v, source = s.load(P)
    t.eq(source, "tmp")
    t.eq(v.n, 2)
    t.eq(s.heal(P), "tmp")
    t.eq(s.load(P).n, 2)
  end },
  { "Abbruch vor dem Austausch: die Hauptdatei bleibt massgeblich, tmp wird verworfen", function()
    local fs, s = setup()
    s.save(P, { n = 1 })
    s.save(P, { n = 1 })
    fs._state.ops = 0
    fs._state.crash_at = 2          -- tmp ist fertig, Hauptdatei noch unberuehrt
    pcall(s.save, P, { n = 2 })
    fs._state.crash_at = nil
    t.ok(fs.exists(P .. ".tmp"))
    local v, source = s.load(P)
    t.eq(source, "main")
    t.eq(v.n, 1)
    t.eq(s.heal(P), "main")
    t.ok(not fs.exists(P .. ".tmp"))
  end },
  { "Platzmangel: .prev wird nicht behalten, die Hauptdatei bleibt", function()
    local fs, s = setup({ capacity = 12000 })
    local big = { text = string.rep("x", 1500) }
    t.eq(s.save(P, big), true)
    -- mit viel Platz entsteht .prev, bei knappem Platz nicht
    local fs2, s2 = setup({ capacity = 6000 })
    t.eq(s2.save(P, big), true)
    t.eq(s2.save(P, big), true)
    t.ok(not fs2.exists(P .. ".prev"), "bei Platzmangel keine zweite Fassung")
    t.ok(s2.load(P) ~= nil)
  end },
  { "heal: nur .prev ist heil", function()
    local fs, s = setup()
    s.save(P, { n = 1 })
    s.save(P, { n = 2 })
    fs.delete(P)
    t.eq(s.heal(P), "prev")
    t.eq(s.load(P).n, 1)
    t.ok(fs.exists(P))
  end },
  { "heal: nichts vorhanden", function()
    local fs, s = setup()
    t.eq(s.heal(P), nil)
  end },
}
