--[[
Purpose: Knoten im Netzverzeichnis (src/domain/netz.lua, Konzept 7): Anschluesse als Gruppen von Gleisenden, gerichtete Fahrwege, Konflikte; Vorschlaege bleiben unbestaetigt, nie wird aus einer T- oder Y-Form eine Verbindung abgeleitet; Nodes bekommen nur Bestaetigtes in Teilen unter der Funkgrenze; benutzte Gleise sind geschuetzt.
]]

local t = dofile("tests/lib/t.lua")
local cc = dofile("tests/fakes/cc.lua")
local storelib = require("core.store")
local netz = require("domain.netz")
local ser = require("core.ser")

local function setup()
  local fs = cc.fs()
  fs.makeDir("/crn_data")
  local store = storelib.new(fs)
  return netz.new({ store = store, path = "/crn_data/netz.lua" }), store
end

-- T-Knoten: West (W1, W2), Ost (O1, O2), Sued (S1); Gleise des Verzeichnisses A0001..A0005
local function t_junction(n)
  n.add_area({ name = "West", ends = { "a", "b" }, count = 2 })   -- A0001 A0002
  n.add_area({ name = "Ost", ends = { "c", "d" }, count = 2 })    -- A0003 A0004
  n.add_area({ name = "Sued", ends = { "e", "f" }, count = 1 })   -- A0005
  local k = n.add_junction({ name = "Hauptknoten" })
  assert(n.add_connection(k, "West", { "A0001", "A0002" }))
  assert(n.add_connection(k, "Ost", { "A0003", "A0004" }))
  assert(n.add_connection(k, "Sued", { "A0005" }))
  return k
end

