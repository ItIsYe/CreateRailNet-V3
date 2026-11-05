--[[
Purpose: Anmeldung und kombinierte Rollen im Verzeichnis-Ablauf (Konzept 9.1, 12.1): Bahnhof/Depot/Signal auf einem Computer, die Anmeldung allein bei einer Betriebsstelle und zusammen mit einem Bahnhof; Kennung, Name, Label und Zuordnung zum Verzeichnis.
]]

local t = dofile("tests/lib/t.lua")
local H = dofile("tests/lib/harness.lua")
local netzlib = require("domain.netz")

local function setup(opts)
  opts = opts or {}
  local h = H.new()
  local z = h.add_node({ id = "hauptstelle", roles = { "zentrale" }, tracks = {} })
  local netz = z.node.roles.zentrale.netz
  netz.add_area({ name = "Hauptbahnhof", ends = { "Einfahrt", "Ausfahrt" }, count = 2, pattern = "gleich" })
  assert(netz.add_station({ name = "Westbahnhof", kind = "personenbahnhof" }))
  assert(netz.add_station({ name = "Hafen", kind = "gueterbahnhof" }))
  local d = h.add_blank({ id = "neu", stations = { "Hof A", "Hof B" } })
  d.world.add_signal("Create_Signal_1"); d.world.add_signal("Create_Signal_2")
  h.step(1)
  local v = d.view()
  v.set_page("einrichtung")
  return h, z, d, v, netz
end

local function screen(d) return d.node.setup.session().screen end

local function join(h, d, v, roles, before_roles)
  d.tap(v, "act:start")
  d.tap(v, "sel:modus:2"); d.tap(v, "act:weiter")
  h.step(5); d.node.render()
  d.tap(v, "sel:netzwahl:1"); d.tap(v, "act:weiter")
  if before_roles then before_roles() end
  for _, r in ipairs(roles) do d.tap_row(v, "rollen", r) end
  d.tap(v, "act:weiter")
  h.step(3); d.node.render()
end

