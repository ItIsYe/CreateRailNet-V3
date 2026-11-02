--[[
Purpose: Zweiter, eigenstaendiger Anschluss derselben Betriebsstelle (Konzept 4.3) und Schleifen als normale Gleisverbindungen (Konzept 8): beide Enden eines Bereichs duerfen an dieselbe Betriebsstelle fuehren, wenn sie verschiedene Namen haben; eine Schleife ist ein Fahrweg und macht aus dem Gleis keine Betriebsstelle.
]]

local t = dofile("tests/lib/t.lua")
local H = dofile("tests/lib/harness.lua")
local netzlib = require("domain.netz")

return {
  { "Beide Enden an derselben Betriebsstelle: ohne Zusatz abgelehnt, mit Zusatz ein eigener Anschluss; Gleisrichtungen folgen", function()
    local netz = netzlib.new({})
    local a = assert(netz.add_area({ name = "Ring", ends = { "West", "Ost" }, count = 2 }))
    local bf = assert(netz.add_station({ name = "Hafen", kind = "gueterbahnhof" }))
    assert(netz.set_end(a, 1, { kind = "betriebsstelle", ref = bf }))
    local ok, why = netz.set_end(a, 2, { kind = "betriebsstelle", ref = bf })
    t.eq(ok, nil); t.contains(why, "verschiedene Namen")
    assert(netz.set_end(a, 2, { kind = "betriebsstelle", ref = bf, suffix = "Nord" }))
    local area = netz.area(a)
    t.eq(area.ends[1], "Hafen"); t.eq(area.ends[2], "Hafen Nord")
    t.eq(area.end_suffixes[1], false); t.eq(area.end_suffixes[2], "Nord")
    t.eq(area.tracks[1].direction, "Hafen Nord", "die Richtung folgt dem neuen Anschlussnamen")
    -- die Betriebsstelle wird umbenannt: beide Anschluesse und die Richtungen ziehen mit, der Zusatz bleibt
    assert(netz.set_station(bf, { name = "Seehafen" }))
    area = netz.area(a)
    t.eq(area.ends[1], "Seehafen"); t.eq(area.ends[2], "Seehafen Nord"); t.eq(area.tracks[1].direction, "Seehafen Nord")
    -- Zusatz entfernen: wieder derselbe Name wie das andere Ende, abgelehnt
    ok, why = netz.set_end(a, 2, { kind = "betriebsstelle", ref = bf })
    t.eq(ok, nil); t.contains(why, "verschiedene Namen")
    -- ein Zusatz, der das andere Ende gleich benennen wuerde
    ok, why = netz.set_end(a, 1, { kind = "betriebsstelle", ref = bf, suffix = "Nord" })
    t.eq(ok, nil); t.contains(why, "verschiedene Namen")
    ok, why = netz.set_end(a, 2, { kind = "betriebsstelle", ref = bf, suffix = "Zu/Lang" })
    t.eq(ok, nil)
  end },
  { "Eine Betriebsstelle laesst sich nicht so umbenennen, dass die beiden Anschluesse eines Bereichs gleich wuerden", function()
    local netz = netzlib.new({})
    local a = assert(netz.add_area({ name = "Ring", ends = { "West", "Ost" }, count = 1 }))
    local x = assert(netz.add_station({ name = "Anker", kind = "gueterbahnhof" }))
    local y = assert(netz.add_station({ name = "Hafen Nord", kind = "depot" }))
    assert(netz.set_end(a, 1, { kind = "betriebsstelle", ref = x, suffix = "Nord" }))
    assert(netz.set_end(a, 2, { kind = "betriebsstelle", ref = y }))
    t.eq(netz.area(a).ends[1], "Anker Nord"); t.eq(netz.area(a).ends[2], "Hafen Nord")
    local ok, why = netz.set_station(x, { name = "Hafen" })
    t.eq(ok, nil); t.contains(why, "zwei gleich benannte Anschluesse")
    t.eq(netz.station(x).name, "Anker")
  end },
  { "Seite Anschluesse: Zusatz eintragen, anzeigen, aendern", function()
    local h = H.new()
    local z = h.add_node({ id = "hauptstelle", roles = { "zentrale" }, tracks = {} })
    h.step(2)
    local netz = z.node.roles.zentrale.netz
    local a = netz.add_area({ name = "Ring", ends = { "West", "Ost" }, count = 1 })
    local bf = netz.add_station({ name = "Hafen", kind = "gueterbahnhof" })
    local v = H.open_page(z, "anschluesse")
    z.tap(v, "sel:anschluesse:1"); z.tap(v, "act:bearbeiten")
    z.type(v, "art", "betriebsstelle")
    z.tap(v, "act:f_weiter"); z.type(v, "ziel", "Hafen"); z.type(v, "zusatz", "Sued"); z.tap(v, "act:f_speichern")
    t.eq(netz.area(a).ends[1], "Hafen Sued", v.hint)
    t.eq(netz.area(a).end_suffixes[1], "Sued")
    z.tap(v, "sel:anschluesse:1"); z.tap(v, "act:bearbeiten")
    z.tap(v, "act:f_weiter")
    z.type(v, "zusatz", "Nord"); z.tap(v, "act:f_speichern")
    t.eq(netz.area(a).ends[1], "Hafen Nord", v.hint)
  end },
  { "Schleife: ein Fahrweg innerhalb eines Bereichs ist eine normale Gleisverbindung; die Seite Knoten kennzeichnet sie", function()
    local h = H.new()
    local z = h.add_node({ id = "hauptstelle", roles = { "zentrale" }, tracks = {} })
    h.step(2)
    local netz = z.node.roles.zentrale.netz
    netz.add_area({ name = "Wende", ends = { "Nord", "Sued" }, count = 2 })
    local k = assert(netz.add_junction({ name = "Wendeschleife" }))
    assert(netz.add_connection(k, "Ein", { "A0001" })); assert(netz.add_connection(k, "Aus", { "A0002" }))
    local rid = assert(netz.add_route(k, "A0001", "A0002"))
    local j = netz.junction(k)
    t.eq(j.routes[1].loop, true, "Start und Ziel im selben Bereich")
    local v = H.open_page(z, "knoten")
    t.contains(z.text(v), "Schleife")
    t.eq(netz.stations()[1], nil, "eine Schleife legt keine Betriebsstelle an")
  end },
}
