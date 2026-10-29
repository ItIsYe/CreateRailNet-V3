--[[
Purpose: Das Betriebsjournal (src/core/journal.lua): Absicht und Ergebnis, offene Vorgaenge nach einem Neustart, halb geschriebene Zeile, Verdichten mit begrenzter Groesse, Abbruch an jeder Dateiaenderung, voller Datentraeger.
]]

local t = dofile("tests/lib/t.lua")
local cc = dofile("tests/fakes/cc.lua")
local journal = require("core.journal")

local P = "/crn_data/journal.log"

local function open(fs, opts)
  opts = opts or {}
  local clock = 0
  return journal.new({ fs = fs, path = P, now = function() clock = clock + 1; return clock end, max_bytes = opts.max_bytes, keep = opts.keep })
end

local function fresh(fs_opts)
  local fs = cc.fs(fs_opts)
  fs.makeDir("/crn_data")
  return fs
end

return {
  { "Absicht und Ergebnis, offene Vorgaenge bleiben nach dem Neustart", function()
    local fs = fresh()
    local j = open(fs)
    local a = j.begin("freigabe.setzen", { zug = "GZ-001" })
    local b = j.begin("fahrplan.setzen", { zug = "GZ-002" })
    t.eq(#j.pending(), 2)
    j.finish(a, { ok = true })
    local j2 = open(fs)
    local pending = j2.pending()
    t.eq(#pending, 1)
    t.eq(pending[1].id, b)
    t.eq(pending[1].kind, "fahrplan.setzen")
    t.eq(pending[1].payload.zug, "GZ-002")
    t.ok(j2.begin("x", {}) > b, "Nummern laufen weiter")
  end },
  { "Ergebnis zweimal melden und unbekannter Vorgang", function()
    local fs = fresh()
    local j = open(fs)
    local a = j.begin("k", {})
    t.eq(j.finish(a, { ok = true }), true)
    t.eq(j.finish(a, { ok = false }), false, "zweites Ergebnis wird ignoriert")
    t.raises(function() j.finish(99, {}) end, "unbekannter Vorgang")
  end },
  { "ungueltige Art wird abgewiesen (keine Zeilentrenner im Namen)", function()
    local fs = fresh()
    local j = open(fs)
    t.raises(function() j.begin("a\tb", {}) end, "ungueltige Art")
    t.raises(function() j.begin("a b", {}) end, "ungueltige Art")
  end },
  { "Nutzdaten mit Zeilenumbruch und Tab bleiben heil", function()
    local fs = fresh()
    local j = open(fs)
    local id = j.begin("k", { text = "a\nb\tc" })
    local j2 = open(fs)
    t.eq(j2.pending()[1].payload.text, "a\nb\tc")
    t.eq(j2.pending()[1].id, id)
  end },
  { "halb geschriebene letzte Zeile wird ignoriert", function()
    local fs = fresh()
    local j = open(fs)
    j.begin("a", { n = 1 })
    local raw = fs.open(P, "r").readAll()
    local fh = fs.open(P, "w"); fh.write(raw .. "I\t2\t5\tb\t{[\"n\"]=2,"); fh.close()
    local j2 = open(fs)
    t.eq(#j2.pending(), 1)
    t.eq(j2.pending()[1].kind, "a")
  end },
  { "vollstaendig aussehende, aber nicht abgeschlossene letzte Zeile gilt als unvollstaendig", function()
    local fs = fresh()
    local j = open(fs)
    j.begin("a", { n = 1 })
    local raw = fs.open(P, "r").readAll()
    local fh = fs.open(P, "w"); fh.write(raw .. "I\t2\t5\tb\t{}"); fh.close()
    local j2 = open(fs)
    t.eq(#j2.pending(), 1)
    t.eq(j2.pending()[1].kind, "a")
  end },
  { "fertige tmp-Datei wird uebernommen, unfertige verworfen", function()
    local fs = fresh()
    local good = "I\t1\t1\tk\t{}\nE\t1\n"
    local fh = fs.open(P .. ".tmp", "w"); fh.write(good); fh.close()
    local j = open(fs)
    t.eq(#j.pending(), 1, "fertige tmp uebernommen")
    t.ok(not fs.exists(P .. ".tmp"))
    local fs2 = fresh()
    local fh2 = fs2.open(P .. ".tmp", "w"); fh2.write("I\t1\t1\tk\t{}\n"); fh2.close()
    local j2 = open(fs2)
    t.eq(#j2.pending(), 0, "ohne Endmarke verworfen")
    t.ok(not fs2.exists(P .. ".tmp"))
    local fs3 = fresh()
    local fh3 = fs3.open(P .. ".tmp", "w"); fh3.write("I\t1\t1\tk\t{}\nE\t5\n"); fh3.close()
    t.eq(#open(fs3).pending(), 0, "falsche Zeilenzahl verworfen")
    local fs4 = fresh()
    local a = fs4.open(P, "w"); a.write("I\t1\t1\talt\t{}\n"); a.close()
    local b = fs4.open(P .. ".tmp", "w"); b.write("I\t2\t2\tneu\t{}\nE\t1\n"); b.close()
    local j4 = open(fs4)
    t.eq(j4.pending()[1].kind, "alt", "mit vorhandener Hauptdatei gilt die Hauptdatei")
  end },
  { "Verdichten: offene Vorgaenge bleiben, abgeschlossene werden begrenzt, Groesse bleibt klein", function()
    local fs = fresh()
    local j = open(fs, { max_bytes = 1500, keep = 5 })
    local open_id = j.begin("offen", { x = 1 })
    for i = 1, 200 do
      local id = j.begin("fertig", { i = i, pad = string.rep("x", 20) })
      j.finish(id, { ok = true })
    end
    t.ok(j.size() < 3000, "Journal waechst unbegrenzt: " .. j.size())
    local pending = j.pending()
    t.eq(#pending, 1)
    t.eq(pending[1].id, open_id)
    local j2 = open(fs, { max_bytes = 1500, keep = 5 })
    t.eq(#j2.pending(), 1)
    t.eq(j2.pending()[1].kind, "offen")
    t.ok(j2.begin("neu", {}) > 200, "Nummern laufen nach dem Verdichten weiter")
  end },
  { "recent liefert die letzten Eintraege", function()
    local fs = fresh()
    local j = open(fs)
    for i = 1, 5 do j.finish(j.begin("k", { i = i }), { i = i }) end
    local recent = j.recent(3)
    t.eq(#recent, 3)
    t.eq(recent[3].payload.i, 5)
    t.eq(recent[1].payload.i, 3)
  end },
  { "Abbruch an jeder Aenderung: bestaetigte Eintraege sind nie weg", function()
    local checked = 0
    local n = 1
    local finished = false
    while not finished do
      local fs = fresh()
      local j = open(fs, { max_bytes = 400, keep = 2 })
      fs._state.ops = 0
      fs._state.crash_at = n
      local confirmed_begin, confirmed_done, attempted = {}, {}, {}
      pcall(function()
        for i = 1, 12 do
          local id = j.begin("k", { i = i, pad = string.rep("y", 15) })
          confirmed_begin[#confirmed_begin + 1] = id
          if i % 2 == 0 then
            attempted[id] = true
            j.finish(id, { ok = true })
            confirmed_done[id] = true
          end
        end
      end)
      local crashed = fs._state.crashed
      fs._state.crash_at = nil
      local j2 = open(fs, { max_bytes = 400, keep = 2 })
      local pending = {}
      for _, p in ipairs(j2.pending()) do pending[p.id] = true end
      -- Offene bestaetigte Absichten muessen noch offen sein, ausser sie wurden bestaetigt abgeschlossen
      for _, id in ipairs(confirmed_begin) do
        if not attempted[id] then
          -- seit dem letzten Verdichten koennen nur abgeschlossene verschwinden; offene nie
          -- (ein begonnenes, aber nicht bestaetigtes Abschliessen darf in beiden Zustaenden enden)
          t.ok(pending[id] or false, "bestaetigte offene Absicht " .. id .. " fehlt bei n=" .. n)
        end
      end
      for id in pairs(confirmed_done) do
        t.ok(not pending[id], "abgeschlossener Vorgang " .. id .. " ist wieder offen bei n=" .. n)
      end
      -- und das Journal bleibt benutzbar
      local id = j2.begin("danach", {})
      t.ok(id > 0)
      checked = checked + 1
      if not crashed then finished = true end
      n = n + 1
      t.ok(n < 400, "Schleife endet nicht")
    end
    t.ok(checked > 15, "es wurden zu wenige Abbruchstellen geprueft: " .. checked)
  end },
  { "voller Datentraeger: begin wirft, damit die Aktion nicht ausgefuehrt wird", function()
    local fs = fresh({ capacity = 1200 })
    local j = open(fs)
    local ok = pcall(function()
      for i = 1, 200 do j.begin("k", { i = i }) end
    end)
    t.eq(ok, false, "irgendwann ist kein Platz mehr")
  end },
}
