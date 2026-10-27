--[[
Purpose: Stufe 8: Zurueckhalten neuer Abfahrten (Wartung), Stoerungsuebersicht, Abstimmung nach dem Start, bestaetigte Ereignismeldungen, Schnittstellenpruefung nach Modpack-Update, Datenformat und Rueckkehr.
]]

local t = dofile("tests/lib/t.lua")
local H = dofile("tests/lib/harness.lua")
local cc = dofile("tests/fakes/cc.lua")
local storelib = require("core.store")
local envcheck = require("core.envcheck")
local dataformat = require("core.dataformat")
local detect = require("dev.detect")

local function build(opts)
  local h = H.new(opts)
  local z = h.add_node({ id = "hauptstelle", roles = { "zentrale" }, tracks = {} })
  local w = h.add_node({
    id = "weizenhof", roles = { "gueterbahnhof", "anmeldung" }, central = "hauptstelle", registration = "Gleis 1",
    tracks = { { name = "Gleis 1", station_name = "Weizenhof", release_side = "back", known = { Zentrallager = 100, Weizenhof = 0 } } },
  })
  local l = h.add_node({
    id = "lager", roles = { "gueterbahnhof" }, central = "hauptstelle",
    tracks = { { name = "Gleis 1", station_name = "Zentrallager", release_side = "back", known = { Weizenhof = 100, Zentrallager = 0 } } },
  })
  local sim = h.sim({ { node = "weizenhof", name = "Weizenhof" }, { node = "lager", name = "Zentrallager" } }, 12)
  return h, z, w, l, sim
end

local function ready(h, z, w, sim)
  sim.add_train("Unnamed Train", "Weizenhof", nil, 0)
  h.step(20)
  w.node.roles.anmeldung.submit_registration({ id = "GZ-001", create_name = "GZ-001", display_name = "W", usage = "fracht", mode = "bedarf", length = 4 })
  t.ok(h.until_true(function() local tr = z.node.roles.zentrale.register.get("GZ-001") return tr and tr.state == "gesteuert" end, 60))
  h.step(8)
  local zentrale = z.node.roles.zentrale
  zentrale.orders.add_template({ id = "fahrt", title = "Fahrt", train = "GZ-001", return_to_start = true, stops = { { station = "Weizenhof", wait = 0 }, { station = "Zentrallager", wait = 2 } } })
  return zentrale
end

