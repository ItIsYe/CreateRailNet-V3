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
  for _, name in ipairs({ "Create_Station_1", "Create_Station_2", "Create_Signal_5", "Create_TrainObserver_1" }) do wiz.toggle_device(name) end
  local ids = {}
  for id, d in pairs(wiz.config.devices) do ids[d.device] = id end
  local g1 = wiz.add_track("Gleis 1")
  wiz.toggle_track_device(g1, "station", ids.Create_Station_1)
  wiz.toggle_track_device(g1, "signals", ids.Create_Signal_5)
  wiz.toggle_track_device(g1, "observers", ids.Create_TrainObserver_1)
  wiz.set_release(g1, { side = "back" })
  local g2 = wiz.add_track("Gleis 2")
  wiz.toggle_track_device(g2, "station", ids.Create_Station_2)
  wiz.set_release(g2, { side = "front" })
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
    for _, code in ipairs({ "name", "rolle", "netz", "zentrale" }) do t.contains(codes, code) end
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
    local c = model.new("X", { "signal" }, { name = "N", central_id = "z" })
    c.devices.a = { kind = "signal", device = "Create_Signal_5" }
    c.devices.b = { kind = "signal", device = "Create_Signal_5" }
    t.ok(has_code(model.validate(c, scan), "geraet_doppelt"))
  end },
  { "Knotenpunkt: Verbindung vom Anschluss zu sich selbst", function()
    local c = model.new("K", { "knoten" }, { name = "N", central_id = "z" })
    c.junction.connections = { West = true, Ost = true }
    c.junction.moves = { { from = "Ost", to = "Ost" } }
    local list = model.validate(c, {})
    t.eq(#list, 1)
    t.contains(list[1].text, "beginnt und endet am selben Anschluss")
  end },
  { "Leitstelle braucht keine Angabe der Leitstelle", function()
    local c = model.new("Zentrale", { "zentrale" }, { name = "Netz" })
    t.eq(#model.validate(c, {}), 0)
  end },
  { "Geraet fehlt, falsche Art, fehlende Methoden", function()
    local w = world()
    local scan = detect.scan(w.peripheral)
    local c = model.new("Bf", { "signal" }, { name = "N", central_id = "z" })
    c.devices.signal1 = { kind = "signal", device = "Create_Signal_9" }
    t.ok(has_code(model.validate(c, scan), "geraet_fehlt"))
    c.devices.signal1 = { kind = "signal", device = "Create_Station_1" }
    t.ok(has_code(model.validate(c, scan), "geraet_art"))
    c.devices.signal1 = { kind = "signal", device = "Create_Signal_5" }
    w.devices["Create_Signal_5"].methods.cycleSignalType = nil
    t.ok(has_code(model.validate(c, detect.scan(w.peripheral)), "geraet_methoden"))
  end },
  { "Geraet nur einem Gleis, Ausgang nur einem Gleis, Gleisname eindeutig", function()
    local w = world()
    local scan = detect.scan(w.peripheral)
    local c = model.new("Bf", { "passagierbahnhof" }, { name = "N", central_id = "z" })
    local s1 = model.add_device(c, "station", "Create_Station_1")
    local g1, g2 = model.add_track(c, "Gleis 1"), model.add_track(c, "Gleis 1")
    model.assign(c, g1, "station", s1)
    model.assign(c, g2, "station", s1)
    c.tracks[g1].release = { side = "back" }
    c.tracks[g2].release = { side = "back" }
    local codes = problem_codes(model.validate(c, scan))
    t.contains(codes, "gleis_name_doppelt")
    t.contains(codes, "geraet_zwei_gleise")
    t.contains(codes, "ausgang_doppelt")
  end },
  { "Relay-Ausgang und Computerseite derselben Seite sind verschiedene Ausgaenge", function()
    local w = world()
    local scan = detect.scan(w.peripheral)
    local c = model.new("Bf", { "passagierbahnhof" }, { name = "N", central_id = "z" })
    local s1, s2 = model.add_device(c, "station", "Create_Station_1"), model.add_device(c, "station", "Create_Station_2")
    local g1, g2 = model.add_track(c, "A"), model.add_track(c, "B")
    model.assign(c, g1, "station", s1); model.assign(c, g2, "station", s2)
    c.tracks[g1].release = { side = "back" }
    c.tracks[g2].release = { relay = "redstone_relay_0", side = "back" }
    t.ok(not has_code(model.validate(c, scan), "ausgang_doppelt"))
  end },
  { "Bahnhofsgleis braucht Bahnhof und Freigabeausgang, Depotgleis keinen Ausgang, Signalgleis ein Signal", function()
    local w = world()
    local scan = detect.scan(w.peripheral)
    local c = model.new("Bf", { "passagierbahnhof" }, { name = "N", central_id = "z" })
    local g = model.add_track(c, "A")
    local codes = problem_codes(model.validate(c, scan))
    t.contains(codes, "gleis_bahnhof")
    local s = model.add_device(c, "station", "Create_Station_1")
    model.assign(c, g, "station", s)
    t.contains(problem_codes(model.validate(c, scan)), "gleis_ausgang")
    local d = model.new("Depot", { "depot" }, { name = "N", central_id = "z" })
    local dg = model.add_track(d, "Abstell 1")
    local ds = model.add_device(d, "station", "Create_Station_1")
    model.assign(d, dg, "station", ds)
    t.eq(#model.validate(d, scan), 0, "Depot braucht keinen Freigabeausgang: " .. problem_codes(model.validate(d, scan)))
    local sg = model.new("Str", { "signal" }, { name = "N", central_id = "z" })
    model.add_track(sg, "Nord")
    t.contains(problem_codes(model.validate(sg, scan)), "gleis_signal")
  end },
  { "Knotenpunkt: Anschluesse, Verbindungen, Konfliktbereiche", function()
    local c = model.new("K", { "knoten" }, { name = "N", central_id = "z" })
    t.contains(problem_codes(model.validate(c, {})), "knoten_anschluesse")
    c.junction.connections = { West = true, Ost = true, Sued = true }
    t.eq(#model.validate(c, {}), 0)
    c.junction.moves = { { from = "West", to = "Nord" }, { from = "Ost", to = "Ost" } }
    t.contains(problem_codes(model.validate(c, {})), "knoten_verbindung")
    c.junction.moves = { { from = "West", to = "Ost" }, { from = "Sued", to = "Ost" } }
    c.junction.conflicts = { { moves = { 1 } } }
    t.contains(problem_codes(model.validate(c, {})), "knoten_konflikt")
    c.junction.conflicts = { { moves = { 1, 7 } } }
    t.contains(problem_codes(model.validate(c, {})), "knoten_konflikt")
    c.junction.conflicts = { { moves = { 1, 2 } } }
    t.eq(#model.validate(c, {}), 0)
  end },
  { "Anmeldung braucht eine Station", function()
    local c = model.new("A", { "anmeldung" }, { name = "N", central_id = "z" })
    t.contains(problem_codes(model.validate(c, {})), "anmeldung_station")
    c.registration_station = "station1"
    t.eq(#model.validate(c, {}), 0)
  end },
  { "Vorlage kopiert Struktur und Standardwerte, aber keine Geraete; Entwurf", function()
    local c = model.new("Bf", { "passagierbahnhof" }, { name = "N", central_id = "z" })
    local g1 = model.add_track(c, "Gleis 1")
    c.tracks[g1].direction = "hin"
    c.tracks[g1].length = 12
    local s = model.add_device(c, "station", "Create_Station_1")
    model.assign(c, g1, "station", s)
    model.assign(c, g1, "signals", model.add_device(c, "signal", "Create_Signal_5"))
    c.tracks[g1].release = { side = "back" }
    c.tracks[g1].status = "aktiv"
    local g2 = model.copy_track(c, g1, "Gleis 2")
    local copy = c.tracks[g2]
    t.eq(copy.direction, "hin"); t.eq(copy.length, 12)
    t.eq(copy.station, nil); t.eq(#copy.signals, 0); t.eq(copy.release, nil)
    t.eq(copy.status, "entwurf")
    t.eq(copy.name, "Gleis 2")
    t.eq(model.copy_track(c, "nix", "x"), nil)
  end },
  { "Geraet entfernen raeumt alle Verweise auf", function()
    local c = model.new("Bf", { "passagierbahnhof" }, { name = "N", central_id = "z" })
    local g = model.add_track(c, "G")
    local st, sg, ob = model.add_device(c, "station", "S"), model.add_device(c, "signal", "G1"), model.add_device(c, "observer", "O")
    model.assign(c, g, "station", st); model.assign(c, g, "signals", sg); model.assign(c, g, "observers", ob)
    c.registration_station = st
    model.remove_device(c, st); model.remove_device(c, sg); model.remove_device(c, ob)
    t.eq(c.tracks[g].station, nil); t.eq(#c.tracks[g].signals, 0); t.eq(#c.tracks[g].observers, 0); t.eq(c.registration_station, nil)
  end },
  { "freie Geraete: noch keinem Gleis zugeordnet; Ausgaenge: Computerseiten und Relay", function()
    local w = world()
    local scan = detect.scan(w.peripheral)
    local c = model.new("Bf", { "passagierbahnhof" }, { name = "N", central_id = "z" })
    local s1 = model.add_device(c, "station", "Create_Station_1")
    model.add_device(c, "station", "Create_Station_2")
    local g = model.add_track(c, "G")
    model.assign(c, g, "station", s1)
    local free = model.free_devices(c, scan, "station")
    t.eq(#free, 1); t.eq(free[1].name, "Create_Station_2")
    local outputs = model.outputs(scan)
    t.eq(#outputs, 12, "sechs Computerseiten und sechs Relayseiten")
    t.eq(outputs[7].relay, "redstone_relay_0")
  end },
  { "Geraet nicht doppelt eintragen", function()
    local c = model.new("N", {}, {})
    local a = model.add_device(c, "signal", "S")
    local b = model.add_device(c, "signal", "S")
    t.eq(a, b)
    t.eq(model.add_device(c, "signal", "T"), "signal2")
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
  { "Schritt 2: Name, Rolle, Leitstelle nur beim Erstellen eines Netzes", function()
    local wiz = start(world())
    wiz.set_network("Testnetz")
    wiz.next()
    local ok, why = wiz.next()
    t.eq(ok, false); t.contains(why, "Namen")
    wiz.set_name("Hauptstelle")
    wiz.set_mode("join")
    wiz.set_network(nil, "z")
    ok, why = wiz.next()
    t.eq(ok, false); t.contains(why, "mindestens eine Rolle")
    wiz.set_mode("create")
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
    wiz.toggle_role("signal")
    wiz.toggle_role("passagierbahnhof")
    t.eq(wiz.config.node.roles[1], "passagierbahnhof")
    t.eq(wiz.config.node.roles[2], "signal")
    wiz.toggle_role("signal")
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
    w.add_signal("Create_Signal_9")      -- kommt nach dem ersten Scan dazu
    wiz.next(); wiz.back()
    wiz.next()
    t.ok(detect.find(wiz.scan, "Create_Signal_9"), "neuer Scan in Schritt 3")
    t.eq(wiz.toggle_device("Create_Signal_9"), true)
    t.eq(wiz.device_selected("Create_Signal_9"), true)
    t.eq(wiz.toggle_device("Create_Signal_9"), true)
    t.eq(wiz.device_selected("Create_Signal_9"), false)
    t.eq(wiz.toggle_device("left"), false, "Modems gehoeren nicht zur Geraeteauswahl")
    t.eq(wiz.toggle_device("gibt-es-nicht"), false)
  end },
  { "Schritt 3 liest beim Betreten die Geraete neu", function()
    local w = world()
    local wiz = start(w)
    wiz.set_network("N", "z"); wiz.set_mode("join"); wiz.next()
    wiz.set_name("Bf"); wiz.toggle_role("passagierbahnhof")
    w.add_signal("Create_Signal_9")        -- nach dem Start des Assistenten angeschlossen
    t.eq(detect.find(wiz.scan, "Create_Signal_9"), nil)
    t.eq(wiz.next(), true)
    t.eq(wiz.step, 3)
    t.ok(detect.find(wiz.scan, "Create_Signal_9"), "neuer Scan beim Betreten von Schritt 3")
  end },
  { "Gleis bearbeiten: Geraet nur einem Gleis, Ausgang nur einem Gleis, Richtung, Umbenennen", function()
    local w = world()
    local wiz, ids, g1, g2 = station_config(w)
    local ok, why = wiz.toggle_track_device(g2, "station", ids.Create_Station_1)
    t.eq(ok, false); t.contains(why, "gehoert schon zu Gleis 1")
    ok, why = wiz.toggle_track_device(g2, "signals", ids.Create_Signal_5)
    t.eq(ok, false); t.contains(why, "gehoert schon zu Gleis 1")
    t.eq(wiz.toggle_track_device(g1, "signals", ids.Create_Signal_5), true, "vom eigenen Gleis nehmen")
    t.eq(wiz.toggle_track_device(g2, "signals", ids.Create_Signal_5), true, "danach frei fuer ein anderes Gleis")
    t.eq(wiz.toggle_track_device(g2, "signals", ids.Create_Signal_5), true)
    ok, why = wiz.set_release(g2, { side = "back" })
    t.eq(ok, false); t.contains(why, "gehoert schon zu Gleis 1")
    t.eq(wiz.set_release(g2, { relay = "redstone_relay_0", side = "back" }), true)
    t.eq(wiz.set_release(g2, nil), true)
    t.eq(wiz.set_direction(g1, "hin"), true)
    t.eq(wiz.config.tracks[g1].direction, "hin")
    t.eq(wiz.rename_track(g1, "Gleis Eins"), true)
    t.eq(wiz.config.tracks[g1].name, "Gleis Eins")
    t.eq(wiz.rename_track("x", "y"), false)
    wiz.remove_track(g2)
    t.eq(#wiz.tracks(), 1)
    local g3 = wiz.copy_track(g1, "Gleis 3")
    t.eq(wiz.config.tracks[g3].direction, "hin")
    t.eq(wiz.config.tracks[g3].station, nil)
  end },
  { "Knotenpunkt im Assistenten", function()
    local wiz = start(world())
    wiz.set_network("N", "z"); wiz.set_mode("join"); wiz.next()
    wiz.set_name("Abzweig"); wiz.toggle_role("knoten"); wiz.next(); wiz.next()
    t.eq(wiz.add_connection("West"), true)
    t.eq(wiz.add_connection("Ost"), true)
    t.eq(wiz.add_connection("Sued"), true)
    t.eq(wiz.add_connection(""), false)
    t.eq(wiz.add_move("West", "Ost"), true)
    t.eq(wiz.add_move("Sued", "Ost"), true)
    local ok, why = wiz.add_move("West", "Ost")
    t.eq(ok, false); t.contains(why, "gibt es schon")
    ok, why = wiz.add_move("West", "West")
    t.eq(ok, false)
    ok, why = wiz.add_move("West", "Nord")
    t.eq(ok, false); t.contains(why, "Unbekannter")
    t.eq(wiz.add_conflict(1, 2), true)
    ok, why = wiz.add_conflict(2, 1)
    t.eq(ok, false); t.contains(why, "schon eingetragen")
    ok = wiz.add_conflict(1, 1)
    t.eq(ok, false)
    t.eq(#wiz.warnings(), 0, problem_codes(wiz.warnings()))
    wiz.remove_connection("Ost")
    t.eq(#wiz.config.junction.moves, 0, "Verbindungen ueber den entfernten Anschluss fallen weg")
    t.eq(#wiz.config.junction.conflicts, 0)
  end },
  -- Pruefungen ---------------------------------------------------------------------------------------------------------------------------------
  { "Pruefungen werden aus der Konfiguration erzeugt: lesen, Sperre, Ausgang", function()
    local w = world()
    local wiz = station_config(w)
    local ids = {}
    for _, test in ipairs(wiz.tests()) do ids[#ids + 1] = test.kind .. ":" .. test.id end
    local joined = table.concat(ids, " ")
    t.contains(joined, "lesen:lesen:signal1")
    t.contains(joined, "schalten:sperre:signal1")
    t.contains(joined, "schalten:ausgang:gleis1")
    t.contains(joined, "schalten:ausgang:gleis2")
    for _, test in ipairs(wiz.tests()) do
      if test.kind == "schalten" then t.ok(#test.explain > 20, "Erklaerung fehlt bei " .. test.id) end
    end
  end },
  { "lesende Pruefung laeuft ohne Bestaetigung, schaltende nur mit", function()
    local w = world()
    local wiz = station_config(w)
    local ok = wiz.run_test("lesen:station1", false)
    t.eq(ok, true)
    t.eq(wiz.test_state("lesen:station1"), "ok")
    local ok2, why = wiz.run_test("sperre:signal1", false)
    t.eq(ok2, false); t.contains(why, "bestaetigen")
    t.eq(wiz.test_state("sperre:signal1"), "offen")
    t.eq(w.devices["Create_Signal_5"].state.forced, false)
    ok2 = wiz.run_test("sperre:signal1", true)
    t.eq(ok2, true)
    t.eq(wiz.test_state("sperre:signal1"), "ok")
    t.eq(w.devices["Create_Signal_5"].state.forced, false, "danach wieder frei")
    t.eq(wiz.run_test("unbekannt:x", true), false)
  end },
  { "Ausgangstest schaltet und stellt zurueck; schon eingeschalteter Ausgang wird nicht angefasst", function()
    local w = world()
    local wiz = station_config(w)
    t.eq(wiz.run_test("ausgang:gleis1", true), true)
    t.eq(w.sides.back, false)
    w.sides.front = true
    local ok, why = wiz.run_test("ausgang:gleis2", true)
    t.eq(ok, false); t.contains(why, "schon eingeschaltet")
    t.eq(w.sides.front, true, "unveraendert")
    t.eq(wiz.test_state("ausgang:gleis2"), "fehler")
  end },
  { "Ausgang, der nicht ausgeht, wird als ACHTUNG gemeldet", function()
    local w = world()
    local wiz = station_config(w)
    local real_set = w.redstone.setOutput
    w.redstone.setOutput = function(side, on) if on then real_set(side, on) end end   -- Ausschalten wirkt nicht
    local ok, why = wiz.run_test("ausgang:gleis1", true)
    t.eq(ok, false); t.contains(why, "ACHTUNG")
  end },
  { "Sperre: schon gesperrtes Signal, Signal ohne Wirkung, Signal verschwunden", function()
    local w = world()
    local wiz = station_config(w)
    w.devices["Create_Signal_5"].methods.setForcedRed(true)
    local ok, why = wiz.run_test("sperre:signal1", true)
    t.eq(ok, false); t.contains(why, "schon gesperrt")
    t.eq(w.devices["Create_Signal_5"].state.forced, true, "fremde Sperre bleibt")
    w.devices["Create_Signal_5"].methods.setForcedRed(false)
    w.devices["Create_Signal_5"].state.ignore_hold = true
    ok, why = wiz.run_test("sperre:signal1", true)
    t.eq(ok, false); t.contains(why, "nicht bestaetigt")
    w.detach("Create_Signal_5")
    ok, why = wiz.run_test("lesen:signal1", false)
    t.eq(ok, false); t.contains(why, "nicht erreichbar")
  end },
  { "Sperre, die sich nicht aufheben laesst, wird als ACHTUNG gemeldet", function()
    local w = world()
    local wiz = station_config(w)
    local state = w.devices["Create_Signal_5"].state
    w.devices["Create_Signal_5"].methods.setForcedRed = function(v) if v then state.forced = true end end   -- Aufheben wirkt nicht
    local ok, why = wiz.run_test("sperre:signal1", true)
    t.eq(ok, false); t.contains(why, "ACHTUNG")
    t.eq(wiz.test_state("sperre:signal1"), "fehler")
  end },
  { "Pruefergebnis gilt nur, solange das Geraet dasselbe ist", function()
    local w = world()
    local wiz, ids, g1 = station_config(w)
    wiz.run_test("lesen:signal1", false)
    t.eq(wiz.test_state("lesen:signal1"), "ok")
    -- anderes Signal an dieselbe Kennung: das alte Ergebnis ist ungueltig
    wiz.config.devices.signal1.device = "Create_Signal_6"
    t.eq(wiz.test_state("lesen:signal1"), "offen")
    wiz.set_release(g1, { side = "left" })
    wiz.config.tests["ausgang:" .. g1] = { ok = true, spec = "Computer back" }
    t.eq(wiz.test_state("ausgang:" .. g1), "offen", "anderer Ausgang")
  end },
  -- Fertig ------------------------------------------------------------------------------------------------------------------------------------
  { "Fertig: ohne Pruefungen nur Entwurf, mit allen Pruefungen aktiv; Revision steigt; gespeichert und lesbar", function()
    local w = world()
    local fs = cc.fs()
    fs.makeDir("/crn_data")
    local store = storelib.new(fs)
    local wiz = station_config(w)
    local status, problems = wiz.finish(store, "/crn_data/config.lua")
    t.eq(status, "entwurf")
    t.eq(wiz.config.revision, 2)
    local saved = store.load("/crn_data/config.lua")
    t.eq(saved.status, "entwurf")
    for _, test in ipairs(wiz.tests()) do wiz.run_test(test.id, test.kind == "schalten") end
    t.eq(wiz.all_tests_ok(), true)
    status, problems = wiz.finish(store, "/crn_data/config.lua")
    t.eq(status, "aktiv", problem_codes(problems))
    t.eq(wiz.config.revision, 3)
    saved = store.load("/crn_data/config.lua")
    t.eq(saved.status, "aktiv")
    t.eq(saved.node.id, "westbahnhof")
    t.eq(saved.tracks.gleis1.status, "aktiv")
    t.ok(saved.tests["lesen:station1"].ok)
  end },
  { "Fertig: ein fehlendes Geraet macht die Einrichtung zum Entwurf", function()
    local w = world()
    local fs = cc.fs()
    fs.makeDir("/crn_data")
    local wiz = station_config(w)
    for _, test in ipairs(wiz.tests()) do wiz.run_test(test.id, test.kind == "schalten") end
    w.detach("Create_Station_2")
    wiz.rescan()
    local status, problems = wiz.finish(storelib.new(fs), "/crn_data/config.lua")
    t.eq(status, "entwurf")
    t.ok(has_code(problems, "geraet_fehlt"))
    t.eq(wiz.config.tracks.gleis1.status, "entwurf", "betroffene Betriebsfunktion bleibt inaktiv")
  end },
  { "Fertig: Speichern scheitert -> Fehler wird gemeldet", function()
    local w = world()
    local wiz = station_config(w)
    local failing = { save = function() return nil, "Platte voll" end }
    local status, problems, err = wiz.finish(failing, "/x")
    t.eq(status, nil)
    t.eq(err, "Platte voll")
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
    d.toggle_track_device(g, "station", id)
    for _, test in ipairs(d.tests()) do d.run_test(test.id, test.kind == "schalten") end
    t.eq((d.finish(store, "/crn_data/d.lua")), "aktiv")
    -- Anmeldung
    local a = start(w)
    a.set_network("Testnetz", "hauptstelle"); a.set_mode("join"); a.next(); a.set_name("Anmeldung Weizenhof"); a.toggle_role("anmeldung"); a.next(); a.next()
    a.toggle_device("Create_Station_1")
    for k in pairs(a.config.devices) do id = k end
    a.set_registration(id)
    for _, test in ipairs(a.tests()) do a.run_test(test.id, false) end
    t.eq((a.finish(store, "/crn_data/a.lua")), "aktiv")
  end },
  { "bestehende Konfiguration wird zum Bearbeiten geladen", function()
    local w = world()
    local fs = cc.fs(); fs.makeDir("/crn_data")
    local store = storelib.new(fs)
    local first = station_config(w)
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
}