return {
  { "Knoten anlegen und benennen; Anschluesse mit Gleisenden; Fehler werden begruendet", function()
    local n = setup()
    local k = t_junction(n)
    t.eq(k, "K0001")
    local j = n.junction(k)
    t.eq(j.name, "Hauptknoten"); t.eq(#j.connections, 3); t.eq(j.connections[1].name, "Ost")
    t.eq(j.connections[2].name, "Sued"); t.eq(#j.connections[2].tracks, 1)
    local ok, why = n.add_connection(k, "West", { "A0005" })
    t.eq(ok, nil); t.contains(why, "schon")
    ok, why = n.add_connection(k, "Neu", { "A0001" })
    t.eq(ok, nil); t.contains(why, "gehoert schon zum Anschluss West")
    ok, why = n.add_connection(k, "Neu", { "A9999" })
    t.eq(ok, nil); t.contains(why, "gibt es nicht")
    ok, why = n.add_connection(k, "Neu", {})
    t.eq(ok, nil); t.contains(why, "mindestens ein Gleisende")
    ok, why = n.add_connection(k, "beide", { "A0001" })
    t.eq(ok, nil)
    ok, why = n.add_junction({ name = "hauptknoten" })
    t.eq(ok, nil); t.contains(why, "gibt es schon")
    t.eq(n.set_junction(k, { name = "Nordknoten" }), true)
    t.eq(n.junctions()[1].name, "Nordknoten")
    t.eq(n.junctions()[1].connections, 3, "die Zusammenfassung nennt Zahlen")
  end },
  { "Fahrwege: nur zwischen verschiedenen Anschluessen, gerichtet, ohne Doppel; zunaechst unbestaetigt", function()
    local n = setup()
    local k = t_junction(n)
    local r = n.add_route(k, "A0001", "A0003")
    t.eq(r, "F0001")
    local j = n.junction(k)
    t.eq(j.routes[1].from, "A0001"); t.eq(j.routes[1].to, "A0003"); t.eq(j.routes[1].confirmed, false)
    t.eq(j.unconfirmed, 1)
    t.eq(n.add_route(k, "A0003", "A0001"), "F0002", "die Gegenrichtung ist ein eigener Fahrweg")
    local ok, why = n.add_route(k, "A0001", "A0003")
    t.eq(ok, nil); t.contains(why, "gibt es schon")
    ok, why = n.add_route(k, "A0001", "A0002")
    t.eq(ok, nil); t.contains(why, "verschiedene Anschluesse")
    ok, why = n.add_route(k, "A0001", "A0099")
    t.eq(ok, nil); t.contains(why, "gehoert zu keinem Anschluss")
    -- Fahrweg ohne Verbindung wird nicht abgeleitet: Sued ist erst einmal mit nichts verbunden
    t.eq(#n.junction(k).routes, 2)
  end },
  { "Vorschlag 'durchgehend': gleich nummerierte Gleisenden zweier Anschluesse in beide Richtungen, unbestaetigt; 'alle' nur ausdruecklich", function()
    local n = setup()
    n.add_area({ name = "West", ends = { "a", "b" }, count = 2 })
    n.add_area({ name = "Ost", ends = { "c", "d" }, count = 2 })
    local k = n.add_junction({ name = "Durchfahrt" })
    n.add_connection(k, "West", { "A0001", "A0002" }); n.add_connection(k, "Ost", { "A0003", "A0004" })
    t.eq(n.propose_routes(k, "durchgehend"), 4)
    local j = n.junction(k)
    t.eq(#j.routes, 4); t.eq(j.unconfirmed, 4)
    for _, r in ipairs(j.routes) do t.eq(r.confirmed, false) end
    t.eq(n.propose_routes(k, "durchgehend"), 0, "wiederholt nichts doppelt an")
    local k2 = t_junction(n)                                   -- drei Anschluesse
    local ok, why = n.propose_routes(k2, "durchgehend")
    t.eq(ok, nil); t.contains(why, "genau zwei")
    ok, why = n.propose_routes(k2, "dreieck")
    t.eq(ok, nil)
  end },
  { "Konfliktvorschlaege und Hinweise im Einzelnen", function()
    local n = setup()
    local k = t_junction(n)
    local f1 = n.add_route(k, "A0001", "A0003")
    local f2 = n.add_route(k, "A0002", "A0003")
    local f3 = n.add_route(k, "A0001", "A0005")
    local f4 = n.add_route(k, "A0004", "A0005")
    local before = n.junction(k)
    local texts = table.concat(before.hints, "|")
    t.contains(texts, "F0001 und F0002 haben dasselbe Zielgleis")
    t.contains(texts, "F0001 und F0003 haben dasselbe Startgleis")
    t.contains(texts, "F0003 und F0004 haben dasselbe Zielgleis")
    t.eq(#before.hints, 3, "F0002/F0004 haben nichts gemeinsam")
    t.eq(n.propose_conflicts(k), 3)
    local after = n.junction(k)
    t.eq(#after.conflicts, 3); t.eq(#after.hints, 0, "mit den Vorschlaegen sind die Luecken geschlossen")
    t.eq(after.conflicts[1].confirmed, false)
    t.eq(n.propose_conflicts(k), 0)
    -- von Hand: Kreuzung auf gleicher Hoehe
    t.eq(n.add_conflict(k, f2, f4), true)
    local ok, why = n.add_conflict(k, f2, f4)
    t.eq(ok, nil); t.contains(why, "gibt es schon")
    ok, why = n.add_conflict(k, f4, f2)
    t.eq(ok, nil, "unabhaengig von der Reihenfolge")
    ok, why = n.add_conflict(k, f1, f1)
    t.eq(ok, nil); t.contains(why, "mit sich selbst")
    ok, why = n.add_conflict(k, f1, "F0099")
    t.eq(ok, nil); t.contains(why, "Beide Fahrwege")
    t.eq(n.remove_conflict(k, f4, f2), true)
    ok, why = n.remove_conflict(k, f4, f2)
    t.eq(ok, nil)
  end },
  { "Bestaetigen: erst danach sehen Nodes Fahrwege und Konflikte; Aenderungen am Knoten bleiben nachvollziehbar", function()
    local n = setup()
    local k = t_junction(n)
    n.add_route(k, "A0001", "A0003"); n.add_route(k, "A0002", "A0003")
    n.propose_conflicts(k)
    t.eq(#n.junction_part(k, "fahrwege").routes, 0, "unbestaetigt: nichts fuer Nodes")
    t.eq(#n.junction_part(k, "konflikte").conflicts, 0)
    t.eq(n.junction(k).unconfirmed, 3)
    t.eq(n.confirm_junction(k), 3)
    t.eq(n.junction(k).unconfirmed, 0)
    t.eq(#n.junction_part(k, "fahrwege").routes, 2); t.eq(#n.junction_part(k, "konflikte").conflicts, 1)
    t.eq(n.confirm_junction(k), 0, "nichts mehr zu bestaetigen")
    -- ein neuer Fahrweg ist wieder unbestaetigt und fehlt in den Nodedaten
    n.add_route(k, "A0001", "A0005")
    t.eq(#n.junction_part(k, "fahrwege").routes, 2)
    t.eq(n.junction(k).unconfirmed, 1)
    -- ein bestaetigter Konflikt mit einem unbestaetigten Fahrweg geht nicht hinaus
    n.add_conflict(k, "F0001", "F0003", true)
    t.eq(#n.junction_part(k, "konflikte").conflicts, 1)
    local ok, why = n.junction_part(k, "teil")
    t.eq(ok, nil); t.contains(why, "Teil")
    ok, why = n.junction_part("K9999", "fahrwege")
    t.eq(ok, nil)
  end },
  { "Teile fuer Nodes: Anschluesse mit Gleisnamen; alles passt auch bei vollem Knoten in eine Funknachricht", function()
    local n = setup()
    -- 8 Anschluesse mit je 3 Gleisenden = 24, 60 Fahrwege, 90 Konflikte
    for i = 1, 8 do n.add_area({ name = "Bereich " .. i, ends = { "x", "y" }, count = 3 }) end
    local k = n.add_junction({ name = "Grosser Knoten" })
    local tid = 0
    for i = 1, 8 do
      local ends = {}
      for e = 1, 3 do tid = tid + 1; ends[e] = string.format("A%04d", tid) end
      n.add_connection(k, "Anschluss " .. i, ends)
    end
    t.eq(n.propose_routes(k, "alle") == nil, true, "'alle' wuerde mehr als 60 Fahrwege ergeben und wird abgelehnt")
    -- 60 Fahrwege von Hand
    local made = 0
    for from = 1, 24 do
      for to = 1, 24 do
        if made < 60 and math.floor((from - 1) / 3) ~= math.floor((to - 1) / 3) and (from + to) % 7 == 0 then
          if n.add_route(k, string.format("A%04d", from), string.format("A%04d", to)) then made = made + 1 end
        end
      end
    end
    n.propose_conflicts(k)
    n.confirm_junction(k)
    for _, part in ipairs({ "anschluesse", "fahrwege", "konflikte" }) do
      local p = n.junction_part(k, part)
      local text = ser.encode({ payload = p, pad = string.rep("x", 300) })
      t.ok(#text < 5800, part .. ": " .. #text)
    end
    local conns = n.junction_part(k, "anschluesse").connections
    t.eq(#conns, 8); t.eq(conns[1].tracks[1].name, "Gleis 1")
  end },
  { "Anschluss entfernen nimmt seine Fahrwege und deren Konflikte mit", function()
    local n = setup()
    local k = t_junction(n)
    local f1 = n.add_route(k, "A0001", "A0003")
    local f2 = n.add_route(k, "A0002", "A0003")
    local f3 = n.add_route(k, "A0004", "A0005")
    n.propose_conflicts(k)
    t.eq(n.remove_connection(k, "West"), true)
    local j = n.junction(k)
    t.eq(#j.routes, 1); t.eq(j.routes[1].id, f3)
    t.eq(#j.conflicts, 0)
    local ok, why = n.remove_connection(k, "West")
    t.eq(ok, nil)
    t.eq(n.remove_route(k, f3), true)
    t.eq(#n.junction(k).routes, 0)
  end },
  { "Benutzte Gleise und Bereiche lassen sich nicht loeschen, solange ein Knoten sie fuehrt", function()
    local n = setup()
    local k = t_junction(n)
    local ok, why = n.remove_track("A0001")
    t.eq(ok, nil); t.contains(why, "Hauptknoten"); t.contains(why, "West")
    ok, why = n.remove_area("B0001")
    t.eq(ok, nil); t.contains(why, "Hauptknoten")
    t.eq(n.remove_connection(k, "West"), true)
    t.eq(n.remove_track("A0001"), true)
    t.eq(n.remove_junction(k), true)
    t.eq(n.junction(k), nil)
  end },
  { "Speichern und Laden: Knoten, Fahrwege, Konflikte und der Zaehler der Fahrwege bleiben", function()
    local n, store = setup()
    local k = t_junction(n)
    n.add_route(k, "A0001", "A0003"); n.add_route(k, "A0002", "A0003")
    n.propose_conflicts(k); n.confirm_junction(k)
    local m = netz.new({ store = store, path = "/crn_data/netz.lua" })
    local j = m.junction(k)
    t.eq(#j.routes, 2); t.eq(#j.conflicts, 1); t.eq(j.unconfirmed, 0)
    t.eq(m.add_route(k, "A0001", "A0005"), "F0003")
    m.remove_route(k, "F0003")
    t.eq(m.add_route(k, "A0001", "A0005"), "F0004", "Fahrwegkennungen werden nicht wiederverwendet")
  end },
  { "Grenzen: Knoten, Gleisenden, Anschluesse", function()
    local n = setup()
    n.add_area({ name = "Gross", ends = { "a", "b" }, count = 40 })
    local k = n.add_junction({ name = "Knoten" })
    local ids = {}
    for i = 1, 25 do ids[i] = string.format("A%04d", i) end
    local ok, why = n.add_connection(k, "Zuviele", ids)
    t.eq(ok, nil); t.contains(why, "hoechstens 24 Gleisenden")
    for i = 1, 8 do n.add_connection(k, "C" .. i, { string.format("A%04d", i) }) end
    ok, why = n.add_connection(k, "C9", { "A0009" })
    t.eq(ok, nil); t.contains(why, "hoechstens 8 Anschluesse")
  end },
}
