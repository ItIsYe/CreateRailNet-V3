--[[
Purpose: Konfigurationsmodell (src/setup/model.lua) und Ablauf des Assistenten (src/setup/wizard.lua): Pruefregeln, Vorlagen, Schritte mit Begruendung, Geraete- und Gleiszuordnung, Knotenpunkt, gefuehrte Pruefungen (lesend und schaltend nur nach Bestaetigung), Speichern als Entwurf oder aktiv.
]]

local t = dofile("tests/lib/t.lua")
local cc = dofile("tests/fakes/cc.lua")
local create = dofile("tests/fakes/create.lua")
local model = require("setup.model")
local wizardlib = require("setup.wizard")
local detect = require("dev.detect")
local storelib = require("core.store")

local function world()
  local w = create.world()
  w.add_station("Create_Station_1", { known = { ["Abstell 10"] = 100 } })
  w.add_station("Create_Station_2")
  w.add_signal("Create_Signal_5")
  w.add_signal("Create_Signal_6")
  w.add_observer("Create_TrainObserver_1")
  w.add_relay("redstone_relay_0")
  w.add_modem("left", true)
  w.add_modem("right", false, true)
  return w
end

local function start(w, existing)
  local clock = { v = 0 }
  local wiz = wizardlib.new({
    scan = function() return detect.scan(w.peripheral) end,
    env = { peripheral = w.peripheral, redstone = w.redstone },
    now = function() clock.v = clock.v + 1 return clock.v end,
    existing = existing,
  })
  return wiz, clock
end

