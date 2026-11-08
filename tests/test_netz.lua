--[[
Purpose: Node-Verzeichnis (src/domain/netz.lua): dauerhafte Kennungen ohne Wiederverwendung, wiederholbare Node-Anforderung (Bahnhof, Depot, kombiniert, Anmeldung), Name und Computerlabel von der Leitstelle, Aktivieren und Verwerfen, Speichern und Laden, Dateiversion 3 (Uebernahme einer Datei der Version 2 ohne Bereiche, Gleise und Knoten).
]]

local t = dofile("tests/lib/t.lua")
local cc = dofile("tests/fakes/cc.lua")
local storelib = require("core.store")
local netz = require("domain.netz")

local P = "/crn_data/netz.lua"

local function setup(opts)
  local fs = cc.fs(opts)
  fs.makeDir("/crn_data")
  local store = storelib.new(fs)
  return netz.new({ store = store, path = P }), fs, store
end

return {
  { "Node anfordern: Kennung, Name und Label kommen von der Leitstelle; dieselbe Anforderung liefert dieselbe Node", function()
    local n = setup()
    local node, err = n.claim_node({ claim = "claim-0001", role = "passagierbahnhof" })
    t.ok(node, err)
    t.eq(node.id, "N0001"); t.eq(node.state, "reserviert")
    t.eq(node.name, "Personenbahnhof N0001")
    t.eq(node.label, "N0001 | PBF")
    local again = n.claim_node({ claim = "claim-0001", role = "passagierbahnhof", legacy = "alter_bahnhof" })
    t.eq(again.id, "N0001", "wiederholbar: gleiche Kennung")
    t.eq(again.legacy, "alter_bahnhof", "mit den neuen Angaben")
    local depot = n.claim_node({ claim = "claim-0002", role = "depot" })
    t.eq(depot.id, "N0002"); t.eq(depot.label, "N0002 | DEP"); t.eq(depot.name, "Depot N0002")
    t.eq(#n.nodes(), 2)
  end },
  { "Kombinierte Rollen: feste Reihenfolge, gemeinsames Kuerzel, Name und Label", function()
    local n = setup()
    local node = n.claim_node({ claim = "claim-kombi", roles = { "anmeldung", "depot", "passagierbahnhof" } })
    t.ok(node)
    t.eq(node.roles[1], "passagierbahnhof"); t.eq(node.roles[2], "depot"); t.eq(node.roles[3], "anmeldung")
    t.eq(node.label, "N0001 | PBF DEP ANM")
    t.eq(node.name, "PBF DEP ANM N0001")
  end },
  { "Anmeldung allein gehoert zu einer Betriebsstelle; andere Rollen nehmen keine an", function()
    local n = setup()
    local bf = n.add_station({ name = "Hauptbahnhof", kind = "personenbahnhof" })
    local ok, why = n.claim_node({ claim = "claim-anm-1", role = "anmeldung", station = "BF0099" })
    t.eq(ok, nil); t.contains(why, "Betriebsstelle")
    ok, why = n.claim_node({ claim = "claim-anm-1", role = "anmeldung" })
    t.eq(ok, nil); t.contains(why, "Betriebsstelle")
    ok, why = n.claim_node({ claim = "claim-bf-1", role = "depot", station = bf })
    t.eq(ok, nil); t.contains(why, "anmeldung")
    local node = n.claim_node({ claim = "claim-anm-1", role = "anmeldung", station = bf })
    t.eq(node.id, "N0001"); t.eq(node.station, bf)
    t.eq(node.name, "Anmeldung Hauptbahnhof N0001")
    t.eq(node.label, "N0001 | ANM | " .. bf)
    ok, why = n.remove_station(bf)
    t.eq(ok, nil); t.contains(why, node.id)
    t.eq(n.discard_node(node.id), true)
    t.eq(n.remove_station(bf), true, "nach dem Verwerfen geht es")
  end },
  { "Anforderung wird geprueft: Kennung, Rolle, doppelte Rolle, ungueltige bisherige Kennung", function()
    local n = setup()
    local function try(spec)
      local node, why = n.claim_node(spec)
      return node, why
    end
    local node, why = try({ claim = "kurz", role = "depot" })
    t.eq(node, nil); t.contains(why, "Anforderungskennung")
    node, why = try({ claim = "claim ungueltig!", role = "depot" })
    t.eq(node, nil); t.contains(why, "Anforderungskennung")
    node, why = try({ claim = "claim-ok-1", role = "zentrale" })
    t.eq(node, nil); t.contains(why, "Rolle")
    for _, entfallen in ipairs({ "signal", "knoten" }) do
      node, why = try({ claim = "claim-ok-1", role = entfallen })
      t.eq(node, nil, "die Rolle " .. entfallen .. " gibt es nicht mehr"); t.contains(why, "Rolle")
    end
    node, why = try({ claim = "claim-ok-1", roles = { "depot", "depot" } })
    t.eq(node, nil); t.contains(why, "doppelt")
    node, why = try({ claim = "claim-ok-1", roles = {} })
    t.eq(node, nil)
    node, why = try({ claim = "claim-ok-1", role = "depot", legacy = "mit Leerzeichen" })
    t.eq(node, nil); t.contains(why, "bisherige")
    t.eq(#n.nodes(), 0, "keine Karteileiche, keine verbrauchte Kennung")
    node = try({ claim = "claim-ok-1", role = "depot" })
    t.eq(node.id, "N0001")
    -- dieselbe bisherige Kennung gehoert nur einer Anforderung
    t.ok(try({ claim = "claim-ok-2", role = "depot", legacy = "alt" }))
    node, why = try({ claim = "claim-ok-3", role = "depot", legacy = "alt" })
    t.eq(node, nil); t.contains(why, "schon als")
  end },
  { "Node meldet sich im Betrieb: reserviert wird aktiv; aktive Anforderungen lassen sich nicht verwerfen", function()
    local n = setup()
    local node = n.claim_node({ claim = "claim-ok-1", role = "depot" })
    t.eq(n.mark_active(node.id), true)
    t.eq(n.node(node.id).state, "aktiv")
    local ok, why = n.discard_node(node.id)
    t.eq(ok, nil); t.contains(why, "noch nicht aktiviert")
    t.eq(n.mark_active("N9999"), true, "unbekannte Kennung: nichts zu tun")
    -- eine bereits eingerichtete Node meldet sich unter ihrer bisherigen Kennung
    local legacy = n.claim_node({ claim = "claim-ok-2", role = "passagierbahnhof", legacy = "bf_alt" })
    t.eq(n.mark_active("bf_alt"), true)
    t.eq(n.node(legacy.id).state, "aktiv")
  end },
  { "Verwerfen: die Kennung bleibt vergeben, dieselbe Anforderung ist danach abgelehnt", function()
    local n = setup()
    local node = n.claim_node({ claim = "claim-ok-1", role = "depot" })
    t.eq(n.discard_node(node.id), true)
    t.eq(n.node(node.id).state, "verworfen")
    local ok, why = n.claim_node({ claim = "claim-ok-1", role = "depot" })
    t.eq(ok, nil); t.contains(why, "verworfen")
    local fresh = n.claim_node({ claim = "claim-ok-2", role = "depot" })
    t.eq(fresh.id, "N0002", "die verworfene Kennung bleibt vergeben")
    local nope, why2 = n.discard_node("N9999")
    t.eq(nope, nil); t.contains(why2, "gibt es nicht")
  end },
  { "Speichern und Laden: alles bleibt, Zaehler laufen weiter", function()
    local n, fs, store = setup()
    local bf = n.add_station({ name = "Hafen", kind = "gueterbahnhof", site = "Nord" })
    n.claim_node({ claim = "claim-ok-1", role = "depot" })
    local rev = n.revision()
    local again = netz.new({ store = store, path = P })
    t.eq(again.revision(), rev)
    t.eq(again.node("N0001").label, "N0001 | DEP")
    t.eq(again.station(bf).site_name, "Nord")
    t.eq(again.claim_node({ claim = "claim-ok-1", role = "depot" }).id, "N0001", "auch nach dem Neustart wiederholbar")
    t.eq(again.claim_node({ claim = "claim-ok-2", role = "depot" }).id, "N0002")
    t.eq(again.add_station({ name = "Zweite", kind = "depot" }), "BF0002")
  end },
  { "Speichern schlaegt fehl: alter Stand, keine halbe Aenderung, keine verbrauchte Kennung", function()
    local n, fs = setup()
    n.claim_node({ claim = "claim-ok-1", role = "depot" })
    local rev = n.revision()
    local real = fs.open
    fs.open = function(path, mode)
      if mode ~= "r" and mode ~= "rb" then return nil, "Platte voll" end
      return real(path, mode)
    end
    local ok, why = n.claim_node({ claim = "claim-ok-2", role = "depot" })
    fs.open = real
    t.eq(ok, nil); t.contains(why, "nicht gespeichert")
    t.eq(n.revision(), rev)
    t.eq(#n.nodes(), 1)
    t.eq(n.claim_node({ claim = "claim-ok-2", role = "depot" }).id, "N0002", "die Kennung wurde nicht verbraucht")
  end },
  { "Revision steigt mit jeder Aenderung, nicht bei Abfragen oder abgelehnten Eingaben", function()
    local n = setup()
    t.eq(n.revision(), 0)
    n.claim_node({ claim = "claim-ok-1", role = "depot" })
    t.eq(n.revision(), 1)
    n.nodes(); n.node("N0001"); n.stations(); n.claim_node({ claim = "kurz", role = "depot" })
    t.eq(n.revision(), 1)
    n.add_station({ name = "A", kind = "depot" })
    t.eq(n.revision(), 2)
  end },
  { "Datei der Version 2: Bereiche, Gleise, Knoten und Gleisbeziehungen entfallen, Nodes und Betriebsstellen bleiben", function()
    local n, fs, store = setup()
    store.save(P, {
      version = 2, revision = 17,
      counters = { bereich = 3, gleis = 9, node = 4, betriebsstelle = 2, standort = 1, knoten = 1 },
      areas = { B0001 = { name = "West-Ost", ends = { "West", "Ost" } } },
      tracks = { A0001 = { area = "B0001", name = "Gleis 1", direction = "Ost" } },
      junctions = { K0001 = { name = "Nord", connections = {}, routes = {}, conflicts = {} } },
      stations = { BF0001 = { name = "Hauptbahnhof", kind = "personenbahnhof", links = { A0001 = { relation = "bahnhofsgleis" } }, rev = 3 } },
      sites = {},
      tokens = { x = "B0001" },
      nodes = {
        N0001 = { claim = "claim-bahnhof-1", role = "passagierbahnhof", roles = { "passagierbahnhof" }, area = "B0001", tracks = { "A0001" }, state = "aktiv", name = "Personenbahnhof West-Ost N0001", label = "N0001 | PBF | B0001" },
        N0002 = { claim = "claim-signal-1", role = "signal", roles = { "signal" }, area = "B0001", tracks = { "A0001" }, state = "aktiv", name = "Signal West-Ost N0002", label = "N0002 | SIG | B0001" },
        N0003 = { claim = "claim-signal-2", role = "signal", roles = { "signal" }, area = "B0001", tracks = { "A0001" }, state = "reserviert", name = "Signal West-Ost N0003", label = "N0003 | SIG | B0001" },
        N0004 = { claim = "claim-kombi-01", role = "passagierbahnhof", roles = { "passagierbahnhof", "signal" }, area = "B0001", tracks = { "A0001" }, state = "aktiv", name = "PBF SIG N0004", label = "N0004 | PBF SIG | B0001" },
      },
    })
    local m = netz.new({ store = store, path = P })
    t.eq(m.blocked, false)
    t.eq(m.node("N0001").state, "aktiv"); t.eq(m.node("N0001").roles[1], "passagierbahnhof")
    t.eq(m.node("N0002").state, "aktiv", "eine aktive Signal-Node bleibt sichtbar (Bediener legt sie still)")
    t.eq(#m.node("N0002").roles, 0, "ohne verbleibende Rolle")
    t.eq(m.node("N0003").state, "verworfen", "eine nie aktivierte Signal-Anforderung gilt als verworfen")
    t.eq(#m.node("N0004").roles, 1, "die Rolle signal faellt aus der Rollenliste")
    t.eq(m.node("N0004").roles[1], "passagierbahnhof")
    t.eq(m.station("BF0001").name, "Hauptbahnhof")
    t.eq(m.add_station({ name = "Neu", kind = "depot" }), "BF0003", "Zaehler laufen weiter")
    local saved = store.load(P)
    t.eq(saved.version, 3)
    t.eq(saved.areas, nil); t.eq(saved.tracks, nil); t.eq(saved.junctions, nil); t.eq(saved.tokens, nil)
    t.eq(saved.stations.BF0001.links, nil)
    t.eq(saved.nodes.N0001.area, nil); t.eq(saved.nodes.N0001.tracks, nil)
    t.eq(saved.counters.node, 4)
    -- eine neue Anforderung bekommt die naechste Kennung; die bekannte Anforderung behaelt ihre und bekommt das schlanke Label
    t.eq(m.claim_node({ claim = "claim-neu-0001", role = "depot" }).id, "N0005")
    t.eq(m.claim_node({ claim = "claim-bahnhof-1", role = "passagierbahnhof" }).label, "N0001 | PBF")
  end },
  { "Datei von einem neueren Programm wird gelesen, aber nie veraendert", function()
    local n, fs, store = setup()
    n.claim_node({ claim = "claim-ok-1", role = "depot" })
    local future = store.load(P)
    future.version = 99
    store.save(P, future)
    local f = netz.new({ store = store, path = P })
    t.eq(f.blocked, true)
    t.eq(f.node("N0001").label, "N0001 | DEP", "lesen geht")
    local ok, why = f.claim_node({ claim = "claim-ok-2", role = "depot" })
    t.eq(ok, nil); t.contains(why, "neueren Programm")
    ok = f.add_station({ name = "X", kind = "depot" })
    t.eq(ok, nil)
    t.eq(store.load(P).version, 99, "die Datei bleibt unveraendert")
  end },
}
