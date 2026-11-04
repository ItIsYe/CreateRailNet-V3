--[[
Purpose: Einrichtung eines Bahnhofs ueber das Netzverzeichnis (Konzept 6, 12.1): Kennung, Name, Label und Gleise kommen aus der Leitstelle, Geraete und Ausgaenge werden wie bisher zugeordnet, die Pruefungen laufen wie bisher; Gleise aus dem Verzeichnis lassen sich lokal nicht anlegen, kopieren oder loeschen.
]]

local t = dofile("tests/lib/t.lua")
local H = dofile("tests/lib/harness.lua")
local storelib = require("core.store")

local function setup(opts)
  opts = opts or {}
  local h = H.new()
  local z = h.add_node({ id = "hauptstelle", roles = { "zentrale" }, tracks = {} })
  local netz = z.node.roles.zentrale.netz
  netz.add_area({ name = "Hauptbahnhof", ends = { "Einfahrt", "Ausfahrt" }, count = opts.tracks or 2, pattern = "gleich" })
  local d = h.add_blank({ id = "neu", stations = { "Hof A", "Hof B", "Hof C" } })
  h.step(1)
  local v = d.view()
  v.set_page("einrichtung")
  return h, z, d, v, netz
end

local function screen(d) return d.node.setup.session().screen end

local function to_devices(h, d, v, role_text)
  d.tap(v, "act:start")
  d.tap(v, "sel:modus:2"); d.tap(v, "act:weiter")
  h.step(5); d.node.render()
  d.tap(v, "sel:netzwahl:1"); d.tap(v, "act:weiter")
  d.tap_row(v, "rollen", role_text or "Passagierbahnhof"); d.tap(v, "act:weiter")
  h.step(3); d.node.render()
  d.tap(v, "sel:bereich:1")
  h.step(3); d.node.render()
  d.tap(v, "act:weiter")
  d.tap(v, "act:weiter")
  h.step(3); d.node.render()
end