return {
  { "Zurueckhalten: keine neuen Abfahrten, Fahrten unterwegs laufen weiter, Fortsetzen gibt frei", function()
    local h, z, w, l, sim = build()
    local zentrale = ready(h, z, w, sim)
    local order = zentrale.demand("fahrt", nil)
    t.ok(h.until_true(function() return order.state == "unterwegs" end, 120), order.state)
    t.eq(zentrale.set_hold(true, "Wartung"), true)
    local o, why = zentrale.demand("fahrt", nil)
    t.eq(o, nil); t.contains(why, "zurueckgehalten")
    -- die laufende Fahrt kommt am Ziel an, bekommt dort aber keine neue Freigabe
    t.ok(h.until_true(function() return order.state == "am_ziel" end, 120), order.state)
    h.step(30)
    t.eq(order.state, "am_ziel", "Freigabe zur Rueckfahrt bleibt aus")
    t.eq(l.world.sides.back, false)
    local drain = zentrale.drain_state()
    t.eq(drain.active, 1); t.eq(drain.committed, 0)
    zentrale.set_hold(false)
    t.ok(h.until_true(function() return order.state == "abgeschlossen" end, 200), order.state .. " " .. tostring(order.reason))
  end },
  { "Zurueckhalten haelt Linien an und bleibt nach einem Neustart bestehen", function()
    local h, z, w, l, sim = build()
    local zentrale = ready(h, z, w, sim)
    zentrale.lines.set({ id = "pendel", title = "P", template = "fahrt", trains = { "GZ-001" }, interval = 60, offset = 5 })
    zentrale.set_hold(true, "Wartung")
    h.step(130)
    t.eq(#zentrale.orders.list(), 0)
    t.ok(zentrale.lines.get("pendel").missed >= 2)
    h.restart("hauptstelle")
    local again = z.node.roles.zentrale
    t.eq((again.hold_state()), true)
    again.set_hold(false)
    t.eq((again.hold_state()), false)
  end },
  { "Seite Stoerungen: Ursachen werden gezeigt, Halten und Fortsetzen brauchen Bestaetigung", function()
    local h, z, w, l, sim = build()
    local zentrale = ready(h, z, w, sim)
    local v = H.open_page(z, "stoerungen")
    t.ok(z.has(v, "Keine Stoerung"), z.text(v))
    z.tap(v, "act:halten")
    t.eq((zentrale.hold_state()), true)
    z.node.render()
    t.ok(z.has(v, "zurueckgehalten"), z.text(v))
    z.tap(v, "act:halten")
    t.eq((zentrale.hold_state()), true, "erster Druck setzt nicht fort")
    z.tap(v, "act:halten")
    t.eq((zentrale.hold_state()), false)
    -- ein Node verstummt
    h.step(1)
    l.world.devices["Create_Station_1"].state.train = nil
    h.nodes.lager.node.shutdown()
    h.order[3].node.handle = function() end        -- Computer ausgefallen
    h.step(70)
    local found = false
    for _, f in ipairs(zentrale.faults()) do if f.who == "lager" and f.text:find("meldet sich nicht", 1, true) then found = true end end
    t.ok(found)
    z.tap(v, "act:pruefen")
  end },
  { "Geraet am Bahnhof verschwunden: Gleis ungeklaert, Auftrag zur Klaerung, keine Zuweisung als Ziel", function()
    local h, z, w, l, sim = build()
    local zentrale = ready(h, z, w, sim)
    zentrale.orders.add_template({ id = "lang", title = "Lang", train = "GZ-001", return_to_start = true, stops = { { station = "Weizenhof", wait = 400 }, { station = "Zentrallager", wait = 2 } } })
    local order = zentrale.demand("lang", nil)
    t.ok(h.until_true(function() return order.state == "fahrplan_uebergeben" end, 60), order.state)
    w.world.devices["Create_Station_1"].methods.isTrainPresent = function() error("Peripheral missing", 0) end
    w.world.devices["Create_Station_1"].methods.getStationName = function() error("Peripheral missing", 0) end
    t.ok(h.until_true(function() return order.state == "klaerung" end, 20), order.state)
    t.contains(order.reason, "nicht verfuegbar")
    local seen = false
    for _, f in ipairs(zentrale.faults()) do if f.text:find("nicht verfuegbar", 1, true) then seen = true end end
    t.ok(seen)
  end },
  { "nach dem Start nimmt der Bahnhof erst nach Abstimmung mit der Leitstelle Aufgaben an", function()
    local h, z, w, l, sim = build()
    local zentrale = ready(h, z, w, sim)
    h.restart("weizenhof")
    local st = w.world.devices["Create_Station_1"].state
    local sets_before = st.sets or 0
    local m = z.node.send_to("weizenhof", "auftrag", { kind = "warteauftrag", track = "gleis1", train = "GZ-001", wait = 0, handover = true })
    local answer
    table.insert(z.node.hooks.on_message, 1, function(r) if r.correlationId == m.messageId then answer = r.payload end end)
    h.step(1)
    t.ok(answer, "Antwort")
    t.eq(answer.status, "zurueckgestellt"); t.contains(answer.grund, "gleicht sich")
    t.eq(st.sets or 0, sets_before)
    h.step(15)
    local m2 = z.node.send_to("weizenhof", "auftrag", { kind = "warteauftrag", track = "gleis1", train = "GZ-001", wait = 0, handover = true })
    answer = nil
    table.insert(z.node.hooks.on_message, 1, function(r) if r.correlationId == m2.messageId then answer = r.payload end end)
    h.step(2)
    t.eq(answer.status, "uebergeben")
  end },
  { "Ereignismeldungen werden bestaetigt und bei Verlust wiederholt: die Fahrt schliesst auch bei hohem Verlust ab", function()
    local opts = { seed = 11, drop = 0.3, dup = 0.1, reorder = true }
    local h, z, w, l, sim = build({ bus = opts })
    sim.add_train("Unnamed Train", "Weizenhof", nil, 0)
    h.step(40)
    w.node.roles.anmeldung.submit_registration({ id = "GZ-001", create_name = "GZ-001", display_name = "W", usage = "fracht", mode = "bedarf", length = 4 })
    t.ok(h.until_true(function() local tr = z.node.roles.zentrale.register.get("GZ-001") return tr and tr.state == "gesteuert" end, 400))
    local zentrale = z.node.roles.zentrale
    zentrale.orders.add_template({ id = "fahrt", title = "Fahrt", train = "GZ-001", return_to_start = true, stops = { { station = "Weizenhof", wait = 0 }, { station = "Zentrallager", wait = 2 } } })
    local order
    t.ok(h.until_true(function()
      order = zentrale.orders.list()[1]
      if not order then zentrale.demand("fahrt", nil) end
      return order and order.state == "abgeschlossen"
    end, 1500), tostring(order and order.state) .. " " .. tostring(order and order.reason))
  end },
  { "Schnittstellenabdruck: gleich, geaendert (Methode fehlt oder neuer Host), erst nach Pruefung wieder gueltig", function()
    local fs = cc.fs()
    fs.makeDir("/crn_data")
    local store = storelib.new(fs)
    local scan = { { name = "a", kind = "station", methods = { getStationName = true, setSchedule = true } }, { name = "m", kind = "modem", methods = { open = true } } }
    t.eq((envcheck.check(store, "/crn_data/u.lua", scan, "CC 1")), "erstmals")
    t.eq((envcheck.check(store, "/crn_data/u.lua", scan, "CC 1")), "gleich")
    scan[2].name = "anderes"
    t.eq((envcheck.check(store, "/crn_data/u.lua", scan, "CC 1")), "gleich", "Namen und fremde Geraete zaehlen nicht")
    t.eq((envcheck.check(store, "/crn_data/u.lua", scan, "CC 2")), "geaendert", "anderer Host")
    t.eq((envcheck.check(store, "/crn_data/u.lua", scan, "CC 2")), "geaendert", "bleibt geaendert bis zur Pruefung")
    envcheck.accept(store, "/crn_data/u.lua", scan, "CC 2")
    t.eq((envcheck.check(store, "/crn_data/u.lua", scan, "CC 2")), "gleich")
    scan[1].methods.setSchedule = nil
    t.eq((envcheck.check(store, "/crn_data/u.lua", scan, "CC 2")), "geaendert", "Methode fehlt")
  end },
  { "Modpack-Update: Node haelt die Automatik an, bis die Pruefung bestanden ist", function()
    local h, z, w, l, sim = build()
    local zentrale = ready(h, z, w, sim)
    -- ein Update veraendert den Host-Text; der Node startet neu
    w.env_host = "CC 99"
    h.restart("weizenhof")
    t.eq(w.node.env_hold, true)
    h.step(15)
    local order, why = nil, nil
    local st = w.world.devices["Create_Station_1"].state
    local sets = st.sets or 0
    local m = z.node.send_to("weizenhof", "auftrag", { kind = "warteauftrag", track = "gleis1", train = "GZ-001", wait = 0, handover = true })
    local answer
    table.insert(z.node.hooks.on_message, 1, function(r) if r.correlationId == m.messageId then answer = r.payload end end)
    h.step(2)
    t.eq(answer.status, "zurueckgestellt"); t.contains(answer.grund, "Umgebung geaendert")
    t.eq(st.sets or 0, sets)
    local v = H.open_page(w, "uebersicht")
    t.ok(w.has(v, "Pruefung"), w.text(v))
    w.tap(v, "act:umgebung")
    t.eq(w.node.env_hold, false)
    local after = z.node.send_to("weizenhof", "auftrag", { kind = "warteauftrag", track = "gleis1", train = "GZ-001", wait = 0, handover = true })
    answer = nil
    table.insert(z.node.hooks.on_message, 1, function(r) if r.correlationId == after.messageId then answer = r.payload end end)
    h.step(2)
    t.eq(answer.status, "uebergeben")
  end },
  { "Datenformat: Sicherung vor dem Migrieren, Rueckkehr mit neuerem Format startet nicht, Sicherung kann zurueckgespielt werden", function()
    local fs = cc.fs()
    fs.makeDir("/crn_data")
    local store = storelib.new(fs)
    t.eq((dataformat.check(fs, store, { format = 1, program = "0.1" })), "neu")
    store.save("/crn_data/register.lua", { trains = { a = 1 } })
    t.eq((dataformat.check(fs, store, { format = 1, program = "0.2" })), "gleich")
    local migrated = false
    local status, old, dir = dataformat.check(fs, store, { format = 2, program = "0.3", migrations = { [1] = function(s) migrated = true s.save("/crn_data/register.lua", { trains = { a = 2 } }) end } })
    t.eq(status, "migriert"); t.eq(old, 1); t.ok(migrated)
    t.ok(fs.exists(dir .. "/register.lua"), "Sicherung angelegt")
    t.eq(store.load("/crn_data/register.lua").trains.a, 2)
    -- Rueckkehr zu Programm mit Format 1
    status, old = dataformat.check(fs, store, { format = 1, program = "0.2" })
    t.eq(status, "zu_neu"); t.eq(old, 2)
    t.eq(store.load("/crn_data/register.lua").trains.a, 2, "nichts veraendert")
    t.eq(#dataformat.backups(fs), 1)
    t.eq(dataformat.restore(fs, store, 1), true)
    t.eq(store.load("/crn_data/register.lua").trains.a, 1)
    t.eq((dataformat.check(fs, store, { format = 1, program = "0.2" })), "gleich")
    local ok, err = dataformat.restore(fs, store, 7)
    t.eq(ok, nil); t.contains(err, "Keine Sicherung")
  end },
  { "Ersatzcomputer: Konfiguration wird gesichert, erst nach Stilllegen oder Ausfall herausgegeben, dann uebernommen", function()
    local h, z, w, l, sim = build()
    local zentrale = ready(h, z, w, sim)
    h.step(40)
    t.ok(zentrale.backup_of("weizenhof"), "Sicherung angekommen")
    t.eq(zentrale.backup_of("weizenhof").revision, w.node.config.revision)
    local fresh = h.add_blank({ id = "neu", stations = { "Weizenhof" } })
    local v = H.open_page(fresh, "einrichtung")
    fresh.tap(v, "act:ersatz")
    fresh.type(v, "r_central", "hauptstelle")
    fresh.type(v, "r_node", "weizenhof")
    -- der alte Computer laeuft noch: abgelehnt
    fresh.tap(v, "act:r_holen")
    h.step(4)
    fresh.node.render()
    t.ok(fresh.has(v, "noch aktiv"), fresh.text(v))
    -- Stilllegen in der Leitstelle (Bestaetigung noetig)
    local nv = H.open_page(z, "netz")
    z.tap(nv, "sel:netz:2")
    z.tap(nv, "act:stilllegen")
    t.eq(zentrale.info().nodes.weizenhof.retired, nil, "erster Druck legt nichts still")
    z.tap(nv, "act:stilllegen")
    t.eq(zentrale.info().nodes.weizenhof.retired, true)
    -- der stillgelegte Node wird ignoriert
    h.step(70)
    local ghost = false
    for _, f in ipairs(zentrale.faults()) do if f.who == "weizenhof" and f.text == "stillgelegt" then ghost = true end end
    t.ok(ghost)
    fresh.tap(v, "act:r_holen")
    h.step(4)
    fresh.node.render()
    t.ok(fresh.has(v, "empfangen"), fresh.text(v))
    fresh.tap(v, "act:r_uebernehmen")
    t.ok(fresh.has(v, "Schritt 6 von 6"), fresh.text(v))
    t.eq(fresh.node.setup.session().wiz.config.node.id, "weizenhof", "Kennung bleibt erhalten")
    local wiz = fresh.node.setup.session().wiz
    for _, test in ipairs(wiz.tests()) do wiz.run_test(test.id, true) end        -- Schritt 5: die Pruefungen am neuen Computer
    fresh.node.render()
    fresh.tap(v, "act:speichern")
    t.eq(fresh.node.config.status, "aktiv")
    t.eq(fresh.node.config.node.id, "weizenhof")
    h.step(15)
    t.eq(zentrale.info().nodes.weizenhof.retired, nil, "nach der Uebergabe gilt der Ersatz")
    t.ok(zentrale.info().track_state["weizenhof:gleis1"], "Ersatz meldet sich")
  end },
  { "Ersatz: unbekannte Node und fehlende Sicherung werden abgelehnt; ausgefallene Node darf ersetzt werden", function()
    local h, z, w, l, sim = build()
    local zentrale = ready(h, z, w, sim)
    h.step(40)
    local fresh = h.add_blank({ id = "neu", stations = {} })
    local v = H.open_page(fresh, "einrichtung")
    fresh.tap(v, "act:ersatz")
    fresh.type(v, "r_central", "hauptstelle")
    fresh.type(v, "r_node", "gibtsnicht")
    fresh.tap(v, "act:r_holen")
    h.step(4)
    fresh.node.render()
    t.ok(fresh.has(v, "keine Sicherung"), fresh.text(v))
    -- Lager faellt aus (Computer aus): nach der Stille darf er ersetzt werden
    local old = h.nodes.lager
    old.node.handle = function() end
    h.step(75)
    fresh.type(v, "r_node", "lager")
    fresh.tap(v, "act:r_holen")
    h.step(4)
    fresh.node.render()
    t.ok(fresh.has(v, "empfangen"), fresh.text(v))
  end },
}