local function problem_codes(list)
  local out = {}
  for _, p in ipairs(list) do out[#out + 1] = p.code end
  return table.concat(out, ",")
end

local function has_code(list, code)
  for _, p in ipairs(list) do if p.code == code then return true end end
  return false
end

-- fertiger Passagierbahnhof mit zwei Gleisen
local function station_config(w)
  local wiz = start(w)
  wiz.set_network("Testnetz", "zentrale-1", nil)
  wiz.set_mode("join")
  wiz.set_name("Westbahnhof")
  wiz.toggle_role("passagierbahnhof")
  assert(wiz.next())
  assert(wiz.next())
  for _, name in ipairs({ "Create_Station_1", "Create_Station_2" }) do wiz.toggle_device(name) end
  local ids = {}
  for id, d in pairs(wiz.config.devices) do ids[d.device] = id end
  local g1 = wiz.add_track("Gleis 1")
  wiz.toggle_track_station(g1, ids.Create_Station_1)
  local g2 = wiz.add_track("Gleis 2")
  wiz.toggle_track_station(g2, ids.Create_Station_2)
  return wiz, ids, g1, g2
end

return {
  -- Modell ---------------------------------------------------------------------------------------------------------------------------------
  { "slug: nur Kleinbuchstaben, Ziffern und Bindestriche", function()
    t.eq(model.slug("Westbahnhof Gleis 1"), "westbahnhof-gleis-1")
    t.eq(model.slug("  --Ost!! "), "ost")
    t.eq(model.slug("???"), "node")
    t.eq(#model.slug(string.rep("a", 100)), 40)
  end },
  { "leere Konfiguration nennt die fehlenden Angaben", function()
    local c = model.new("", {}, {})
    local codes = problem_codes(model.validate(c, {}))
    for _, code in ipairs({ "rolle", "netz", "zentrale" }) do t.contains(codes, code) end
    t.ok(not has_code(model.validate(c, {}), "name"), "der Name blockiert nie")
  end },
  { "unbekannte Rolle wird gemeldet", function()
    local c = model.new("X", { "lokfuehrer" }, { name = "N", central_id = "z" })
    local list = model.validate(c, {})
    t.ok(has_code(list, "rolle"))
    local found = false
    for _, p in ipairs(list) do if p.text:find("Unbekannte Rolle lokfuehrer", 1, true) then found = true end end
    t.ok(found, "Text nennt die Rolle")
  end },
  { "dasselbe Geraet unter zwei Kennungen wird gemeldet", function()
    local w = world()
    local scan = detect.scan(w.peripheral)
    local c = model.new("X", { "passagierbahnhof" }, { name = "N", central_id = "z" })
    c.devices.a = { kind = "observer", device = "Create_TrainObserver_1" }
    c.devices.b = { kind = "observer", device = "Create_TrainObserver_1" }
    t.ok(has_code(model.validate(c, scan), "geraet_doppelt"))
  end },
  { "Leitstelle braucht keine Angabe der Leitstelle", function()
    local c = model.new("Zentrale", { "zentrale" }, { name = "Netz" })
    t.eq(#model.validate(c, {}), 0)
  end },
  { "Geraet fehlt, falsche Art, fehlende Methoden", function()
    local w = world()
    local scan = detect.scan(w.peripheral)
    local c = model.new("Bf", { "passagierbahnhof" }, { name = "N", central_id = "z" })
    c.devices.station1 = { kind = "station", device = "Create_Station_9" }
    t.ok(has_code(model.validate(c, scan), "geraet_fehlt"))
    c.devices.station1 = { kind = "station", device = "Create_TrainObserver_1" }
    t.ok(has_code(model.validate(c, scan), "geraet_art"))
    c.devices.station1 = { kind = "station", device = "Create_Station_1" }
    w.devices["Create_Station_1"].methods.getTrainName = nil
    t.ok(has_code(model.validate(c, detect.scan(w.peripheral)), "geraet_methoden"))
  end },
  { "Geraet nur einem Gleis, Gleisname eindeutig", function()
    local w = world()
    local scan = detect.scan(w.peripheral)
    local c = model.new("Bf", { "passagierbahnhof" }, { name = "N", central_id = "z" })
    local s1 = model.add_device(c, "station", "Create_Station_1")
    local g1, g2 = model.add_track(c, "Gleis 1"), model.add_track(c, "Gleis 1")
    model.assign(c, g1, "station", s1)
    model.assign(c, g2, "station", s1)
    local codes = problem_codes(model.validate(c, scan))
    t.contains(codes, "gleis_name_doppelt")
    t.contains(codes, "geraet_zwei_gleise")
  end },
  { "Bahnhofsgleis braucht einen Bahnhof, aber keinen Freigabeausgang (die Freigabe laeuft ueber die Station)", function()
    local w = world()
    local scan = detect.scan(w.peripheral)
    local c = model.new("Bf", { "passagierbahnhof" }, { name = "N", central_id = "z" })
    local g = model.add_track(c, "A")
    local codes = problem_codes(model.validate(c, scan))
    t.contains(codes, "gleis_bahnhof")
    local s = model.add_device(c, "station", "Create_Station_1")
    model.assign(c, g, "station", s)
    t.eq(#model.validate(c, scan), 0, "kein Ausgang noetig: " .. problem_codes(model.validate(c, scan)))
    local d = model.new("Depot", { "depot" }, { name = "N", central_id = "z" })
    local dg = model.add_track(d, "Abstell 1")
    local ds = model.add_device(d, "station", "Create_Station_1")
    model.assign(d, dg, "station", ds)
    t.eq(#model.validate(d, scan), 0, "Depot braucht keinen Freigabeausgang: " .. problem_codes(model.validate(d, scan)))
  end },
  { "Anmeldung braucht eine Station", function()
    local c = model.new("A", { "anmeldung" }, { name = "N", central_id = "z" })
    t.contains(problem_codes(model.validate(c, {})), "anmeldung_station")
    c.registration_station = "station1"
    t.ok(has_code(model.validate(c, {}), "anmeldung_station"), "unbekannte Station bleibt ungueltig")
    local w = world()
    c.devices.station1 = {kind="station", device="Create_Station_1"}
    t.eq(#model.validate(c, detect.scan(w.peripheral)), 0)
  end },
  { "Vorlage kopiert Struktur und Standardwerte, aber keine Geraete; Gleis bleibt offen", function()
    local c = model.new("Bf", { "passagierbahnhof" }, { name = "N", central_id = "z" })
    local g1 = model.add_track(c, "Gleis 1")
    c.tracks[g1].length = 12
    local s = model.add_device(c, "station", "Create_Station_1")
    model.assign(c, g1, "station", s)
    c.tracks[g1].status = "aktiv"
    local g2 = model.copy_track(c, g1, "Gleis 2")
    local copy = c.tracks[g2]
    t.eq(copy.length, 12)
    t.eq(copy.station, nil)
    t.eq(copy.status, "offen")
    t.eq(copy.name, "Gleis 2")
    t.eq(model.copy_track(c, "nix", "x"), nil)
  end },
  { "Geraet entfernen raeumt alle Verweise auf", function()
    local c = model.new("Bf", { "passagierbahnhof" }, { name = "N", central_id = "z" })
    local g = model.add_track(c, "G")
    local st = model.add_device(c, "station", "S")
    model.assign(c, g, "station", st)
    c.registration_station = st
    model.remove_device(c, st)
    t.eq(c.tracks[g].station, nil); t.eq(c.registration_station, nil)
  end },
  { "freie Geraete: noch keinem Gleis zugeordnet", function()
    local w = world()
    local scan = detect.scan(w.peripheral)
    local c = model.new("Bf", { "passagierbahnhof" }, { name = "N", central_id = "z" })
    local s1 = model.add_device(c, "station", "Create_Station_1")
    model.add_device(c, "station", "Create_Station_2")
    local g = model.add_track(c, "G")
    model.assign(c, g, "station", s1)
    local free = model.free_devices(c, scan, "station")
    t.eq(#free, 1); t.eq(free[1].name, "Create_Station_2")
  end },
  { "Geraet nicht doppelt eintragen", function()
    local c = model.new("N", {}, {})
    local a = model.add_device(c, "observer", "S")
    local b = model.add_device(c, "observer", "S")
    t.eq(a, b)
    t.eq(model.add_device(c, "observer", "T"), "observer2")
  end },
  -- Assistent: Schritte ----------------------------------------------------------------------------------------------------------------------
  { "Schritt 1: Netzname, beim Beitritt die Leitstelle", function()
    local wiz = start(world())
    local ok, why = wiz.next()
    t.eq(ok, false); t.contains(why, "Netzname")
    wiz.set_network("Testnetz")
    wiz.set_mode("join")
    ok, why = wiz.next()
    t.eq(ok, false); t.contains(why, "Leitstelle")
    wiz.set_network(nil, "zentrale-1")
    t.eq(wiz.next(), true)
    t.eq(wiz.step, 2)
  end },
  { "Schritt 2: Rolle, Leitstelle nur beim Erstellen eines Netzes; der Name blockiert nie (leer gilt ein Vorschlag)", function()
    local wiz = start(world())
    wiz.set_network("Testnetz")
    wiz.next()
    local ok, why = wiz.next()
    t.eq(ok, false); t.contains(why, "mindestens eine Rolle")
    t.ok(not why:find("Namen", 1, true), "kein Zwang zum Namen")
    wiz.set_name("   ")
    t.eq(wiz.name, "", "nur Leerzeichen gelten als leer")
    t.ok(wiz.config.node.name:match("%S"), "Vorschlag statt leerem Namen")
    t.eq(wiz.config.node.id, require("setup.model").slug(wiz.config.node.name))
    wiz.set_name("Hauptstelle")
    wiz.set_mode("join")
    wiz.set_network(nil, "z")
    ok, why = wiz.next()
    t.eq(ok, false); t.contains(why, "mindestens eine Rolle")
    wiz.set_mode("create")
    t.eq(#wiz.roles, 1); t.eq(wiz.roles[1], "zentrale", "'Erste Leitstelle erstellen' belegt die Rolle Leitstelle vor")
    wiz.toggle_role("zentrale")                     -- abgewaehlt: ohne die Rolle geht es nicht weiter
    wiz.toggle_role("passagierbahnhof")
    ok, why = wiz.next()
    t.eq(ok, false); t.contains(why, "erste Leitstelle braucht die Rolle Leitstelle")
    wiz.toggle_role("passagierbahnhof")
    wiz.toggle_role("zentrale")
    t.eq(wiz.next(), true)
    t.eq(wiz.config.node.id, "hauptstelle")
    t.eq(wiz.config.node.roles[1], "zentrale")
    -- beitreten als zweite Leitstelle ist nicht vorgesehen
    local wiz2 = start(world())
    wiz2.set_network("Testnetz", "zentrale-1")
    wiz2.set_mode("join")
    wiz2.next()
    wiz2.set_name("Zweite")
    wiz2.toggle_role("zentrale")
    ok, why = wiz2.next()
    t.eq(ok, false); t.contains(why, "zweite aktive Leitstelle")
  end },
  { "Rollen sind geordnet und mehrere moeglich", function()
    local wiz = start(world())
    wiz.set_network("N", "z"); wiz.set_mode("join"); wiz.next()
    wiz.set_name("Mehrfach")
    wiz.toggle_role("anmeldung")
    wiz.toggle_role("passagierbahnhof")
    t.eq(wiz.config.node.roles[1], "passagierbahnhof")
    t.eq(wiz.config.node.roles[2], "anmeldung")
    wiz.toggle_role("anmeldung")
    t.eq(#wiz.config.node.roles, 1)
  end },
  { "zurueck und vorwaerts behalten die Eingaben", function()
    local wiz = start(world())
    wiz.set_network("Testnetz")
    wiz.next()
    wiz.back()
    t.eq(wiz.step, 1)
    t.eq(wiz.network_name, "Testnetz")
    wiz.back()
    t.eq(wiz.step, 1, "vor Schritt 1 gibt es nichts")
  end },
  { "Schritt 3 liest die Geraete neu und merkt die Auswahl", function()
    local w = world()
    local wiz = start(w)
    wiz.set_network("N", "z"); wiz.set_mode("join"); wiz.next()
    wiz.set_name("Bf"); wiz.toggle_role("passagierbahnhof"); wiz.next()
    w.add_station("Create_Station_9")             -- kommt nach dem ersten Scan dazu
    wiz.next(); wiz.back()
    wiz.next()
    t.ok(detect.find(wiz.scan, "Create_Station_9"), "neuer Scan in Schritt 3")
    t.eq(wiz.toggle_device("Create_Station_9"), true)
    t.eq(wiz.device_selected("Create_Station_9"), true)
    t.eq(wiz.toggle_device("Create_Station_9"), true)
    t.eq(wiz.device_selected("Create_Station_9"), false)
    t.eq(wiz.toggle_device("Create_TrainObserver_1"), false, "Beobachter gehoeren nicht mehr zur Auswahl")
    t.eq(wiz.toggle_device("left"), false, "Modems gehoeren nicht zur Geraeteauswahl")
    t.eq(wiz.toggle_device("gibt-es-nicht"), false)
  end },
  { "Schritt 3 liest beim Betreten die Geraete neu", function()
    local w = world()
    local wiz = start(w)
    wiz.set_network("N", "z"); wiz.set_mode("join"); wiz.next()
    wiz.set_name("Bf"); wiz.toggle_role("passagierbahnhof")
    w.add_signal("Create_TrainObserver_9")        -- nach dem Start des Assistenten angeschlossen
    t.eq(detect.find(wiz.scan, "Create_TrainObserver_9"), nil)
    t.eq(wiz.next(), true)
    t.eq(wiz.step, 3)
    t.ok(detect.find(wiz.scan, "Create_TrainObserver_9"), "neuer Scan beim Betreten von Schritt 3")
  end },
  { "Gleis bearbeiten: Station nur einem Gleis, Umbenennen, Kopieren", function()
    local w = world()
    local wiz, ids, g1, g2 = station_config(w)
    local ok, why = wiz.toggle_track_station(g2, ids.Create_Station_1)
    t.eq(ok, false); t.contains(why, "gehoert schon zu Gleis 1")
    t.eq(wiz.toggle_track_station(g1, ids.Create_Station_1), true, "vom eigenen Gleis nehmen")
    t.eq(wiz.config.tracks[g1].station, nil)
    t.eq(wiz.toggle_track_station(g2, ids.Create_Station_1), true, "danach frei fuer ein anderes Gleis")
    t.eq(wiz.config.tracks[g2].station, ids.Create_Station_1)
    t.eq(wiz.rename_track(g1, "Gleis Eins"), true)
    t.eq(wiz.config.tracks[g1].name, "Gleis Eins")
    t.eq(wiz.rename_track("x", "y"), false)
    wiz.remove_track(g2)
    t.eq(#wiz.tracks(), 1)
    local g3 = wiz.copy_track(g1, "Gleis 3")
    t.eq(wiz.config.tracks[g3].station, nil)
  end },
  -- Pruefungen ---------------------------------------------------------------------------------------------------------------------------------
  { "Pruefungen werden aus der Konfiguration erzeugt: nur lesende (keine Sperre, kein Ausgang)", function()
    local w = world()
    local wiz = station_config(w)
    local ids = {}
    for _, test in ipairs(wiz.tests()) do ids[#ids + 1] = test.kind .. ":" .. test.id end
    local joined = table.concat(ids, " ")
    t.contains(joined, "lesen:lesen:station2")
    t.contains(joined, "lesen:lesen:station1")
    t.not_contains(joined, "schalten")
    t.not_contains(joined, "ausgang")
  end },
  { "lesende Pruefung laeuft ohne Bestaetigung", function()
    local w = world()
    local wiz = station_config(w)
    local ok = wiz.run_test("lesen:station1")
    t.eq(ok, true)
    t.eq(wiz.test_state("lesen:station1"), "ok")
    t.eq(wiz.run_test("unbekannt:x"), false)
    w.detach("Create_Station_2")
    local ok2, why = wiz.run_test("lesen:station2")
    t.eq(ok2, false); t.contains(why, "nicht erreichbar")
  end },
  { "Pruefergebnis gilt nur, solange das Geraet dasselbe ist", function()
    local w = world()
    local wiz, ids, g1 = station_config(w)
    wiz.run_test("lesen:station2")
    t.eq(wiz.test_state("lesen:station2"), "ok")
    -- andere Station an dieselbe Kennung: das alte Ergebnis ist ungueltig
    wiz.config.devices.station2.device = "Create_Station_6"
    t.eq(wiz.test_state("lesen:station2"), "offen")
  end },
  -- Fertig ------------------------------------------------------------------------------------------------------------------------------------
  { "Fertig: ohne Pruefungen wird nichts gespeichert (kein Entwurf); mit allen Pruefungen aktiv; Revision steigt; gespeichert und lesbar", function()
    local w = world()
    local fs = cc.fs()
    fs.makeDir("/crn_data")
    local store = storelib.new(fs)
    local wiz = station_config(w)
    local status, problems, why = wiz.finish(store, "/crn_data/config.lua")
    t.eq(status, nil)
    t.contains(why, "nicht vollstaendig")
    t.ok(not fs.exists("/crn_data/config.lua"), "kein Entwurf auf dem Computer")
    t.eq(wiz.config.revision, 1)
    t.eq(wiz.config.status, "offen")
    for _, test in ipairs(wiz.tests()) do wiz.run_test(test.id) end
    t.eq(wiz.all_tests_ok(), true)
    status, problems = wiz.finish(store, "/crn_data/config.lua")
    t.eq(status, "aktiv", problem_codes(problems))
    t.eq(wiz.config.revision, 2)
    local saved = store.load("/crn_data/config.lua")
    t.eq(saved.status, "aktiv")
    t.eq(saved.node.id, "westbahnhof")
    t.eq(saved.tracks.gleis1.status, "aktiv")
    t.ok(saved.tests["lesen:station1"].ok)
  end },
  { "Fertig: ein fehlendes Geraet verhindert das Aktivieren, es wird nichts gespeichert", function()
    local w = world()
    local fs = cc.fs()
    fs.makeDir("/crn_data")
    local wiz = station_config(w)
    for _, test in ipairs(wiz.tests()) do wiz.run_test(test.id) end
    w.detach("Create_Station_2")
    wiz.rescan()
    local status, problems = wiz.finish(storelib.new(fs), "/crn_data/config.lua")
    t.eq(status, nil)
    t.ok(has_code(problems, "geraet_fehlt"))
    t.ok(not fs.exists("/crn_data/config.lua"))
    t.eq(wiz.config.status, "offen")
  end },
  { "Fertig: Speichern scheitert -> Fehler wird gemeldet, die Einrichtung bleibt offen", function()
    local w = world()
    local wiz = station_config(w)
    for _, test in ipairs(wiz.tests()) do wiz.run_test(test.id) end
    local failing = { save = function() return nil, "Platte voll" end }
    local status, problems, err = wiz.finish(failing, "/x")
    t.eq(status, nil)
    t.eq(err, "Platte voll")
    t.eq(wiz.config.status, "offen")
  end },
  { "Leitstelle, Depot und Anmeldung durchlaufen den Assistenten bis aktiv", function()
    local w = world()
    local fs = cc.fs(); fs.makeDir("/crn_data")
    local store = storelib.new(fs)
    -- Leitstelle
    local z = start(w)
    z.set_network("Testnetz"); z.next(); z.set_name("Hauptstelle"); z.toggle_role("zentrale"); z.next(); z.next(); z.next(); z.next(); z.next()
    t.eq(z.step, 6)
    t.eq((z.finish(store, "/crn_data/z.lua")), "aktiv")
    -- Depot mit Gleis ohne Ausgang
    local d = start(w)
    d.set_network("Testnetz", "hauptstelle"); d.set_mode("join"); d.next(); d.set_name("Depot Nord"); d.toggle_role("depot"); d.next(); d.next()
    d.toggle_device("Create_Station_2")
    local id
    for k in pairs(d.config.devices) do id = k end
    local g = d.add_track("Abstell 1")
    d.toggle_track_station(g, id)
    for _, test in ipairs(d.tests()) do d.run_test(test.id) end
    t.eq((d.finish(store, "/crn_data/d.lua")), "aktiv")
    -- Anmeldung
    local a = start(w)
    a.set_network("Testnetz", "hauptstelle"); a.set_mode("join"); a.next(); a.set_name("Anmeldung Weizenhof"); a.toggle_role("anmeldung"); a.next(); a.next()
    a.toggle_device("Create_Station_1")
    for k in pairs(a.config.devices) do id = k end
    a.set_registration(id)
    for _, test in ipairs(a.tests()) do a.run_test(test.id) end
    t.eq((a.finish(store, "/crn_data/a.lua")), "aktiv")
  end },
  { "bestehende Konfiguration wird zum Bearbeiten geladen", function()
    local w = world()
    local fs = cc.fs(); fs.makeDir("/crn_data")
    local store = storelib.new(fs)
    local first = station_config(w)
    for _, test in ipairs(first.tests()) do first.run_test(test.id) end
    first.finish(store, "/crn_data/config.lua")
    local saved = store.load("/crn_data/config.lua")
    local again = start(w, saved)
    t.eq(again.network_name, "Testnetz")
    t.eq(again.name, "Westbahnhof")
    t.eq(again.roles[1], "passagierbahnhof")
    t.eq(again.mode, "join")
    t.eq(#again.tracks(), 2)
    t.eq(again.config.node.id, "westbahnhof", "die Kennung bleibt beim Umbenennen erhalten")
    again.set_name("Westbahnhof Neu")
    again.step_ok(1)
    t.eq(again.config.node.id, "westbahnhof")
  end },
  { "Einrichtung aus einer aelteren Version: Beobachter und Gleisrichtung werden beim Aendern verworfen, der Rest bleibt", function()
    local w = world()
    local fs = cc.fs(); fs.makeDir("/crn_data")
    local store = storelib.new(fs)
    local first = station_config(w)
    for _, test in ipairs(first.tests()) do first.run_test(test.id) end
    first.finish(store, "/crn_data/config.lua")
    local saved = store.load("/crn_data/config.lua")
    -- so sah eine Einrichtung frueher aus: ein Beobachter am Gleis und eine Richtung
    saved.devices.observer1 = { kind = "observer", device = "Create_TrainObserver_1" }
    saved.tracks.gleis1.observers = { "observer1" }
    saved.tracks.gleis1.direction = "hin"
    local again = start(w, saved)
    t.eq(again.config.devices.observer1, nil, "Beobachter weg")
    t.eq(again.config.tracks.gleis1.observers, nil)
    t.eq(again.config.tracks.gleis1.direction, nil)
    t.eq(#again.tracks(), 2, "die Gleise bleiben")
    t.ok(again.config.tracks.gleis1.station, "die Station des Gleises bleibt")
    t.eq(#model.validate(again.config, detect.scan(w.peripheral)), 0, "keine Meldung wegen der alten Felder")
  end },
}
