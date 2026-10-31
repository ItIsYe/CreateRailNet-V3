--[[
Purpose: Knotenlaufzeit und Einrichtung ueber die Oberflaeche (src/app/node.lua, src/setup/page.lua): ein frischer Computer wird nur ueber Beruehrung und Tastatur eingerichtet, danach laeuft er als Node weiter; Monitor als zweite Ansicht, Neustart, Geraeteaenderung, Meldungen, Rollenanschluesse.
]]

local t = dofile("tests/lib/t.lua")
local drv = dofile("tests/lib/ui_driver.lua")
local create = dofile("tests/fakes/create.lua")
local screenlib = dofile("tests/fakes/screen.lua")
local storelib = require("core.store")
local detect = require("dev.detect")

local function detect_has(scan, name) return detect.find(scan, name) ~= nil end

local function world()
  local w = create.world()
  w.add_station("Create_Station_1", { known = { ["Abstell 10"] = 100 } })
  w.add_station("Create_Station_2")
  w.add_signal("Create_Signal_5")
  w.add_observer("Create_TrainObserver_1")
  w.add_modem("left", true)
  w.add_modem("right", false, true)
  w.add_monitor("monitor_0", 100, 40)
  return w
end

local function new_driver(opts)
  opts = opts or {}
  local w = opts.world or world()
  local monitors = { monitor_0 = screenlib.new(100, 40) }
  local d = drv.new({ world = w, monitors = monitors, width = opts.width, height = opts.height })
  d.restart()
  return d, w
end

-- Einrichtung eines Passagierbahnhofs mit einem Gleis ueber die Oberflaeche, bis zum letzten Schritt (ohne Speichern)
local function setup_station(d, v)
  d.tap(v, "nav:einrichtung")
  d.tap(v, "act:start")
  d.tap(v, "sel:modus:2")
  d.tap(v, "act:weiter")
  d.type(v, "netz", "Testnetz")
  d.tap(v, "act:weiter")
  d.type(v, "zentrale", "hauptstelle")
  d.tap(v, "act:weiter")
  d.tap_row(v, "rollen", "Passagierbahnhof")
  d.tap(v, "act:weiter")
  d.type(v, "name", "Westbahnhof")
  d.tap(v, "act:weiter")
  d.tap_row(v, "geraete", "Create_Station_1")
  d.tap_row(v, "geraete", "Create_Signal_5")
  d.tap_row(v, "geraete", "Create_TrainObserver_1")
  d.tap(v, "act:weiter")
  -- Gleisliste
  d.tap(v, "act:neues_gleis")
  d.type(v, "gleisname", "Gleis 1")
  d.tap(v, "act:weiter")                    -- Richtung
  d.tap(v, "act:weiter")                    -- Bahnhof
  return d
end

