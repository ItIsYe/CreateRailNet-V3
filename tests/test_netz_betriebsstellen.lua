--[[
Purpose: Node-Verzeichnis, zweiter Teil (src/domain/netz.lua): Betriebsstellen (Personenbahnhof, Gueterbahnhof, Depot) mit Standorten, Stand je Objekt (veraltete Aenderungen werden abgelehnt) und Schutz einer von einer Anmeldung genutzten Betriebsstelle.
]]

local t = dofile("tests/lib/t.lua")
local cc = dofile("tests/fakes/cc.lua")
local storelib = require("core.store")
local netz = require("domain.netz")

local P = "/crn_data/netz.lua"

local function setup()
  local fs = cc.fs()
  fs.makeDir("/crn_data")
  local store = storelib.new(fs)
  return netz.new({ store = store, path = P }), store, fs
end

return {
  { "Betriebsstelle anlegen: Kennung BF0001, Art, Standort ueber den Namen; Fehler werden begruendet", function()
    local n = setup()
    local id, err = n.add_station({ name = "Patrick Personen", kind = "personenbahnhof", site = "Patrick" })
    t.eq(id, "BF0001", err)
    local st = n.station(id)
    t.eq(st.name, "Patrick Personen"); t.eq(st.kind, "personenbahnhof"); t.eq(st.site_name, "Patrick"); t.eq(st.site, "S0001")
    t.eq(n.add_station({ name = "Patrick Gueter", kind = "gueterbahnhof", site = "patrick" }), "BF0002")
    t.eq(n.add_station({ name = "Patrick Depot", kind = "depot", site = "Patrick" }), "BF0003")
    t.eq(#n.sites(), 1, "ein Standort fuer alle drei"); t.eq(n.sites()[1].stations, 3)
    local ok, why = n.add_station({ name = "patrick personen", kind = "depot" })
    t.eq(ok, nil); t.contains(why, "gibt es schon")
    ok, why = n.add_station({ name = "Neu", kind = "hafen" })
    t.eq(ok, nil); t.contains(why, "personenbahnhof")
    ok, why = n.add_station({ name = "", kind = "depot" })
    t.eq(ok, nil); t.contains(why, "Name")
    ok, why = n.add_station({ name = "Neu", kind = "depot", site = "Bad/Name" })
    t.eq(ok, nil); t.contains(why, "nur Buchstaben")
    t.eq(n.add_station({ name = "Ohne Standort", kind = "depot" }), "BF0004")
    t.eq(n.station("BF0004").site, nil)
    t.eq(#n.stations(), 4)
  end },
  { "Standort wechseln und leeren; leere Standorte verschwinden, Kennungen werden nicht wiederverwendet", function()
    local n = setup()
    local a = n.add_station({ name = "A", kind = "depot", site = "Alt" })
    t.eq(n.set_station(a, { site = "Neu" }), true)
    t.eq(#n.sites(), 1); t.eq(n.sites()[1].name, "Neu"); t.eq(n.sites()[1].id, "S0002", "der alte Standort ist weg, seine Kennung bleibt vergeben")
    t.eq(n.set_station(a, { site = false }), true)
    t.eq(#n.sites(), 0); t.eq(n.station(a).site, nil)
    t.eq(n.set_station(a, { site = "Wieder" }), true)
    t.eq(n.sites()[1].id, "S0003")
  end },
  { "Umbenennen und Art aendern; doppelter Name und unbekannte Art werden abgelehnt", function()
    local n = setup()
    local a = n.add_station({ name = "A", kind = "depot" })
    local b = n.add_station({ name = "B", kind = "depot" })
    t.eq(n.set_station(a, { name = "Anders", kind = "gueterbahnhof" }), true)
    t.eq(n.station(a).name, "Anders"); t.eq(n.station(a).kind, "gueterbahnhof")
    local ok, why = n.set_station(a, { name = "b" })
    t.eq(ok, nil); t.contains(why, "gibt es schon")
    ok, why = n.set_station(a, { kind = "hafen" })
    t.eq(ok, nil); t.contains(why, "personenbahnhof")
    ok, why = n.set_station("BF0099", { name = "X" })
    t.eq(ok, nil); t.contains(why, "gibt es nicht")
    t.eq(n.station(b).name, "B")
  end },
  { "Eine Betriebsstelle, die eine Anmeldung nutzt, laesst sich nicht loeschen; sonst schon", function()
    local n = setup()
    local bf = n.add_station({ name = "Hauptbahnhof", kind = "personenbahnhof", site = "Mitte" })
    local free = n.add_station({ name = "Frei", kind = "depot" })
    local node = n.claim_node({ claim = "claim-anm-1", role = "anmeldung", station = bf })
    local ok, why = n.remove_station(bf)
    t.eq(ok, nil); t.contains(why, node.id)
    t.eq(n.remove_station(free), true)
    t.eq(n.station(free), nil)
    t.eq(n.discard_node(node.id), true)
    t.eq(n.remove_station(bf), true)
    t.eq(#n.sites(), 0, "der leere Standort verschwindet")
  end },
  { "Stand je Objekt: veraltete Aenderungen werden abgelehnt, gleichzeitige Aenderungen gehen nicht verloren", function()
    local n = setup()
    local bf = n.add_station({ name = "S", kind = "depot" })
    local st = n.station(bf)
    t.eq(st.rev, 1)
    t.eq(n.set_station(bf, { kind = "gueterbahnhof", if_rev = st.rev }), true)
    t.eq(n.station(bf).rev, 2)
    local ok, why = n.set_station(bf, { kind = "depot", if_rev = st.rev })       -- zweiter Bearbeiter mit altem Stand
    t.eq(ok, nil); t.contains(why, "Betriebsstelle"); t.contains(why, "Stand 2")
    t.eq(n.station(bf).kind, "gueterbahnhof")
    -- ohne if_rev gilt die Aenderung wie bisher
    t.eq(n.set_station(bf, { kind = "depot" }), true)
  end },
}
