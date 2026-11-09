--[[
Purpose: Node-Verzeichnis (src/domain/netz.lua): dauerhafte Kennungen ohne Wiederverwendung, wiederholbare Node-Anforderung (Bahnhof, Depot, kombiniert, Anmeldung), Name und Computerlabel von der Leitstelle, Aktivieren und Verwerfen, Speichern und Laden, Dateiversion 5 (Uebernahme aelterer Dateien: ohne Bereiche, Gleise, Knoten, Betriebsstellen und Standorte; die Anmeldung nennt den Bahnhof mit seinem Namen).
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
    local node, err = n.claim_node({ claim = "claim-0001", role = "bahnhof" })
    t.ok(node, err)
    t.eq(node.id, "N0001"); t.eq(node.state, "reserviert")
    t.eq(node.name, "Bahnhof N0001")
    t.eq(node.label, "N0001 | BHF")
    local again = n.claim_node({ claim = "claim-0001", role = "bahnhof", legacy = "alter_bahnhof" })
    t.eq(again.id, "N0001", "wiederholbar: gleiche Kennung")
    t.eq(again.legacy, "alter_bahnhof", "mit den neuen Angaben")
    -- die alten Bahnhofsnamen (Passagierbahnhof, Gueterbahnhof, Depot) nimmt die Leitstelle noch an: sie sind eine Rolle
    local depot = n.claim_node({ claim = "claim-0002", role = "depot" })
    t.eq(depot.id, "N0002"); t.eq(depot.label, "N0002 | BHF"); t.eq(depot.name, "Bahnhof N0002"); t.eq(depot.role, "bahnhof")
    t.eq(#n.nodes(), 2)
  end },
  { "Kombinierte Rollen: feste Reihenfolge, gemeinsames Kuerzel, Name und Label", function()
    local n = setup()
    local node = n.claim_node({ claim = "claim-kombi", roles = { "anmeldung", "bahnhof" } })
    t.ok(node)
    t.eq(node.roles[1], "bahnhof"); t.eq(node.roles[2], "anmeldung")
    t.eq(node.label, "N0001 | BHF ANM")
    t.eq(node.name, "BHF ANM N0001")
    -- alte Angaben (Bahnhof und Depot auf einem Computer) werden zu einer Rolle; dieselbe Angabe zweimal bleibt ein Fehler
    local old = n.claim_node({ claim = "claim-alt-01", roles = { "passagierbahnhof", "depot", "anmeldung" } })
    t.eq(#old.roles, 2); t.eq(old.label, "N0002 | BHF ANM")
    local twice, why = n.claim_node({ claim = "claim-alt-02", roles = { "bahnhof", "bahnhof" } })
    t.eq(twice, nil); t.contains(why, "doppelt")
  end },
  { "Anmeldung allein nennt den Bahnhof (seinen Namen); andere Rollen nehmen keinen an", function()
    local n = setup()
    local ok, why = n.claim_node({ claim = "claim-anm-1", role = "anmeldung" })
    t.eq(ok, nil); t.contains(why, "Bahnhof")
    ok, why = n.claim_node({ claim = "claim-anm-1", role = "anmeldung", station = "" })
    t.eq(ok, nil); t.contains(why, "Bahnhof")
    ok, why = n.claim_node({ claim = "claim-anm-1", role = "anmeldung", station = string.rep("x", 41) })
    t.eq(ok, nil); t.contains(why, "zu lang")
    ok, why = n.claim_node({ claim = "claim-anm-1", role = "anmeldung", station = "Haupt\1bahnhof" })
    t.eq(ok, nil); t.contains(why, "ungueltig")
    ok, why = n.claim_node({ claim = "claim-bf-1", role = "bahnhof", station = "Hauptbahnhof" })
    t.eq(ok, nil); t.contains(why, "anmeldung")
    local node = n.claim_node({ claim = "claim-anm-1", role = "anmeldung", station = "  Hauptbahnhof " })
    t.eq(node.id, "N0001"); t.eq(node.station, "Hauptbahnhof")
    t.eq(node.name, "Anmeldung Hauptbahnhof N0001")
    t.eq(node.label, "N0001 | ANM", "das Label nennt den Bahnhof nicht")
    -- Create-Namen duerfen mehr Zeichen enthalten: Name und Label der Node bleiben aus erlaubten Zeichen
    local special = n.claim_node({ claim = "claim-anm-2", role = "anmeldung", station = "Weizenhof Sued.1 \195\188" })
    t.eq(special.station, "Weizenhof Sued.1 \195\188")
    t.eq(special.name, "Anmeldung Weizenhof Sued1 N0002")
    t.ok(special.name:match("^[%w _%-]+$"), special.name)
  end },
  { "Bahnhof umbenannt: die Anmeldungen dieses Bahnhofs tragen den neuen Namen, Kennung und Label bleiben", function()
    local n = setup()
    local a = n.claim_node({ claim = "claim-anm-1", role = "anmeldung", station = "Hafen" })
    local b = n.claim_node({ claim = "claim-anm-2", role = "anmeldung", station = "Hafen" })
    local c = n.claim_node({ claim = "claim-anm-3", role = "anmeldung", station = "Dorf" })
    local kombi = n.claim_node({ claim = "claim-kombi", roles = { "bahnhof", "anmeldung" } })
    t.eq(n.discard_node(b.id), true)
    local rev = n.revision()
    t.eq(n.rename_station("Hafen", "Hafen Nord"), 1, "nur die nicht verworfene Anmeldung")
    t.eq(n.revision(), rev + 1)
    t.eq(n.node(a.id).station, "Hafen Nord"); t.eq(n.node(a.id).name, "Anmeldung Hafen Nord " .. a.id); t.eq(n.node(a.id).label, a.label)
    t.eq(n.node(c.id).station, "Dorf")
    t.eq(n.node(kombi.id).station, nil)
    local bad, why = n.rename_station("Dorf", "")
    t.eq(bad, nil); t.contains(why, "fehlt")
    t.eq(n.node(c.id).station, "Dorf")
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
    local legacy = n.claim_node({ claim = "claim-ok-2", role = "bahnhof", legacy = "bf_alt" })
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
    n.claim_node({ claim = "claim-ok-1", role = "depot" })
    n.claim_node({ claim = "claim-anm-1", role = "anmeldung", station = "Hafen" })
    local rev = n.revision()
    local again = netz.new({ store = store, path = P })
    t.eq(again.revision(), rev)
    t.eq(again.node("N0001").label, "N0001 | BHF")
    t.eq(again.node("N0002").station, "Hafen")
    t.eq(again.claim_node({ claim = "claim-ok-1", role = "depot" }).id, "N0001", "auch nach dem Neustart wiederholbar")
    t.eq(again.claim_node({ claim = "claim-ok-2", role = "depot" }).id, "N0003")
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
    n.nodes(); n.node("N0001"); n.claim_node({ claim = "kurz", role = "depot" })
    t.eq(n.revision(), 1)
    n.claim_node({ claim = "claim-ok-2", role = "depot" })
    t.eq(n.revision(), 2)
  end },
  { "Datei der Version 2: Bereiche, Gleise, Knoten, Gleisbeziehungen, Betriebsstellen und Standorte entfallen, Nodes bleiben", function()
    local n, fs, store = setup()
    store.save(P, {
      version = 2, revision = 17,
      counters = { bereich = 3, gleis = 9, node = 6, betriebsstelle = 2, standort = 1, knoten = 1 },
      areas = { B0001 = { name = "West-Ost", ends = { "West", "Ost" } } },
      tracks = { A0001 = { area = "B0001", name = "Gleis 1", direction = "Ost" } },
      junctions = { K0001 = { name = "Nord", connections = {}, routes = {}, conflicts = {} } },
      stations = { BF0001 = { name = "Hauptbahnhof", kind = "personenbahnhof", links = { A0001 = { relation = "bahnhofsgleis" } }, rev = 3 } },
      sites = { S0001 = { name = "Nord" } },
      tokens = { x = "B0001" },
      nodes = {
        N0001 = { claim = "claim-bahnhof-1", role = "bahnhof", roles = { "bahnhof" }, area = "B0001", tracks = { "A0001" }, state = "aktiv", name = "Personenbahnhof West-Ost N0001", label = "N0001 | PBF | B0001" },
        N0002 = { claim = "claim-signal-1", role = "signal", roles = { "signal" }, area = "B0001", tracks = { "A0001" }, state = "aktiv", name = "Signal West-Ost N0002", label = "N0002 | SIG | B0001" },
        N0003 = { claim = "claim-signal-2", role = "signal", roles = { "signal" }, area = "B0001", tracks = { "A0001" }, state = "reserviert", name = "Signal West-Ost N0003", label = "N0003 | SIG | B0001" },
        N0004 = { claim = "claim-kombi-01", role = "bahnhof", roles = { "bahnhof", "signal" }, area = "B0001", tracks = { "A0001" }, state = "aktiv", name = "PBF SIG N0004", label = "N0004 | PBF SIG | B0001" },
        N0005 = { claim = "claim-anm-0001", role = "anmeldung", roles = { "anmeldung" }, station = "BF0001", state = "aktiv", name = "Anmeldung Hauptbahnhof N0005", label = "N0005 | ANM | BF0001" },
        N0006 = { claim = "claim-anm-0002", role = "anmeldung", roles = { "anmeldung" }, station = "BF0077", state = "aktiv", name = "Anmeldung Weg N0006", label = "N0006 | ANM | BF0077" },
      },
    })
    local m = netz.new({ store = store, path = P })
    t.eq(m.blocked, false)
    t.eq(m.node("N0001").state, "aktiv"); t.eq(m.node("N0001").roles[1], "bahnhof")
    t.eq(m.node("N0002").state, "aktiv", "eine aktive Signal-Node bleibt sichtbar (Bediener legt sie still)")
    t.eq(#m.node("N0002").roles, 0, "ohne verbleibende Rolle")
    t.eq(m.node("N0003").state, "verworfen", "eine nie aktivierte Signal-Anforderung gilt als verworfen")
    t.eq(#m.node("N0004").roles, 1, "die Rolle signal faellt aus der Rollenliste")
    t.eq(m.node("N0004").roles[1], "bahnhof")
    -- die Betriebsstelle wird zum Namen des Bahnhofs; eine Kennung ohne Eintrag ergibt keinen Bahnhof
    t.eq(m.node("N0005").station, "Hauptbahnhof"); t.eq(m.node("N0005").name, "Anmeldung Hauptbahnhof N0005"); t.eq(m.node("N0005").label, "N0005 | ANM")
    t.eq(m.node("N0006").station, nil); t.eq(m.node("N0006").name, "Anmeldung N0006")
    t.eq(m.claim_node({ claim = "claim-neu-0001", role = "depot" }).id, "N0007", "Zaehler laufen weiter")
    local saved = store.load(P)
    t.eq(saved.version, 5)
    t.eq(saved.areas, nil); t.eq(saved.tracks, nil); t.eq(saved.junctions, nil); t.eq(saved.tokens, nil)
    t.eq(saved.stations, nil); t.eq(saved.sites, nil)
    t.eq(saved.counters.betriebsstelle, nil); t.eq(saved.counters.standort, nil)
    t.eq(saved.nodes.N0001.area, nil); t.eq(saved.nodes.N0001.tracks, nil)
    t.eq(saved.counters.node, 7)
    -- eine neue Anforderung bekommt die naechste Kennung; die bekannte Anforderung behaelt ihre und bekommt das schlanke Label
    t.eq(m.node("N0001").label, "N0001 | BHF", "Name und Label tragen den neuen Code (Version 4)")
    t.eq(m.node("N0001").name, "Bahnhof N0001")
    t.eq(m.node("N0004").label, "N0004 | BHF"); t.eq(m.node("N0004").name, "Bahnhof N0004")
    t.eq(m.claim_node({ claim = "claim-bahnhof-1", role = "bahnhof" }).label, "N0001 | BHF")
  end },
  { "Datei von einem neueren Programm wird gelesen, aber nie veraendert", function()
    local n, fs, store = setup()
    n.claim_node({ claim = "claim-ok-1", role = "depot" })
    local future = store.load(P)
    future.version = 99
    store.save(P, future)
    local f = netz.new({ store = store, path = P })
    t.eq(f.blocked, true)
    t.eq(f.node("N0001").label, "N0001 | BHF", "lesen geht")
    local ok, why = f.claim_node({ claim = "claim-ok-2", role = "depot" })
    t.eq(ok, nil); t.contains(why, "neueren Programm")
    t.eq(f.rename_station("A", "B"), nil)
    t.eq(store.load(P).version, 99, "die Datei bleibt unveraendert")
  end },
}