return {
  { "frischer Computer: Status Einrichtung, Seite Einrichtung, noch kein Funk, kein Absturz", function()
    local d = new_driver()
    local v = d.view()
    t.eq(d.node.status().text, "Einrichtung")
    t.eq(v.current_page().id, "einrichtung")
    t.ok(d.has(v, "Einrichtung starten"))
    t.eq(d.node.net, nil)
    t.eq(d.view("monitor_0"), nil, "Monitor ohne Konfiguration noch nicht als Ansicht")
  end },
  { "Assistent fuer einen Passagierbahnhof, nur ueber Beruehrung und Tastatur, bis zum aktiven Node", function()
    local d, w = new_driver()
    local v = d.view()
    d.tap(v, "nav:einrichtung")
    d.tap(v, "act:start")
    t.ok(d.has(v, "Schritt 1 von 6: Anlage"))
    -- Schritt 1: Netz beitreten
    d.tap(v, "sel:modus:2")
    d.tap(v, "act:weiter")
    d.tap(v, "act:weiter")
    t.ok(d.has(v, "Der Netzname fehlt") or d.has(v, "Netzname"), "ohne Netzname geht es nicht weiter:\n" .. d.text(v))
    d.type(v, "netz", "Testnetz")
    d.tap(v, "act:weiter")
    d.type(v, "zentrale", "hauptstelle")
    d.tap(v, "act:weiter")
    -- Schritt 2
    t.ok(d.has(v, "Schritt 2 von 6: Rolle"))
    d.tap(v, "act:weiter")
    t.ok(d.has(v, "mindestens eine Rolle"), "Hinweis ohne Rolle")
    d.tap_row(v, "rollen", "Passagierbahnhof")
    d.tap(v, "act:weiter")
    d.type(v, "name", "Westbahnhof")
    t.ok(d.has(v, "Kennung im Netz: westbahnhof"))
    d.tap(v, "act:weiter")
    -- Schritt 3: Geraete
    t.ok(d.has(v, "Schritt 3 von 6: Geraete"))
    t.ok(d.has(v, "Funk: left"), "Funkmodem wird gezeigt")
    d.tap_row(v, "geraete", "Create_Station_1")
    t.ok(d.has(v, "[x] Create_Station_1"))
    d.tap_row(v, "geraete", "Create_Signal_5")
    d.tap_row(v, "geraete", "Create_TrainObserver_1")
    d.tap(v, "act:weiter")
    -- Schritt 4: ein Gleis
    t.ok(d.has(v, "Schritt 4 von 6: Gleise"))
    d.tap(v, "act:neues_gleis")
    d.type(v, "gleisname", "Gleis 1")
    d.tap(v, "act:weiter")
    d.tap_row(v, "richtung", "hin")
    d.tap(v, "act:weiter")
    d.tap_row(v, "bahnhof", "Create_Station_1")
    d.tap(v, "act:weiter")
    d.tap_row(v, "signale", "Create_Signal_5")
    d.tap(v, "act:weiter")
    d.tap_row(v, "beobachter", "Create_TrainObserver_1")
    d.tap(v, "act:weiter")
    d.tap_row(v, "ausgang", "Computer back")
    d.tap(v, "act:weiter")
    t.ok(d.has(v, "Gleis 1"), "zurueck in der Gleisliste")
    t.ok(d.has(v, "> Gleis 1"))
    t.ok(d.has(v, "Bahnhof, 1 Signal"), "Zusammenfassung des Gleises in der Liste: " .. d.text(v))
    d.tap(v, "act:weiter")
    -- Schritt 5: Pruefungen
    t.ok(d.has(v, "Schritt 5 von 6: Test"))
    d.tap(v, "act:alle_lesen")
    t.ok(d.has(v, "3 lesende Pruefungen ausgefuehrt"))
    d.tap_row(v, "tests", "Sperre: Create_Signal_5")
    d.tap(v, "act:ausfuehren")
    t.ok(d.has(v, "Schaltende Pruefung bestaetigen"))
    t.ok(d.has(v, "Das Signal Create_Signal_5 wird kurz"), "Erklaerung der Wirkung:\n" .. d.text(v))
    t.eq(w.devices["Create_Signal_5"].state.forced, false, "noch nichts geschaltet")
    d.tap(v, "act:start_test")
    t.ok(d.has(v, "ok: Sperre gesetzt und aufgehoben"), d.text(v))
    d.tap_row(v, "tests", "Ausgang: Gleis 1")
    d.tap(v, "act:ausfuehren")
    d.tap(v, "act:start_test")
    t.ok(d.has(v, "ok: Ausgang geschaltet"))
    t.eq(w.sides.back, false)
    d.tap(v, "act:weiter")
    -- Schritt 6
    t.ok(d.has(v, "Schritt 6 von 6: Fertig"))
    t.ok(d.has(v, "Bereit zum Aktivieren."))
    t.ok(d.has(v, "Aktivieren"))
    d.tap(v, "act:speichern")
    t.eq(d.node.status().text, "Bereit")
    t.eq(d.node.config.status, "aktiv")
    t.eq(d.node.config.node.id, "westbahnhof")
    t.ok(d.node.net, "Funk startet gleich nach der Aktivierung")
    -- gespeichert und lesbar
    local saved = storelib.new(d.fs).load("/crn_data/config.lua")
    t.eq(saved.status, "aktiv")
    t.eq(saved.tracks.gleis1.release.side, "back")
  end },
  { "nach dem Speichern: Monitor aus der Konfiguration wird zweite Ansicht, Beruehrung dort wirkt nur dort", function()
    local d = new_driver()
    local v = d.view()
    -- Konfiguration mit Monitor direkt speichern
    local cfg = require("setup.model").new("Westbahnhof", { "passagierbahnhof" }, { name = "Testnetz", central_id = "hauptstelle" })
    require("setup.model").add_device(cfg, "monitor", "monitor_0")
    cfg.status = "aktiv"
    storelib.new(d.fs).save("/crn_data/config.lua", cfg)
    d.restart()
    local term_view, monitor_view = d.view(), d.view("monitor_0")
    t.ok(monitor_view, "Monitor-Ansicht vorhanden")
    t.eq(monitor_view.layout.mode, "gross")
    t.eq(term_view.layout.mode, "kompakt")
    t.ok(d.has(monitor_view, "Westbahnhof - passagierbahnhof"))
    -- auf dem Monitor eine andere Seite waehlen
    d.node.render()
    local a = d.area(monitor_view, "nav:geraete")
    d.node.handle({ "monitor_touch", "monitor_0", a.x, a.y })
    d.node.render()
    t.eq(monitor_view.current_page().id, "geraete")
    t.eq(term_view.current_page().id, "uebersicht")
    -- Beruehrung eines anderen Monitors wird ignoriert
    d.node.handle({ "monitor_touch", "monitor_9", a.x, a.y })
    t.eq(term_view.current_page().id, "uebersicht")
  end },
  { "Neustart: Konfiguration, Uhr und Journal werden fortgesetzt", function()
    local d = new_driver()
    local cfg = require("setup.model").new("Depot Nord", { "depot" }, { name = "Testnetz", central_id = "hauptstelle" })
    cfg.status = "aktiv"
    storelib.new(d.fs).save("/crn_data/config.lua", cfg)
    d.restart()
    d.raw.v = 125
    d.node.journal.begin("test.vorgang", { zug = "GZ-001" })      -- kein Vorgang, den eine Rolle beim Start abgleicht
    d.node.shutdown()
    d.restart()
    t.eq(d.node.config.node.name, "Depot Nord")
    t.eq(d.node.status().text, "Bereit")
    t.ok(d.node.clock.resumed())
    t.ok(d.node.clock.now() >= 125)
    t.eq(#d.node.journal.pending(), 1, "offener Vorgang bleibt sichtbar")
    t.ok(d.has(d.view(), "offene Vorgaenge im Journal") or d.has(d.view(), "1 offene Vorgaenge"))
    t.ok(d.has(d.view(), "(fortgesetzt)"))
  end },
  { "beschaedigte Konfiguration: aus der Vorversion geheilt, Node startet", function()
    local d = new_driver()
    local store = storelib.new(d.fs)
    local cfg = require("setup.model").new("Depot Nord", { "depot" }, { name = "Testnetz", central_id = "h" })
    cfg.status = "aktiv"
    store.save("/crn_data/config.lua", cfg)
    cfg.revision = 2
    store.save("/crn_data/config.lua", cfg)
    local fh = d.fs.open("/crn_data/config.lua", "w"); fh.write("muell"); fh.close()
    d.restart()
    t.ok(d.node.config, "Konfiguration aus .prev")
    t.eq(d.node.config.node.name, "Depot Nord")
  end },
  { "Entwurf: Zustand 'Entwurf' und Hinweis, kein Funk", function()
    local d = new_driver()
    local cfg = require("setup.model").new("Depot Nord", { "depot" }, { name = "Testnetz", central_id = "h" })
    storelib.new(d.fs).save("/crn_data/config.lua", cfg)
    d.restart()
    t.eq(d.node.status().text, "Entwurf")
    t.eq(d.node.net, nil)
    local text = ""
    for _, m in ipairs(d.node.messages) do text = text .. m.text end
    t.contains(text, "nur ein Entwurf")
  end },
  { "Geraeteaenderung zur Laufzeit erzeugt Meldungen", function()
    local d, w = new_driver()
    w.add_signal("Create_Signal_9")
    d.node.handle({ "peripheral", "Create_Signal_9" })
    w.detach("Create_TrainObserver_1")
    d.node.handle({ "peripheral_detach", "Create_TrainObserver_1" })
    local texts = {}
    for _, m in ipairs(d.node.messages) do texts[#texts + 1] = m.text end
    local all = table.concat(texts, "|")
    t.contains(all, "Geraet angeschlossen: Create_Signal_9")
    t.contains(all, "Geraet entfernt: Create_TrainObserver_1")
    t.ok(not detect_has(d.node.scan, "Create_TrainObserver_1"))
  end },
  { "Meldungen: Liste, Quittieren aendert nur die Meldung", function()
    local d, w = new_driver()
    local v = d.view()
    d.node.notify("warnung", "Signal Nord gestoert")
    d.tap(v, "nav:meldungen")
    t.ok(d.has(v, "Signal Nord gestoert"))
    d.tap(v, "act:quittieren")
    t.ok(d.has(v, "(quittiert)"))
    t.ok(d.has(v, "Quittiert; Belegung und Signale bleiben."))
  end },
  { "Create-Ereignisse und Funknachrichten gehen an die Rollenanschluesse, Fehler dort stoppen nichts", function()
    local d, w = new_driver()
    local cfg = require("setup.model").new("Westbahnhof", { "passagierbahnhof" }, { name = "Testnetz", central_id = "hauptstelle" })
    require("setup.model").add_device(cfg, "station", "Create_Station_1")
    cfg.status = "aktiv"
    storelib.new(d.fs).save("/crn_data/config.lua", cfg)
    d.restart()
    local seen, messages = {}, {}
    table.insert(d.node.hooks.on_event, function(ev) seen[#seen + 1] = ev.type .. ":" .. tostring(ev.id) end)
    table.insert(d.node.hooks.on_event, function() error("Rolle kaputt") end)
    table.insert(d.node.hooks.on_message, function(m, status) messages[#messages + 1] = m.messageType .. ":" .. status end)
    w.arrive("Create_Station_1", "Zug 5", { cyclic = false, entries = {} })
    while true do
      local ev = w.pull()
      if not ev then break end
      d.node.handle(ev)
    end
    t.eq(seen[1], "train_imminent:station1")
    t.eq(seen[2], "train_arrival:station1")
    local all = {}
    for _, m in ipairs(d.node.messages) do all[#all + 1] = m.text end
    t.contains(table.concat(all, "|"), "Rolle kaputt")
    -- unbekanntes Geraet
    d.node.handle({ "train_arrival", "Create_Station_77", "Zug 1" })
    t.contains(table.concat((function() local x = {} for _, m in ipairs(d.node.messages) do x[#x + 1] = m.text end return x end)(), "|"), "unbekanntes Geraet: Create_Station_77")
    -- Funknachricht
    local other = require("core.msg").new({ node_id = "hauptstelle", boot_id = 1, epoch = 1 })
    local msg = other.make("auftrag", "westbahnhof", { kind = "x" })
    d.node.handle({ "rednet_message", 9, require("core.ser").encode(msg), "crn1" })
    t.eq(messages[1], "auftrag:ok")
  end },
  { "Rollenseiten aus hooks erscheinen in der Navigation", function()
    local d = new_driver()
    local page = { id = "gleisbild", title = "Gleisbild", render = function(v, rect) require("ui.widgets").label(v, rect.x + 1, rect.y, "Gleisbild folgt") end }
    table.insert(d.node.hooks.pages, page)
    d.node.rebuild_views()
    d.node.render()
    local v = d.view()
    t.ok(not d.has(v, "Gleisbild"), "im kompakten Layout zunaechst hinter dem Blaetterpfeil")
    t.ok(d.area(v, "navscroll:next"), "Pfeil zum Blaettern vorhanden")
    d.tap(v, "navscroll:next")
    t.ok(d.has(v, "Gleisbild"))
    d.tap(v, "nav:gleisbild")
    t.ok(d.has(v, "Gleisbild folgt"))
  end },
  { "run(): Schleife verarbeitet Ereignisse, speichert die Uhr beim Beenden", function()
    local d = new_driver()
    d.raw.v = 40
    table.insert(d.queue, { "mouse_click", 1, 3, 2 })
    table.insert(d.queue, { "timer", 1 })
    d.node.run()    -- danach wirft pull_event "Terminated"
    local saved = storelib.new(d.fs).load("/crn_data/clock.lua")
    t.ok(saved.t >= 40, "Uhr gespeichert")
  end },
  { "run(): ein Fehler in einem Ereignis beendet die Schleife nicht, wird einmal gemeldet, spaetere Ereignisse laufen weiter", function()
    local d = new_driver()
    local v = d.view()
    local calls = 0
    local real = v.handle
    v.handle = function(ev)
      calls = calls + 1
      if ev[1] == "mouse_click" then error("kaputter Touch") end
      return real(ev)
    end
    table.insert(d.queue, { "mouse_click", 1, 3, 2 })
    table.insert(d.queue, { "mouse_click", 1, 3, 2 })    -- derselbe Fehler gleich nochmal: keine zweite Meldung
    table.insert(d.queue, { "key", 65 })                 -- laeuft danach noch durch
    d.node.run()
    t.eq(calls, 3, "alle drei Ereignisse wurden verarbeitet")
    local found = 0
    for _, m in ipairs(d.node.messages) do if m.level == "fehler" and m.text:find("kaputter Touch", 1, true) then found = found + 1 end end
    t.eq(found, 1, "der gleiche Fehler wird nur einmal gemeldet")
  end },
  { "Wizard: Abbrechen braucht zwei Beruehrungen und laesst die Einrichtung unveraendert", function()
    local d = new_driver()
    local v = d.view()
    d.tap(v, "nav:einrichtung")
    d.tap(v, "act:start")
    d.tap(v, "act:abbrechen")
    t.ok(d.has(v, "Nochmal druecken verwirft die Eingaben."))
    t.ok(d.has(v, "Schritt 1 von 6"))
    d.tap(v, "act:abbrechen")
    t.ok(d.has(v, "Einrichtung starten"))
    t.eq(d.node.config, nil)
  end },
  { "Wizard: nur eine Ansicht bearbeitet, die andere zeigt den Hinweis", function()
    local d = new_driver()
    local cfg = require("setup.model").new("Westbahnhof", { "passagierbahnhof" }, { name = "N", central_id = "h" })
    require("setup.model").add_device(cfg, "monitor", "monitor_0")
    storelib.new(d.fs).save("/crn_data/config.lua", cfg)
    d.restart()
    local tv, mv = d.view(), d.view("monitor_0")
    d.tap(tv, "nav:einrichtung")
    d.tap(tv, "act:start")
    mv.set_page("einrichtung")
    d.node.render()
    t.ok(d.has(mv, "Einrichtung wird bearbeitet."))
    t.ok(d.has(tv, "Schritt 1 von 6"))
    mv.dispatch("act:weiter")
    mv.dispatch("sel:modus:2")
    d.node.render()
    t.ok(d.has(tv, "Schritt 1 von 6"), "die zweite Ansicht kann den Assistenten nicht weiterschalten")
    t.eq(d.node.setup.session().screen, "1.modus")
  end },
  { "Wizard: ohne Pruefungen nur als Entwurf speichern", function()
    local d, w = new_driver()
    local v = d.view()
    setup_station(d, v)
    d.tap_row(v, "bahnhof", "Create_Station_1")
    d.tap(v, "act:weiter"); d.tap(v, "act:weiter"); d.tap(v, "act:weiter")
    d.tap_row(v, "ausgang", "Computer back")
    d.tap(v, "act:weiter")
    d.tap(v, "act:weiter")              -- Pruefungen
    d.tap(v, "act:weiter")              -- Fertig
    t.eq(d.node.setup.session().screen, "5.test", "offene Tests blockieren Weiter")
    t.eq(d.area(v, "act:weiter").enabled, false)
    d.tap(v, "act:entwurf")
    t.eq(d.node.config.status, "entwurf")
    t.eq(d.node.status().text, "Entwurf")
    t.eq(d.node.net, nil, "kein Funk fuer einen Entwurf")
  end },
  { "Wizard: Vorlage kopieren verlangt neue Zuordnung", function()
    local d, w = new_driver()
    local v = d.view()
    setup_station(d, v)
    d.tap_row(v, "bahnhof", "Create_Station_1")
    d.tap(v, "act:weiter")                   -- Signale
    d.tap(v, "act:weiter")                   -- Beobachter
    d.tap(v, "act:weiter")                   -- Ausgang
    d.tap_row(v, "ausgang", "Computer back")
    d.tap(v, "act:weiter")                   -- zurueck zur Liste
    d.tap(v, "act:kopieren")
    t.ok(d.has(v, "Gleis bearbeiten: Gleis 1 Kopie"))
    t.ok(d.has(v, "Kopie: Geraete und Ausgang neu zuordnen."))
  end },
  { "Wizard: Knotenpunkt ueber die Oberflaeche", function()
    local d, w = new_driver()
    local v = d.view()
    d.tap(v, "nav:einrichtung"); d.tap(v, "act:start")
    d.tap(v, "sel:modus:2"); d.tap(v, "act:weiter")
    d.type(v, "netz", "Testnetz"); d.tap(v, "act:weiter")
    d.type(v, "zentrale", "hauptstelle"); d.tap(v, "act:weiter")
    d.tap_row(v, "rollen", "Knotenpunkt"); d.tap(v, "act:weiter")
    d.type(v, "name", "Abzweig Sued"); d.tap(v, "act:weiter")
    d.tap_row(v, "geraete", "Create_Signal_5")
    d.tap_row(v, "geraete", "Create_TrainObserver_1")
    d.tap(v, "act:weiter")                    -- Pflichtgeraete zugeordnet
    t.ok(d.has(v, "Anschluesse und Verbindungen des Knotenpunkts"))
    for _, name in ipairs({ "West", "Ost", "Sued" }) do
      d.type(v, "anschluss", name)
    end
    t.ok(d.has(v, "Sued"))
    d.tap(v, "act:verbindung")
    d.tap_row(v, "von", "West")
    d.tap_row(v, "nach", "Ost")
    d.tap(v, "act:verbindung")
    d.tap_row(v, "von", "Sued")
    d.tap_row(v, "nach", "Ost")
    t.ok(d.has(v, "1: West->Ost"))
    t.ok(d.has(v, "2: Sued->Ost"))
    d.tap(v, "act:konflikt")
    d.tap_row(v, "konflikt", "1: West")
    d.tap_row(v, "konflikt", "2: Sued")
    t.ok(d.has(v, "Konflikt eingetragen.") or d.has(v, "Anschluesse und Verbindungen"))
    d.tap(v, "act:weiter")                    -- Gleise
    d.tap(v, "act:weiter")                    -- Test
    d.tap(v, "act:weiter")
    t.eq(d.node.setup.session().screen, "4.gleise", "Ein Knoten ohne Gleise darf nicht zum Test")
    t.eq(d.area(v,"act:weiter").enabled,false)
    d.tap(v, "act:entwurf")
    t.eq(d.node.config.status, "entwurf", "nicht vollstaendig: nur als Entwurf gespeichert")
    t.eq(#d.node.config.junction.conflicts, 1)
  end },
  { "main startet die Laufzeit und beendet sich sauber, wenn das Programm abgebrochen wird", function()
    local main = dofile("src/app/main.lua")
    local d = new_driver()
    local ok, err = pcall(main.run, d.env, {})
    t.eq(ok, true, tostring(err))
    t.ok(d.has(d.view(), "Einrichtung"))
  end },
  { "Wizard auf dem grossen Monitor", function()
    local d = new_driver()
    local cfg = require("setup.model").new("Westbahnhof", { "passagierbahnhof" }, { name = "N", central_id = "h" })
    require("setup.model").add_device(cfg, "monitor", "monitor_0")
    storelib.new(d.fs).save("/crn_data/config.lua", cfg)
    d.restart()
    local mv = d.view("monitor_0")
    mv.set_page("einrichtung")
    d.tap(mv, "act:start")
    d.tap(mv, "sel:modus:1")
    d.tap(mv, "act:weiter")
    d.type(mv, "netz", "Gross")
    t.ok(d.has(mv, "Gross"))
    d.tap(mv, "act:weiter")
    t.ok(d.has(mv, "Schritt 2 von 6"))
  end },
}