return {
  { "Domain: kombinierte Rollen, Reihenfolge, Name und Label; knoten allein; doppelte Rolle; Anmeldung bei einer Betriebsstelle", function()
    local netz = netzlib.new({})
    netz.add_area({ name = "Hauptbahnhof", ends = { "Ein", "Aus" }, count = 2 })
    assert(netz.add_station({ name = "Westbahnhof", kind = "personenbahnhof" }))
    local node = assert(netz.claim_node({ claim = "kombi-claim-01", roles = { "signal", "passagierbahnhof" }, area = "B0001", tracks = { "A0001", "A0002" } }))
    t.eq(node.role, "passagierbahnhof"); t.eq(node.roles[1], "passagierbahnhof"); t.eq(node.roles[2], "signal")
    t.eq(node.label, "N0001 | PBF SIG | B0001"); t.eq(node.name, "PBF SIG Hauptbahnhof N0001")
    local single = assert(netz.claim_node({ claim = "kombi-claim-02", role = "depot", area = "B0001", tracks = { "A0001" } }))
    t.eq(single.name, "Depot Hauptbahnhof N0002"); t.eq(single.roles[1], "depot")
    local function bad(spec, expect, why)
      spec.claim = spec.claim or "kombi-claim-09"
      local r, err = netz.claim_node(spec)
      t.eq(r, nil, why); t.contains(err, expect)
    end
    bad({ roles = { "signal", "signal" }, area = "B0001", tracks = { "A0001" } }, "doppelt", "doppelte Rolle")
    bad({ roles = { "knoten", "signal" }, junction = "K0001" }, "allein", "knoten kombiniert")
    bad({ roles = { "unsinn" }, area = "B0001", tracks = { "A0001" } }, "keine Anforderung", "unbekannte Rolle")
    bad({ roles = {}, area = "B0001", tracks = { "A0001" } }, "keine Anforderung", "leer")
    bad({ role = "signal", area = "B0001", tracks = { "A0001" }, station = "BF0001" }, "Nur die Rolle anmeldung", "Station bei Signal")
    local anm = assert(netz.claim_node({ claim = "kombi-claim-03", role = "anmeldung", station = "BF0001" }))
    t.eq(anm.label, "N0003 | ANM | BF0001"); t.eq(anm.name, "Anmeldung Westbahnhof N0003"); t.eq(anm.station, "BF0001"); t.eq(#anm.tracks, 0)
    bad({ role = "anmeldung", station = "BF9999" }, "gibt es nicht", "Station unbekannt")
    bad({ role = "anmeldung" }, "gibt es nicht", "Station fehlt")
    bad({ role = "anmeldung", station = "BF0001", area = "B0001", tracks = { "A0001" } }, "ohne Bereich", "Anmeldung mit Gleisen")
    -- die Betriebsstelle laesst sich nicht loeschen, solange die Anmeldung sie nutzt
    local ok, why = netz.remove_station("BF0001")
    t.eq(ok, nil); t.contains(why, "N0003")
    assert(netz.discard_node("N0003"))
    assert(netz.remove_station("BF0001"))
    -- Anmeldung zusammen mit einem Bahnhof: Bereich und Gleise, keine Betriebsstelle noetig
    local both = assert(netz.claim_node({ claim = "kombi-claim-04", roles = { "gueterbahnhof", "anmeldung" }, area = "B0001", tracks = { "A0001" } }))
    t.eq(both.label, "N0004 | GBF ANM | B0001")
  end },
  { "Bahnhof und Signal auf einem Computer: ein Bereich, ein Label, Bahnhof/Signal je Gleis, aktiv", function()
    local h, z, d, v, netz = setup()
    join(h, d, v, { "Passagierbahnhof", "Signal" })
    t.eq(screen(d), "2.bereich", d.text(v))
    d.tap(v, "sel:bereich:1"); h.step(3); d.node.render()
    d.tap(v, "act:weiter"); d.tap(v, "act:weiter")
    h.step(3); d.node.render()
    t.eq(screen(d), "3.geraete", d.text(v))
    t.eq(netz.node("N0001").label, "N0001 | PBF SIG | B0001")
    d.tap_row(v, "geraete", "Create_Station_1"); d.tap_row(v, "geraete", "Create_Station_2")
    d.tap_row(v, "geraete", "Create_Signal_1"); d.tap_row(v, "geraete", "Create_Signal_2")
    d.tap(v, "act:weiter")
    t.eq(screen(d), "4.gleise", d.text(v))
    d.tap(v, "sel:gleise:1"); d.tap(v, "act:bearbeiten")
    t.eq(screen(d), "4.g.bahnhof", d.text(v))
    d.tap_row(v, "bahnhof", "Create_Station_1"); d.tap(v, "act:weiter")
    t.eq(screen(d), "4.g.signale", d.text(v))
    d.tap_row(v, "signale", "Create_Signal_1"); d.tap(v, "act:weiter")
    t.eq(screen(d), "4.gleise", d.text(v), "kein Ausgang-Menue")
    d.tap(v, "sel:gleise:2"); d.tap(v, "act:bearbeiten")
    d.tap_row(v, "bahnhof", "Create_Station_2"); d.tap(v, "act:weiter")
    d.tap_row(v, "signale", "Create_Signal_2"); d.tap(v, "act:weiter")
    d.tap(v, "act:weiter")
    t.eq(screen(d), "5.test", d.text(v))
    d.tap(v, "act:alle_pruefen"); d.tap(v, "act:alle_starten")
    t.contains(v.hint, "0 Fehler")
    d.tap(v, "act:weiter")
    d.tap(v, "act:speichern")
    local config = d.node.config
    t.eq(config.status, "aktiv", d.text(v))
    t.eq(config.node.roles[1], "passagierbahnhof"); t.eq(config.node.roles[2], "signal")
    t.eq(config.node.label, "N0001 | PBF SIG | B0001")
    t.eq(d.label, "N0001 | PBF SIG | B0001")
    h.step(30)
    t.eq(netz.node("N0001").state, "aktiv")
  end },
  { "Bahnhof und Anmeldung zusammen: nach den Gleisen folgt die Wahl der Anmeldestation", function()
    local h, z, d, v, netz = setup()
    join(h, d, v, { "Passagierbahnhof", "Anmeldung" })
    t.eq(screen(d), "2.bereich", d.text(v))
    d.tap(v, "sel:bereich:1"); h.step(3); d.node.render()
    d.tap(v, "act:weiter"); d.tap(v, "act:weiter")
    h.step(3); d.node.render()
    t.eq(netz.node("N0001").label, "N0001 | PBF ANM | B0001")
    d.tap_row(v, "geraete", "Create_Station_1"); d.tap_row(v, "geraete", "Create_Station_2")
    d.tap(v, "act:weiter")
    d.tap(v, "sel:gleise:1"); d.tap(v, "act:bearbeiten")
    d.tap_row(v, "bahnhof", "Create_Station_1"); d.tap(v, "act:weiter")
    d.tap(v, "sel:gleise:2"); d.tap(v, "act:bearbeiten")
    d.tap_row(v, "bahnhof", "Create_Station_2"); d.tap(v, "act:weiter")
    d.tap(v, "act:weiter")
    t.eq(screen(d), "4.anmeldung", d.text(v))
  end },
  { "Anmeldung allein: Betriebsstelle waehlen, Kennung, Geraete, Anmeldestation, Pruefung, aktiv", function()
    local h, z, d, v, netz = setup()
    join(h, d, v, { "Anmeldung" })
    t.eq(screen(d), "2.station", d.text(v))
    t.contains(d.text(v), "Westbahnhof"); t.contains(d.text(v), "Hafen")
    d.tap(v, "act:weiter")
    t.contains(v.hint, "Bitte eine Betriebsstelle")
    d.tap(v, "sel:station_wahl:1")
    d.tap(v, "act:weiter")
    h.step(3); d.node.render()
    t.eq(screen(d), "3.geraete", d.text(v))
    t.eq(netz.node("N0001").role, "anmeldung"); t.eq(netz.node("N0001").station, "BF0001")
    d.tap_row(v, "geraete", "Create_Station_1")
    d.tap(v, "act:weiter")
    t.eq(screen(d), "4.anmeldung", d.text(v))
    d.tap_row(v, "anmeldung", "Create_Station_1")
    d.tap(v, "act:weiter")
    t.eq(screen(d), "5.test", d.text(v))
    d.tap(v, "act:alle_pruefen")
    d.tap(v, "act:weiter")
    d.tap(v, "act:speichern")
    local config = d.node.config
    t.eq(config.status, "aktiv", d.text(v))
    t.eq(config.node.label:match("ANM") ~= nil, true)
    t.eq(config.node.station, netz.node("N0001").station)
  end },
  { "Anmeldung: leeres Netz zeigt einen Hinweis, 'Von Hand' geht den bisherigen Weg, Ausfall der Leitstelle meldet", function()
    local h, z, d, v, netz = setup()
    for _, st in ipairs(netz.stations()) do assert(netz.remove_station(st.id)) end
    join(h, d, v, { "Anmeldung" })
    t.contains(d.text(v), "noch keine Betriebsstelle")
    d.tap(v, "act:von_hand")
    t.eq(screen(d), "2.name", d.text(v))
    local h2, z2, d2, v2 = setup()
    join(h2, d2, v2, { "Anmeldung" }, function() z2.node.handle = function() end end)
    h2.step(12); d2.node.render()
    t.contains(d2.text(v2), "antwortet nicht")
  end },
  { "Wire: Betriebsstellen seitenweise, ungueltige Anfragen abgelehnt", function()
    local h, z, d, v, netz = setup()
    local role = z.node.roles.zentrale
    d.node.directory_areas("hauptstelle"); h.step(3)
    local replies = {}
    local real = z.node.reply
    z.node.reply = function(m, status, payload) replies[#replies + 1] = { status = status, payload = payload } return real(m, status, payload) end
    local function ask(payload)
      role.on_message(d.node.replace_factory.make("abfrage", "hauptstelle", payload), "ok")
      return replies[#replies]
    end
    local first = ask({ kind = "betriebsstellen_liste" })
    t.eq(first.status, "ok"); t.eq(#first.payload.stations, 2); t.eq(first.payload.stations[1].name, "Westbahnhof")
    local after = ask({ kind = "betriebsstellen_liste", after = "BF0001" })
    t.eq(#after.payload.stations, 1); t.eq(after.payload.stations[1].id, "BF0002")
    t.eq(#ask({ kind = "betriebsstellen_liste", after = 7 }).payload.stations, 2, "falscher Typ wird wie 'ab Anfang' behandelt")
    t.eq(ask({ kind = "node_anfordern", claim = "wire-claim-001", role = "anmeldung", station = 5 }).status, "abgelehnt")
    t.eq(ask({ kind = "node_anfordern", claim = "wire-claim-001", roles = "signal", area = "B0001", tracks = { "A0001" } }).status, "abgelehnt")
    local ok = ask({ kind = "node_anfordern", claim = "wire-claim-001", role = "anmeldung", station = "BF0001" })
    t.eq(ok.status, "ok"); t.eq(ok.payload.node.label, "N0001 | ANM | BF0001")
  end },
}