return {
  { "Bahnhof: Kennung, Name und Gleise kommen aus dem Verzeichnis; Geraete wie bisher, keine Ausgangswahl; aktiv mit dem Label der Leitstelle", function()
    local h, z, d, v, netz = setup()
    to_devices(h, d, v)
    t.eq(screen(d), "3.geraete", d.text(v))
    t.eq(netz.node("N0001").role, "passagierbahnhof")
    t.eq(netz.node("N0001").name, "Personenbahnhof Hauptbahnhof N0001")
    d.tap_row(v, "geraete", "Create_Station_1"); d.tap_row(v, "geraete", "Create_Station_2")
    d.tap(v, "act:weiter")
    t.eq(screen(d), "4.gleise", d.text(v))
    t.contains(d.text(v), "Gleis 1"); t.contains(d.text(v), "Gleis 2")
    t.ok(not d.has(v, "Kopieren"), "Gleise aus dem Verzeichnis lassen sich nicht kopieren: " .. d.text(v))
    t.ok(not d.has(v, "Entfernen"), d.text(v))
    -- Gleis 1 und 2: nur der Bahnhof (Name und Richtung stehen schon fest); einen Freigabeausgang gibt es im Assistenten nicht mehr
    d.tap(v, "sel:gleise:1"); d.tap(v, "act:bearbeiten")
    t.eq(screen(d), "4.g.bahnhof", d.text(v))
    d.tap_row(v, "bahnhof", "Create_Station_1"); d.tap(v, "act:weiter")
    t.eq(screen(d), "4.gleise", d.text(v), "nach dem Bahnhof geht es zurueck zur Gleisliste, kein Ausgang-Menue")
    t.ok(not d.has(v, "Welcher Ausgang"), d.text(v))
    d.tap(v, "sel:gleise:2"); d.tap(v, "act:bearbeiten")
    d.tap_row(v, "bahnhof", "Create_Station_2"); d.tap(v, "act:weiter")
    t.eq(screen(d), "4.gleise", d.text(v))
    d.tap(v, "act:weiter")
    t.eq(screen(d), "5.test", d.text(v))
    d.tap(v, "act:alle_lesen")
    t.ok(not d.has(v, "Ausgang: Gleis"), "keine Ausgangspruefungen ohne Ausgang: " .. d.text(v))
    d.tap(v, "act:weiter")
    t.eq(screen(d), "6.fertig", d.text(v))
    d.tap(v, "act:speichern")
    local config = d.node.config
    t.eq(config.status, "aktiv", d.text(v))
    t.eq(config.node.id, "N0001"); t.eq(config.node.label, "N0001 | PBF | B0001")
    t.eq(config.node.roles[1], "passagierbahnhof")
    local tracks = {}
    for _, tr in pairs(config.tracks) do tracks[tr.name] = tr end
    t.eq(tracks["Gleis 1"].dir.id, "A0001"); t.eq(tracks["Gleis 1"].dir.direction, "Ausfahrt")
    t.ok(tracks["Gleis 1"].station, "Bahnhof zugeordnet")
    t.eq(tracks["Gleis 1"].release, nil, "kein Redstone-Ausgang: die Freigabe laeuft ueber die Station")
    t.eq(d.label, "N0001 | PBF | B0001", "Computerlabel gesetzt")
    local saved = storelib.new(d.fs).load("/crn_data/config.lua")
    t.eq(saved.status, "aktiv"); t.eq(saved.node.claimed, true)
    -- im Betrieb meldet sich die Node; das Verzeichnis fuehrt sie danach als aktiv
    h.step(30)
    t.eq(netz.node("N0001").state, "aktiv")
  end },
  { "Alle pruefen (vorhandene Ausgaenge): lesende laufen beim Oeffnen von selbst, die schaltenden werden zusammen bestaetigt und nacheinander ausgefuehrt", function()
    local h, z, d, v, netz = setup()
    to_devices(h, d, v)
    d.tap_row(v, "geraete", "Create_Station_1"); d.tap_row(v, "geraete", "Create_Station_2")
    d.tap(v, "act:weiter")
    d.tap(v, "sel:gleise:1"); d.tap(v, "act:bearbeiten")
    d.tap_row(v, "bahnhof", "Create_Station_1"); d.tap(v, "act:weiter")
    d.tap(v, "sel:gleise:2"); d.tap(v, "act:bearbeiten")
    d.tap_row(v, "bahnhof", "Create_Station_2"); d.tap(v, "act:weiter")
    -- Ausgaenge einer aelteren Einrichtung bleiben moeglich (hier ueber die Schnittstelle gesetzt) und werden weiter geprueft
    local wiz = d.node.setup.session().wiz
    local tid = wiz.tracks()
    t.eq(wiz.set_release(tid[1], { side = "back" }), true); t.eq(wiz.set_release(tid[2], { side = "top" }), true)
    d.tap(v, "act:weiter")
    t.eq(screen(d), "5.test", d.text(v))
    for _, test in ipairs(wiz.tests()) do
      if test.kind == "lesen" then t.eq(wiz.test_state(test.id, nil, test), "ok", "lesende Pruefungen sind schon gelaufen: " .. test.title) end
      if test.kind == "schalten" then t.eq(wiz.test_state(test.id, nil, test), "offen") end
    end
    d.tap(v, "act:alle_pruefen")
    t.eq(screen(d), "5.alle_bestaetigen", d.text(v))
    t.contains(d.text(v), "Ausgang: Gleis 1"); t.contains(d.text(v), "Ausgang: Gleis 2")
    t.contains(d.text(v), "vorbereitet")
    d.tap(v, "act:alle_abbruch")
    t.eq(screen(d), "5.test"); t.contains(v.hint, "nicht gestartet")
    t.eq(d.world.sides.back, false)
    d.tap(v, "act:alle_pruefen")
    d.tap(v, "act:alle_starten")
    t.eq(screen(d), "5.test", d.text(v))
    t.contains(v.hint, "2 ok, 0 Fehler")
    t.eq(d.world.sides.back, false); t.eq(d.world.sides.top, false)
    d.tap(v, "act:alle_pruefen")
    t.contains(v.hint, "0 ok, 0 Fehler", "nichts mehr offen: kein weiterer Bestaetigungsbildschirm")
    t.eq(screen(d), "5.test")
    d.tap(v, "act:weiter")
    t.eq(screen(d), "6.fertig")
    d.tap(v, "act:speichern")
    t.eq(d.node.config.status, "aktiv")
  end },
  { "Depot geht denselben Weg; die Rolle bestimmt Kuerzel und Namen", function()
    local h, z, d, v, netz = setup({ tracks = 1 })
    to_devices(h, d, v, "Depot")
    t.eq(screen(d), "3.geraete", d.text(v))
    t.eq(netz.node("N0001").role, "depot")
    t.eq(netz.node("N0001").label, "N0001 | DEP | B0001")
    t.eq(d.node.setup.session().wiz.config.node.label, "N0001 | DEP | B0001")
  end },
  { "Zurueck von den Geraeten zu den Gleisen: erneutes Weiter vergibt dieselbe Kennung und uebernimmt die neue Auswahl", function()
    local h, z, d, v, netz = setup()
    to_devices(h, d, v)
    d.tap(v, "act:zurueck")
    t.eq(screen(d), "3.gleise", d.text(v))
    d.tap(v, "sel:gleise_auswahl:2")                 -- Gleis 2 abwaehlen
    d.tap(v, "act:weiter")
    h.step(3); d.node.render()
    t.eq(screen(d), "3.geraete", d.text(v))
    t.eq(#netz.nodes(), 1, "keine zweite Kennung")
    t.eq(#netz.node("N0001").tracks, 1)
    local wiz = d.node.setup.session().wiz
    local count = 0
    for _ in pairs(wiz.config.tracks) do count = count + 1 end
    t.eq(count, 1)
  end },
  { "Von Hand geht der bisherige Weg weiter (Name statt Kennung aus dem Verzeichnis)", function()
    local h, z, d, v, netz = setup()
    d.tap(v, "act:start")
    d.tap(v, "sel:modus:2"); d.tap(v, "act:weiter")
    h.step(5); d.node.render()
    d.tap(v, "sel:netzwahl:1"); d.tap(v, "act:weiter")
    d.tap_row(v, "rollen", "Passagierbahnhof"); d.tap(v, "act:weiter")
    h.step(3); d.node.render()
    d.tap(v, "act:von_hand")
    t.eq(screen(d), "2.name", d.text(v))
    d.type(v, "name", "Westbahnhof"); d.tap(v, "act:weiter")
    t.eq(screen(d), "3.geraete")
    t.eq(#netz.nodes(), 0, "nichts im Verzeichnis angefordert")
  end },
  { "Nach einem Neustart beginnt die Einrichtung von vorn (kein Entwurf), die Node behaelt aber ihre Kennung im Verzeichnis", function()
    local h, z, d, v, netz = setup()
    to_devices(h, d, v)
    d.tap_row(v, "geraete", "Create_Station_1")
    t.eq(d.node.setup.session().wiz.config.node.id, "N0001")
    t.ok(not d.fs.exists("/crn_data/config.lua"), "nichts als Entwurf gespeichert")
    local saved = storelib.new(d.fs).load("/crn_data/anforderung.lua")
    t.eq(type(saved.claim), "string", "nur die Anforderungskennung dieses Computers bleibt")
    d.restart(); h.step(1)
    local v2 = d.view()
    v2.set_page("einrichtung")
    t.eq(d.node.config, nil)
    t.eq(d.node.status().text, "Einrichtung")
    to_devices(h, d, v2)
    t.eq(screen(d), "3.geraete", d.text(v2))
    t.ok(not d.has(v2, "[x] Create_Station_1"), "die Auswahl beginnt leer: " .. d.text(v2))
    t.eq(#netz.nodes(), 1, "keine zweite Kennung im Verzeichnis")
    t.eq(d.node.setup.session().wiz.config.node.id, "N0001", "dieselbe Kennung")
  end },
}
