--[[
Purpose: Einrichtung eines Bahnhofs ueber das Node-Verzeichnis (Konzept 6, 12.1): Kennung, Name und Label kommen aus der Leitstelle, Gleise und Geraete richtet der Assistent ein (die Strecke selbst regelt Create), Pruefungen lesen nur, Von Hand geht der bisherige Weg weiter, Neustart und Zurueck vergeben keine zweite Kennung.
]]

local t = dofile("tests/lib/t.lua")
local H = dofile("tests/lib/harness.lua")
local storelib = require("core.store")

local function setup(opts)
  opts = opts or {}
  local h = H.new()
  local z = h.add_node({ id = "hauptstelle", roles = { "zentrale" }, tracks = {} })
  local netz = z.node.roles.zentrale.netz
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
  d.tap_row(v, "rollen", role_text or "Bahnhof"); d.tap(v, "act:weiter")
  h.step(3); d.node.render()
  d.tap(v, "act:weiter")                                  -- Kennung von der Leitstelle anfordern
  h.step(3); d.node.render()
end

-- legt ein Gleis an und ordnet ihm eine Train Station zu; danach steht der Assistent wieder auf der Gleisliste
local function add_track(d, v, station_device)
  d.tap(v, "act:neues_gleis")
  d.tap_row(v, "bahnhof", station_device); d.tap(v, "act:weiter")     -- Name und Bahnhof auf einem Bildschirm
end

