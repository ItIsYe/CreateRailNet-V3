--[[
Purpose: Automatik im Einrichtungsassistenten (freiwillig neben der Handarbeit): "Automatisch einrichten" waehlt passende Geraete, legt Gleise an, vergibt freie Freigabeausgaenge und laesst die Pruefungen laufen; schaltende Pruefungen laufen nur, wenn der gelesene Zustand beweist, dass sie nichts treffen (kein Zug am Bahnhof, Signal gruen und frei), sonst warten sie auf die Bestaetigung. Bei Unklarem (Knotenpunkt, mehrere Bahnhoefe mit Signalen, fehlende Geraete) springt der Assistent dorthin, wo von Hand etwas noetig ist.
]]

local t = dofile("tests/lib/t.lua")
local driver = dofile("tests/lib/ui_driver.lua")
local create = dofile("tests/fakes/create.lua")
local storelib = require("core.store")

local function world(opts)
  opts = opts or {}
  local w = create.world()
  w.add_modem("left", true)
  for _, name in ipairs(opts.stations or {}) do w.add_station(name) end
  for _, name in ipairs(opts.signals or {}) do w.add_signal(name) end
  for _, name in ipairs(opts.observers or {}) do w.add_observer(name) end
  for _, name in ipairs(opts.relays or {}) do w.add_relay(name) end
  return w
end

-- bis zum Namen (Schritt 2) im Beitreten-Ablauf; row = Zeile der Rolle in der Liste (3 Gueterbahnhof, 5 Signal, 6 Knoten, 7 Anmeldung)
local function to_name(w, row, role_rows)
  local d = driver.new({ world = w })
  d.restart()
  local v = d.view()
  v.set_page("einrichtung")
  d.tap(v, "act:start")
  d.tap(v, "sel:modus:2"); d.tap(v, "act:weiter")
  d.tap(v, "sel:netzwahl:1"); d.tap(v, "act:weiter")
  d.type(v, "netz", "Testnetz"); d.tap(v, "act:weiter")
  d.type(v, "zentrale", "hauptstelle"); d.tap(v, "act:weiter")
  for _, r in ipairs(role_rows or { row }) do d.tap(v, "sel:rollen:" .. r) end
  d.tap(v, "act:weiter")
  return d, v
end

local function screen(d) return d.node.setup.session().screen end

