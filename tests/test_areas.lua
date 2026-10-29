--[[
Purpose: Nutzungsvormerkung am Knotenpunkt: T-Kreuzung mit langen Zuegen, Konflikte durch Zusammenfuehrung und gegenlaeufige Verbindungen, Raeumung erst mit "train_passed" am erwarteten Ausgang, keine Freigabe durch Zeitablauf, ungeplante Einfahrt, Neustart mit gespeichertem Stand.
]]

local t = dofile("tests/lib/t.lua")
local cc = dofile("tests/fakes/cc.lua")
local storelib = require("core.store")
local areas = require("domain.areas")

-- T-Kreuzung: West, Ost, Sued. Verbindungen: 1 West->Ost, 2 West->Sued, 3 Sued->Ost, 4 Ost->West
local function tee(extra)
  local clock = { t = 0 }
  local spec = {
    connections = { West = true, Ost = true, Sued = true },
    moves = { { from = "West", to = "Ost" }, { from = "West", to = "Sued" }, { from = "Sued", to = "Ost" }, { from = "Ost", to = "West" } },
    conflicts = { { moves = { 1, 4 } } },
    now = function() return clock.t end,
  }
  for k, v in pairs(extra or {}) do spec[k] = v end
  return areas.new(spec), clock
end

return {
  { "Konflikte zwischen Einfahrten: gemeinsames Ziel, ausdrueckliche Konflikte, dieselbe Einfahrt", function()
    local a = tee()
    t.eq(a.entries_conflict("West", "West"), true)
    t.eq(a.entries_conflict("West", "Sued"), true, "beide koennen nach Ost fahren (Zusammenfuehrung)")
    t.eq(a.entries_conflict("West", "Ost"), true, "Verbindung 1 und 4 schliessen sich aus")
    t.eq(a.entries_conflict("Sued", "Ost"), false, "Sued->Ost und Ost->West sind nicht eingetragen als Konflikt, enden aber an verschiedenen Ausgaengen")
  end },
  { "freie Einfahrt wird freigegeben; die zweite wartet, bis der erste Zug ganz heraus ist", function()
    local a, clock = tee()
    local u1 = a.announce("West", "Zug A")
    clock.t = 5
    local u2 = a.announce("Sued", "Zug B")
    local granted = a.next_grants()
    t.eq(#granted, 1); t.eq(granted[1].id, u1.id)
    t.eq(u2.state, "angekuendigt")
    t.eq(#a.next_grants(), 0, "kein zweiter Zug in den Konfliktbereich")
    local u, unplanned = a.entered("West", "Zug A")
    t.eq(u.state, "eingefahren"); t.eq(unplanned, false)
    t.eq(#a.next_grants(), 0)
    -- Spitze am Ausgang: noch nicht frei (der lange Zug ragt zurueck)
    local used, state = a.exited("Ost", "Zug A", "passing")
    t.eq(state, "ausgefahren")
    t.eq(#a.next_grants(), 0, "Ausfahrt der Spitze ist keine Raeumung")
    used, state = a.exited("Ost", "Zug A", "passed")
    t.eq(state, "freigemeldet")
    local next_ = a.next_grants()
    t.eq(#next_, 1); t.eq(next_[1].id, u2.id)
  end },
  { "Raeumung nur am erwarteten Ausgang und nur fuer den richtigen Zug", function()
    local a = tee()
    a.announce("Sued", "Zug A")
    a.next_grants()
    a.entered("Sued", "Zug A")
    local u, why = a.exited("West", "Zug A", "passed")
    t.eq(u, nil); t.contains(why, "keine passende Nutzung")
    u, why = a.exited("Ost", "Zug X", "passed")
    t.eq(u, nil)
    u, why = a.exited("Ost", nil, "passed")
    t.eq(u, nil); t.contains(why, "Zugname fehlt")
    t.eq(a.status()[1].state, "eingefahren", "kein Nachweis, keine Freigabe")
  end },
  { "keine Freigabe durch Zeitablauf: nur Anzeige 'bleibt lange belegt'", function()
    local a, clock = tee()
    a.announce("West", "Zug A")
    a.next_grants()
    a.entered("West", "Zug A")
    clock.t = 100000
    t.eq(#a.next_grants(), 0)
    local st = a.status()
    t.eq(#st, 1); t.eq(st[1].long, true)
    a.announce("Sued", "Zug B")
    t.eq(#a.next_grants(), 0)
  end },
  { "Einfahrt ohne Freigabe wird als ungeplant erkannt und blockiert Konflikte", function()
    local a = tee()
    a.announce("West", "Zug A")
    local u, unplanned = a.entered("West", "Zug A")
    t.eq(unplanned, true, "fuhr ein, ohne dass die Freigabe stand")
    a.announce("Sued", "Zug B")
    t.eq(#a.next_grants(), 0)
    local u2, unplanned2 = a.entered("Sued", "Zug C")
    t.eq(unplanned2, true, "unbekannter Zug ohne Ankuendigung")
    t.eq(#a.status(), 3)
  end },
  { "Zurueckgenommene Ankuendigung gibt den Platz frei; freigegebene bleiben bestehen", function()
    local a = tee()
    a.announce("West", "Zug A")
    a.announce("Sued", "Zug B")
    t.eq(a.withdraw("Sued", "Zug B"), true)
    a.next_grants()
    t.eq(a.withdraw("West", "Zug A"), false, "eine freigegebene Nutzung wird nicht stillschweigend zurueckgenommen")
    t.eq(#a.status(), 1)
  end },
  { "Bediener loest eine Nutzung auf: wird protokolliert", function()
    local a = tee()
    a.announce("West", "Zug A"); a.next_grants(); a.entered("West", "Zug A")
    local u = a.status()[1]
    t.eq(a.clear(u.id, "Sichtpruefung"), true)
    t.eq(#a.status(), 0)
    t.contains(a.history()[1].how, "Sichtpruefung")
    t.eq((a.clear("N-99", "x")), nil)
  end },
  { "Neustart: gespeicherte Nutzungen bleiben, bis ein Nachweis vorliegt", function()
    local fs = cc.fs()
    fs.makeDir("/crn_data")
    local store = storelib.new(fs)
    local a1 = tee({ store = store, path = "/crn_data/knoten.lua" })
    a1.announce("West", "Zug A"); a1.next_grants(); a1.entered("West", "Zug A")
    local a2 = tee({ store = store, path = "/crn_data/knoten.lua" })
    t.eq(#a2.status(), 1)
    a2.announce("Sued", "Zug B")
    t.eq(#a2.next_grants(), 0, "nach dem Neustart wird nichts leichtfertig freigegeben")
    a2.exited("Ost", "Zug A", "passed")
    t.eq(#a2.next_grants(), 1)
  end },
  { "unabhaengige Einfahrten laufen parallel", function()
    local clock = { t = 0 }
    local a = areas.new({
      connections = { A1 = true, A2 = true, B1 = true, B2 = true },
      moves = { { from = "A1", to = "B1" }, { from = "A2", to = "B2" } },
      conflicts = {}, now = function() return clock.t end,
    })
    a.announce("A1", "Zug 1"); a.announce("A2", "Zug 2")
    t.eq(#a.next_grants(), 2, "getrennte Durchfahrgleise sind unabhaengig")
  end },
  { "Zufallsablauf: eine neue Freigabe kollidiert nie mit einer aktiven Nutzung", function()
    local seed = 7
    local function rnd(n) seed = (seed * 48271) % 2147483647 return seed % n + 1 end
    for run = 1, 20 do
      local clock = { t = 0 }
      local names = { "A", "B", "C", "D" }
      local a = areas.new({
        connections = { A = true, B = true, C = true, D = true },
        moves = { { from = "A", to = "C" }, { from = "A", to = "D" }, { from = "B", to = "D" }, { from = "C", to = "A" } },
        conflicts = { { moves = { 1, 4 } }, { moves = { 2, 4 } } },
        now = function() return clock.t end,
      })
      local trains = { "T1", "T2", "T3", "T4", "T5" }
      for _ = 1, 200 do
        clock.t = clock.t + 1
        local op = rnd(6)
        local train = trains[rnd(#trains)]
        if op == 1 then a.announce(names[rnd(4)], train, "g")
        elseif op == 2 then
          local before = {}
          for _, u in ipairs(a.status()) do
            if u.state == "freigegeben" or u.state == "eingefahren" or u.state == "ausgefahren" then before[#before + 1] = u end
          end
          local granted = a.next_grants()
          for i, g in ipairs(granted) do
            for _, b in ipairs(before) do t.ok(not a.entries_conflict(g.entry, b.entry), "Freigabe kollidiert mit " .. b.id) end
            for j = 1, i - 1 do t.ok(not a.entries_conflict(g.entry, granted[j].entry), "zwei Freigaben kollidieren") end
          end
        elseif op == 3 then a.entered(names[rnd(4)], train, "g")
        elseif op == 4 then a.exited(names[rnd(4)], train, rnd(2) == 1 and "passing" or "passed")
        elseif op == 5 then a.withdraw(names[rnd(4)], train)
        else
          local st = a.status()
          if #st > 0 and rnd(10) == 1 then a.clear(st[rnd(#st)].id, "Test") end
        end
      end
    end
  end },
}