return {
  { "Bahnhof: Kennung und Name kommen aus dem Verzeichnis; Gleise und Geraete richtet der Assistent ein, keine Ausgangswahl; aktiv mit dem Label der Leitstelle", function()
    local h, z, d, v, netz = setup()
    to_devices(h, d, v)
    t.eq(screen(d), "3.geraete", d.text(v))
    t.eq(netz.node("N0001").role, "bahnhof")
    t.eq(netz.node("N0001").name, "Bahnhof N0001")
    d.tap_row(v, "geraete", "Create_Station_1"); d.tap_row(v, "geraete", "Create_Station_2")
    d.tap(v, "act:weiter")
    t.eq(screen(d), "4.gleise", d.text(v))
    t.contains(d.text(v), "Noch kein Gleis")
    t.ok(d.has(v, "Kopieren") and d.has(v, "Entfernen"), "die Gleise lassen sich wie bei jeder Node anlegen und aendern: " .. d.text(v))
    add_track(d, v, "Create_Station_1")
    t.eq(screen(d), "4.gleise", d.text(v), "nach dem Bahnhof geht es zurueck zur Gleisliste, kein Ausgang-Menue")
    t.ok(not d.has(v, "Welcher Ausgang"), d.text(v))
    add_track(d, v, "Create_Station_2")
    t.eq(screen(d), "4.gleise", d.text(v))
    t.contains(d.text(v), "Gleis 1"); t.contains(d.text(v), "Gleis 2")
    d.tap(v, "act:weiter")
    t.eq(screen(d), "5.test", d.text(v))
    d.tap(v, "act:alle_pruefen")
    t.ok(not d.has(v, "Ausgang: Gleis"), "keine Ausgangspruefungen ohne Ausgang: " .. d.text(v))
    d.tap(v, "act:weiter")
    t.eq(screen(d), "6.fertig", d.text(v))
    d.tap(v, "act:speichern")
    local config = d.node.config
    t.eq(config.status, "aktiv", d.text(v))
    t.eq(config.node.id, "N0001"); t.eq(config.node.label, "N0001 | BHF")
    t.eq(config.node.roles[1], "bahnhof")
    local tracks = {}
    for _, tr in pairs(config.tracks) do tracks[tr.name] = tr end
    t.eq(tracks["Gleis 1"].dir, nil, "keine Gleise aus einem Verzeichnis")
    t.ok(tracks["Gleis 1"].station, "Bahnhof zugeordnet")
    t.eq(tracks["Gleis 1"].release, nil, "kein Redstone-Ausgang: die Freigabe laeuft ueber die Station")
    t.eq(d.label, "N0001 | BHF", "Computerlabel gesetzt")
    local saved = storelib.new(d.fs).load("/crn_data/config.lua")
    t.eq(saved.status, "aktiv"); t.eq(saved.node.claimed, true)
    -- im Betrieb meldet sich die Node; das Verzeichnis fuehrt sie danach als aktiv
    h.step(30)
    t.eq(netz.node("N0001").state, "aktiv")
  end },
  { "Alle pruefen am Bahnhof: die lesenden laufen beim Oeffnen von selbst, es gibt nichts zu schalten (kein Ausgang)", function()
    local h, z, d, v, netz = setup()
    to_devices(h, d, v)
    d.tap_row(v, "geraete", "Create_Station_1"); d.tap_row(v, "geraete", "Create_Station_2")
    d.tap(v, "act:weiter")
    add_track(d, v, "Create_Station_1")
    add_track(d, v, "Create_Station_2")
    local wiz = d.node.setup.session().wiz
    d.tap(v, "act:weiter")
    t.eq(screen(d), "5.test", d.text(v))
    for _, test in ipairs(wiz.tests()) do
      t.eq(test.kind, "lesen", "ein Bahnhof braucht keine schaltende Pruefung (kein Ausgang): " .. test.title)
      t.eq(wiz.test_state(test.id, nil, test), "ok", "lesende Pruefungen sind schon gelaufen: " .. test.title)
    end
    d.tap(v, "act:alle_pruefen")
    t.eq(screen(d), "5.test", "nichts zu schalten: kein Bestaetigungsbildschirm")
    t.contains(v.hint, "0 ok, 0 Fehler", "nichts mehr offen")
    d.tap(v, "act:weiter")
    t.eq(screen(d), "6.fertig")
    d.tap(v, "act:speichern")
    t.eq(d.node.config.status, "aktiv")
  end },
  { "Es gibt nur noch die Rolle Bahnhof (Passagierbahnhof, Gueterbahnhof und Depot sind aufgegangen): ein Auswahlpunkt, Kuerzel BHF", function()
    local h, z, d, v, netz = setup()
    to_devices(h, d, v)
    t.eq(screen(d), "3.geraete", d.text(v))
    t.eq(netz.node("N0001").role, "bahnhof")
    t.eq(netz.node("N0001").label, "N0001 | BHF")
    t.eq(netz.node("N0001").name, "Bahnhof N0001")
    t.eq(d.node.setup.session().wiz.config.node.label, "N0001 | BHF")
    t.eq(d.node.setup.session().wiz.roles[1], "bahnhof")
  end },
  { "Zurueck von den Geraeten zur Kennung: erneutes Weiter vergibt dieselbe Kennung", function()
    local h, z, d, v, netz = setup()
    to_devices(h, d, v)
    d.tap(v, "act:zurueck")
    t.eq(screen(d), "2.kennung", d.text(v))
    d.tap(v, "act:weiter")
    h.step(3); d.node.render()
    t.eq(screen(d), "3.geraete", d.text(v))
    t.eq(#netz.nodes(), 1, "keine zweite Kennung")
    t.eq(netz.node("N0001").id, "N0001")
    t.eq(d.node.setup.session().wiz.config.node.id, "N0001")
  end },
  { "Von Hand geht der bisherige Weg weiter (Name statt Kennung aus dem Verzeichnis)", function()
    local h, z, d, v, netz = setup()
    d.tap(v, "act:start")
    d.tap(v, "sel:modus:2"); d.tap(v, "act:weiter")
    h.step(5); d.node.render()
    d.tap(v, "sel:netzwahl:1"); d.tap(v, "act:weiter")
    d.tap_row(v, "rollen", "Bahnhof"); d.tap(v, "act:weiter")
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