return {
  { "ein Bahnhof mit Signal und Beobachter: alles automatisch bis zum Aktivieren, Ausgang an freier Seite", function()
    local w = world({ stations = { "Create_Station_1" }, signals = { "Create_Signal_5" }, observers = { "Create_TrainObserver_1" } })
    local d, v = to_name(w, 3)
    d.type(v, "name", "Hof")
    d.tap(v, "act:auto")
    t.eq(screen(d), "6.fertig", d.text(v))
    t.contains(v.hint, "Automatisch eingerichtet")
    local wiz = d.node.setup.session().wiz
    local ids = wiz.tracks()
    t.eq(#ids, 1)
    local track = wiz.config.tracks[ids[1]]
    t.ok(track.station); t.eq(#track.signals, 1); t.eq(#track.observers, 1)
    t.eq(track.release.side, "top", "left ist vom Modem belegt, top ist die erste freie Seite")
    t.ok(d.has(v, "Freigabe Gleis 1: Computer top"), "die Seite wird genannt, damit man danach verdrahten kann:\n" .. d.text(v))
    t.eq(w.sides.top, false, "die Pruefung hat den Ausgang wieder ausgeschaltet")
    d.tap(v, "act:speichern")
    t.eq(d.node.status().text, "Bereit")
    t.eq(storelib.new(d.fs).load("/crn_data/config.lua").status, "aktiv")
  end },
  { "zwei Bahnhoefe: zwei Gleise mit eigenen Ausgaengen, lose Signale werden genannt, nichts wird geraten", function()
    local w = world({ stations = { "Create_Station_1", "Create_Station_2" }, signals = { "Create_Signal_5" } })
    local d, v = to_name(w, 3)
    d.type(v, "name", "Hof")
    d.tap(v, "act:auto")
    t.eq(screen(d), "6.fertig", d.text(v))
    t.contains(v.hint, "gehoeren zu keinem Gleis")
    local wiz = d.node.setup.session().wiz
    t.eq(#wiz.tracks(), 2)
    local sides = {}
    for _, id in ipairs(wiz.tracks()) do
      local track = wiz.config.tracks[id]
      t.eq(#track.signals, 0, "das Signal wird keinem Gleis zugeordnet")
      sides[#sides + 1] = track.release.side
    end
    t.eq(sides[1], "top"); t.eq(sides[2], "bottom")
  end },
  { "ein Zug am Bahnhof: der Ausgangstest wartet auf die Bestaetigung, danach geht es von Hand weiter", function()
    local w = world({ stations = { "Create_Station_1" }, signals = { "Create_Signal_5" } })
    w.arrive("Create_Station_1", "Zug A")
    local d, v = to_name(w, 3)
    d.type(v, "name", "Hof")
    d.tap(v, "act:auto")
    t.eq(screen(d), "5.test", "es bleibt bei den Pruefungen")
    t.contains(v.hint, "warten auf Bestaetigung")
    t.eq(w.sides.top, false, "der Ausgang wurde nicht geschaltet")
    t.ok(d.has(v, "wartet: Zug am Bahnhof"), d.text(v))
    t.eq(d.area(v, "act:weiter").enabled, false)
    d.tap_row(v, "tests", "Ausgang: Gleis 1")
    d.tap(v, "act:ausfuehren")
    d.tap(v, "act:start_test")
    t.contains(v.hint, "ok: Ausgang geschaltet")
    d.tap(v, "act:weiter")
    t.eq(screen(d), "6.fertig")
  end },
  { "rotes oder belegtes Signal: die Sperrpruefung wartet", function()
    local w = world({ stations = { "Create_Station_1" }, signals = { "Create_Signal_5" } })
    w.set_base("Create_Signal_5", "RED")
    local d, v = to_name(w, 3)
    d.type(v, "name", "Hof")
    d.tap(v, "act:auto")
    t.eq(screen(d), "5.test")
    local wiz = d.node.setup.session().wiz
    t.eq(wiz.auto_waiting["sperre:" .. next(wiz.config.devices)] or wiz.auto_waiting[next(wiz.auto_waiting)], "Signal nicht gruen")
    d.tap_row(v, "tests", "Sperre: Create_Signal_5")
    d.node.render()
    t.contains(v.hint, "Wartet auf Bestaetigung: Signal nicht gruen")
    t.eq(w.devices["Create_Signal_5"].state.forced, false)
    -- gruen, aber ein Zug wird gemeldet
    local w2 = world({ stations = { "Create_Station_1" }, signals = { "Create_Signal_5" } })
    w2.devices["Create_Signal_5"].state.blocking = { "Zug B" }
    local d2, v2 = to_name(w2, 3)
    d2.type(v2, "name", "Hof")
    d2.tap(v2, "act:auto")
    t.eq(screen(d2), "5.test")
    local wiz2 = d2.node.setup.session().wiz
    t.eq(wiz2.auto_waiting[next(wiz2.auto_waiting)], "Zug am Signal gemeldet")
  end },
  { "Signal-Node: ein Gleis mit allen Signalen und Beobachtern, kein Ausgang", function()
    local w = world({ signals = { "Sig_A", "Sig_B" }, observers = { "Obs_A" } })
    local d, v = to_name(w, 5)
    d.type(v, "name", "Strecke Nord")
    d.tap(v, "act:auto")
    t.eq(screen(d), "6.fertig", d.text(v))
    local wiz = d.node.setup.session().wiz
    local ids = wiz.tracks()
    t.eq(#ids, 1)
    local track = wiz.config.tracks[ids[1]]
    t.eq(track.name, "Strecke Nord")
    t.eq(#track.signals, 2); t.eq(#track.observers, 1); t.eq(track.release, nil)
    d.tap(v, "act:speichern")
    t.eq(d.node.status().text, "Bereit")
  end },
  { "Knotenpunkt bleibt Handarbeit: Geraete werden gewaehlt, dann geht es zu den Anschluessen", function()
    local w = world({ signals = { "Sig_W" }, observers = { "Obs_W" } })
    local d, v = to_name(w, 6)
    d.type(v, "name", "Tee")
    d.tap(v, "act:auto")
    t.eq(screen(d), "4.knoten")
    t.contains(v.hint, "Knotenpunkt")
    local wiz = d.node.setup.session().wiz
    t.ok(wiz.device_selected("Sig_W")); t.ok(wiz.device_selected("Obs_W"))
    t.eq(#wiz.tracks(), 0, "Gleise des Knotens legt die Automatik nicht an")
  end },
  { "ohne Bahnhof: zurueck zur Geraeteauswahl mit Begruendung", function()
    local w = world({ signals = { "Create_Signal_5" } })
    local d, v = to_name(w, 3)
    d.type(v, "name", "Hof")
    d.tap(v, "act:auto")
    t.eq(screen(d), "3.geraete")
    t.contains(v.hint, "Train Station")
  end },
  { "ohne Namen oder Rolle startet die Automatik nicht", function()
    local w = world({ stations = { "Create_Station_1" } })
    local d, v = to_name(w, 3)
    d.tap(v, "act:auto")
    t.eq(screen(d), "2.name")
    t.contains(v.hint, "Namen")
  end },
  { "Seiten mit Modem sind fuer Ausgaenge belegt", function()
    local w = world({ stations = { "Create_Station_1" } })
    w.add_modem("top", false, true)                       -- ein Kabelmodem oben
    local d, v = to_name(w, 3)
    d.type(v, "name", "Hof")
    d.tap(v, "act:auto")
    local wiz = d.node.setup.session().wiz
    t.eq(wiz.config.tracks[wiz.tracks()[1]].release.side, "bottom", "top und left sind belegt: bottom ist die erste freie Seite")
  end },
  { "Aktivieren laesst offene Pruefungen vorher selbst laufen", function()
    local w = world({ stations = { "Create_Station_1" }, signals = { "Create_Signal_5" } })
    local d, v = to_name(w, 3)
    d.type(v, "name", "Hof")
    d.tap(v, "act:auto")
    t.eq(screen(d), "6.fertig")
    local wiz = d.node.setup.session().wiz
    wiz.config.tests = {}                                  -- Nachweise sind veraltet (zum Beispiel nach einer Aenderung)
    t.eq(wiz.all_tests_ok(), false)
    t.ok(d.node.setup.on_action(v, "act:speichern"))
    t.eq(storelib.new(d.fs).load("/crn_data/config.lua").status, "aktiv")
  end },
  { "Einzelhilfen: Alle passenden (ohne Relais) und Automatisch bei den Gleisen", function()
    local w = world({ stations = { "Create_Station_1" }, signals = { "Create_Signal_5" }, observers = { "Create_TrainObserver_1" }, relays = { "redstone_relay_0" } })
    local d, v = to_name(w, 3)
    d.type(v, "name", "Hof")
    d.tap(v, "act:weiter")
    t.eq(screen(d), "3.geraete")
    d.tap(v, "act:alle_passenden")
    local wiz = d.node.setup.session().wiz
    t.ok(wiz.device_selected("Create_Station_1")); t.ok(wiz.device_selected("Create_Signal_5")); t.ok(wiz.device_selected("Create_TrainObserver_1"))
    t.ok(not wiz.device_selected("redstone_relay_0"), "Relais werden nie von selbst gewaehlt")
    d.tap(v, "act:weiter")
    t.eq(screen(d), "4.gleise")
    d.tap(v, "act:auto_gleise")
    t.eq(#wiz.tracks(), 1)
    t.contains(v.hint, "1 Gleis(e) angelegt")
    t.eq(d.area(v, "act:auto_gleise").enabled, false, "mit vorhandenen Gleisen ist die Automatik gesperrt")
    local ok, why = wiz.auto_tracks()
    t.eq(ok, false); t.contains(why, "schon Gleise")
  end },
  { "Anmeldung: genau ein Bahnhof wird zur Anmeldestation, bei mehreren entscheidet der Mensch", function()
    local w = world({ stations = { "Create_Station_1" } })
    local d, v = to_name(w, 7)
    d.type(v, "name", "Anmeldung Hof")
    d.tap(v, "act:auto")
    local wiz = d.node.setup.session().wiz
    t.ok(wiz.config.registration_station, "Anmeldestation gesetzt")
    local w2 = world({ stations = { "Create_Station_1", "Create_Station_2" } })
    local d2, v2 = to_name(w2, 7)
    d2.type(v2, "name", "Anmeldung Hof")
    d2.tap(v2, "act:auto")
    local wiz2 = d2.node.setup.session().wiz
    t.eq(wiz2.config.registration_station, nil, "bei zwei Bahnhoefen wird nichts geraten")
  end },
  { "Pruefungen laufen beim Betreten von Schritt 5 von selbst; Neu pruefen wiederholt auch Fehlgeschlagenes", function()
    local w = world({ stations = { "Create_Station_1" }, signals = { "Create_Signal_5" } })
    local d, v = to_name(w, 3)
    d.type(v, "name", "Hof")
    d.tap(v, "act:weiter")
    d.tap(v, "act:alle_passenden"); d.tap(v, "act:weiter")
    d.tap(v, "act:auto_gleise")
    d.tap(v, "sel:gleise:1"); d.tap(v, "act:weiter")     -- Gleis bearbeiten ist nicht noetig: Weiter geht zu Schritt 5
    t.eq(screen(d), "5.test", d.text(v))
    t.contains(v.hint, "Pruefung(en) automatisch")
    local wiz = d.node.setup.session().wiz
    t.ok(wiz.all_tests_ok())
    w.detach("Create_Signal_5")
    local ran, passed = wiz.auto_tests(false)
    t.ok(ran > 0)
    t.eq(wiz.all_tests_ok(), false, "ausgefallenes Signal: Pruefung schlaegt fehl")
    w.add_signal("Create_Signal_5")
    d.tap(v, "act:alle_pruefen")
    t.ok(wiz.all_tests_ok(), "nach Wiederanschluss besteht Neu pruefen")
  end },
}
