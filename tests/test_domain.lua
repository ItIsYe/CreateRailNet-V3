--[[
Purpose: Fachlogik ohne Geraete (src/domain): Fahrplaene bauen und pruefen (letzte Bedingung create:powered, keine Alternative), Zugregister (Eindeutigkeit, Standardname, Betriebsart nur am Haltepunkt), Fahrtauftraege (Lebenszyklus, doppelte Anforderung, Stornieren).
]]

local t = dofile("tests/lib/t.lua")
local cc = dofile("tests/fakes/cc.lua")
local storelib = require("core.store")
local schedule = require("domain.schedule")
local registerlib = require("domain.register")
local orderslib = require("domain.orders")

local function fresh()
  local fs = cc.fs()
  fs.makeDir("/crn_data")
  return fs, storelib.new(fs)
end

-- ein Muster, wie es ein Spieler im Zielpack erzeugen koennte (Feldnamen sind hier erfunden; der Test prueft nur das Verfahren)
local SAMPLE_COND = { id = "create:item_threshold", data = { operator = 0, threshold = "7", measure = 0, item = { id = "minecraft:wheat" } } }

return {
  -- Fahrplan -----------------------------------------------------------------------------------------------------------------------------
  { "Warteauftrag: ein Eintrag, zyklisch, Mindestaufenthalt, zuletzt create:powered", function()
    local s = schedule.waiting("Weizenhof", 5)
    t.eq(s.cyclic, true)
    t.eq(#s.entries, 1)
    local e = s.entries[1]
    t.eq(e.instruction.id, "create:destination")
    t.eq(e.instruction.data.text, "Weizenhof")
    t.eq(#e.conditions, 1, "nur eine Gruppe")
    t.eq(e.conditions[1][1].id, "create:delay")
    t.eq(e.conditions[1][1].data.value, 5)
    t.eq(e.conditions[1][1].data.time_unit, 1, "Sekunden wie gemessen")
    t.eq(e.conditions[1][#e.conditions[1]].id, "create:powered")
    t.eq(#schedule.check(s), 0)
    local no_wait = schedule.waiting("Weizenhof", 0)
    t.eq(#no_wait.entries[1].conditions[1], 1)
  end },
  { "Auftrag: jeder Aufenthalt endet mit create:powered, Reihenfolge Halt, Ladung, Freigabe", function()
    local s = schedule.order({
      { station = "Weizenhof", wait = 5, cargo = { count = 640 } },
      { station = "Zentrallager", wait = 3 },
      { station = "Weizenhof" },
    }, { item_threshold = { condition = SAMPLE_COND, path = { "data", "threshold" } } })
    t.eq(s.cyclic, false)
    t.eq(#s.entries, 3)
    local first = s.entries[1].conditions[1]
    t.eq(first[1].id, "create:delay")
    t.eq(first[2].id, "create:item_threshold")
    t.eq(first[3].id, "create:powered")
    t.eq(first[2].data.threshold, "640", "Text bleibt Text")
    t.eq(first[2].data.item.id, "minecraft:wheat", "Filter aus dem Muster")
    t.eq(SAMPLE_COND.data.threshold, "7", "das Muster bleibt unveraendert")
    t.eq(#s.entries[3].conditions[1], 1)
    t.eq(#schedule.check(s), 0)
    t.eq(table.concat(schedule.stops(s), ","), "Weizenhof,Zentrallager,Weizenhof")
  end },
  { "Mengenbedingung ohne Muster ist nicht moeglich", function()
    local s, err = schedule.order({ { station = "A", cargo = { count = 10 } } }, {})
    t.eq(s, nil)
    t.contains(err, "Musterfahrplan")
  end },
  { "Zahl bleibt Zahl, wenn das Muster eine Zahl fuehrt", function()
    local sample = { condition = { id = "x", data = { n = 5 } }, path = { "data", "n" } }
    t.eq(schedule.cargo_condition(sample, 640).data.n, 640)
  end },
  { "Feld mit der Menge im Muster finden", function()
    local cond = { id = "create:item_threshold", data = { operator = 0, threshold = "640", item = { id = "minecraft:wheat" } } }
    local path = schedule.locate(cond, 640)
    t.eq(table.concat(path, "."), "data.threshold")
    t.eq(schedule.locate(cond, "minecraft:wheat") ~= nil, true)
    t.eq(schedule.locate(cond, 12345), nil)
  end },
  { "Pruefung findet Alternative und fehlendes powered", function()
    local good = schedule.order({ { station = "A" } })
    t.eq(#schedule.check(good), 0)
    local alt = schedule.order({ { station = "A" } })
    alt.entries[1].conditions[2] = { schedule.delay(5) }
    local problems = schedule.check(alt)
    t.eq(#problems, 1)
    t.contains(problems[1], "genau eine Bedingungsgruppe")
    local no_powered = schedule.order({ { station = "A", wait = 5 } })
    table.remove(no_powered.entries[1].conditions[1])
    problems = schedule.check(no_powered)
    t.contains(problems[1], "create:powered")
    t.eq(#schedule.check({}), 1)
    t.eq(#schedule.check({ entries = {} }), 1)
    local nodest = { entries = { { instruction = { id = "create:rename", data = { text = "x" } }, conditions = { { schedule.powered() } } } } }
    t.contains(schedule.check(nodest)[1], "kein Ziel")
  end },
  { "Fahrplan-Kennung ist stabil und unterscheidet Fahrplaene", function()
    local a, b = schedule.waiting("A", 5), schedule.waiting("A", 5)
    t.eq(schedule.hash(a), schedule.hash(b))
    t.ok(schedule.hash(a) ~= schedule.hash(schedule.waiting("A", 6)))
    t.eq(#schedule.hash(a), 8)
  end },
  { "Fahrplaene vergleichen unabhaengig von der Schluesselreihenfolge", function()
    local a = schedule.waiting("A", 5)
    local b = schedule.waiting("A", 5)
    t.eq(schedule.same(a, b), true)
    b.entries[1].conditions[1][1].data.value = 6
    t.eq(schedule.same(a, b), false)
    t.eq(schedule.same(a, nil), false)
  end },
  -- Register ---------------------------------------------------------------------------------------------------------------------------
  { "Anmeldung eines Zuges mit allen Angaben, gespeichert und neu lesbar", function()
    local fs, store = fresh()
    local r = registerlib.new({ store = store, path = "/crn_data/register.lua" })
    local ok = r.register({ id = "GZ-001", create_name = "GZ-001", display_name = "Weizenpendel", usage = "fracht", mode = "bedarf", length = 4,
      evidence = { present = true, train_name = "GZ-001", where = "weizenhof.gleis1", t = 10, source = "abfrage" } })
    t.eq(ok, true)
    local train = r.get("GZ-001")
    t.eq(train.display_name, "Weizenpendel")
    t.eq(train.state, "registriert")
    t.eq(train.position.kind, "am_bahnhof")
    t.eq(train.position.where, "weizenhof.gleis1")
    local again = registerlib.new({ store = store, path = "/crn_data/register.lua" })
    t.eq(again.get("GZ-001").length, 4)
    t.eq(again.by_create_name("GZ-001").id, "GZ-001")
  end },
  { "Anmeldung wird abgewiesen: Standardname, doppelter Name, doppelte Kennung, falscher Zug, kein Zug", function()
    local fs, store = fresh()
    local r = registerlib.new({ store = store, path = "/crn_data/register.lua" })
    local function base(over)
      local req = { id = "GZ-001", create_name = "GZ-001", evidence = { present = true, train_name = "GZ-001", where = "x", t = 1 } }
      for k, v in pairs(over or {}) do req[k] = v end
      return req
    end
    local ok, why = r.register(base({ create_name = "Unnamed Train", evidence = { present = true, train_name = "Unnamed Train" } }))
    t.eq(ok, nil); t.contains(why, "Unnamed Train")
    t.eq(r.register(base()), true)
    ok, why = r.register(base({ id = "GZ-002" }))
    t.eq(ok, nil); t.contains(why, "gehoert schon zu GZ-001")
    ok, why = r.register(base({ create_name = "GZ-002" }))
    t.eq(ok, nil); t.contains(why, "Kennung GZ-001 ist schon vergeben")
    ok, why = r.register(base({ id = "GZ-003", create_name = "GZ-003", evidence = { present = true, train_name = "Anderer", where = "x" } }))
    t.eq(ok, nil); t.contains(why, "heisst Anderer")
    ok, why = r.register(base({ id = "GZ-004", create_name = "GZ-004", evidence = { present = false, train_name = "GZ-004" } }))
    t.eq(ok, nil); t.contains(why, "nicht bestaetigt")
    ok, why = r.register(base({ id = "gz", create_name = "GZ-005" }))
    t.eq(ok, nil); t.contains(why, "Grossbuchstaben")
    ok, why = r.register(base({ id = "GZ-006", create_name = "GZ-006", length = 0, evidence = { present = true, train_name = "GZ-006" } }))
    t.eq(ok, nil); t.contains(why, "Zuglaenge")
    ok, why = r.register(base({ id = "GZ-007", create_name = "GZ-007", usage = "post", evidence = { present = true, train_name = "GZ-007" } }))
    t.eq(ok, nil); t.contains(why, "Verwendung")
    ok, why = r.register(base({ id = "GZ-008", create_name = "bad\nname", evidence = { present = true, train_name = "bad\nname" } }))
    t.eq(ok, nil); t.contains(why, "Zugname")
    t.eq(#r.list(), 1, "nichts Halbes eingetragen")
  end },
  { "Anzeigename aendern laesst die technische Zuordnung unberuehrt", function()
    local fs, store = fresh()
    local r = registerlib.new({ store = store, path = "/crn_data/register.lua" })
    r.register({ id = "GZ-001", create_name = "GZ-001", evidence = { present = true, train_name = "GZ-001", where = "x" } })
    t.eq(r.rename_display("GZ-001", "Weizenpendel"), true)
    t.eq(r.get("GZ-001").create_name, "GZ-001")
    t.eq(r.by_create_name("GZ-001").display_name, "Weizenpendel")
    local ok, why = r.rename_display("GZ-001", "kaputt\n")
    t.eq(ok, nil)
  end },
  { "Betriebsart wechselt nur an einem bestaetigten Haltepunkt", function()
    local fs, store = fresh()
    local r = registerlib.new({ store = store, path = "/crn_data/register.lua" })
    r.register({ id = "GZ-001", create_name = "GZ-001", evidence = { present = true, train_name = "GZ-001", where = "x" } })
    t.eq(r.set_mode("GZ-001", "manuell"), true)
    r.set_position("GZ-001", "erwartet", "zwischen A und B", "ableitung", 5)
    local ok, why = r.set_mode("GZ-001", "linie")
    t.eq(ok, nil); t.contains(why, "bestaetigten Haltepunkt")
    t.eq(r.get("GZ-001").mode, "manuell")
    t.eq(r.set_mode("GZ-001", "quatsch"), nil)
    t.eq(r.set_mode("nix", "linie"), nil)
  end },
  { "Zustand, Aufenthalt, Abmelden", function()
    local fs, store = fresh()
    local r = registerlib.new({ store = store, path = "/crn_data/register.lua" })
    r.register({ id = "GZ-001", create_name = "GZ-001", evidence = { present = true, train_name = "GZ-001", where = "x" } })
    t.eq(r.set_state("GZ-001", "gesteuert"), true)
    t.eq(r.get("GZ-001").state, "gesteuert")
    t.eq(r.set_state("GZ-001", "kaputt"), nil)
    t.eq(r.set_position("GZ-001", "unbekannt", nil, "ableitung", 9), true)
    t.eq(r.get("GZ-001").position.kind, "unbekannt")
    t.eq(r.set_position("GZ-001", "phantasie", nil, "x", 9), nil)
    t.eq(r.unregister("GZ-001"), true)
    t.eq(r.get("GZ-001"), nil)
    t.eq(r.unregister("GZ-001"), nil)
  end },
  { "Register: Speicherfehler wird gemeldet und nichts bleibt halb eingetragen", function()
    local failing = { load = function() return nil end, save = function() return nil, "Platte voll" end }
    local r = registerlib.new({ store = failing, path = "/x" })
    local ok, why = r.register({ id = "GZ-001", create_name = "GZ-001", evidence = { present = true, train_name = "GZ-001", where = "x" } })
    t.eq(ok, nil); t.eq(why, "Platte voll")
    t.eq(r.get("GZ-001"), nil)
  end },
  -- Auftraege -----------------------------------------------------------------------------------------------------------------------------
  { "Vorlage anlegen und pruefen", function()
    local fs, store = fresh()
    local clock = { v = 0 }
    local o = orderslib.new({ store = store, path = "/crn_data/orders.lua", now = function() return clock.v end })
    t.eq(o.add_template({ id = "weizen", title = "Weizen liefern", train = "GZ-001", stops = { { station = "Weizenhof" } } }), true)
    t.eq(#o.templates(), 1)
    t.eq(o.add_template({ id = "x y", title = "t", train = "a", stops = { { station = "A" } } }), nil)
    t.eq(o.add_template({ id = "x", title = "", train = "a", stops = { { station = "A" } } }), nil)
    t.eq(o.add_template({ id = "x", title = "t", stops = { { station = "A" } } }), nil)
    t.eq(o.add_template({ id = "x", title = "t", train = "a", stops = {} }), nil)
    t.eq(o.add_template({ id = "x", title = "t", train = "a", stops = { { station = "" } } }), nil)
  end },
  { "Anforderung: eigener Auftrag, zweite Anforderung liefert denselben, gleiche Anforderungskennung ebenso", function()
    local fs, store = fresh()
    local clock = { v = 5 }
    local o = orderslib.new({ store = store, path = "/crn_data/orders.lua", now = function() return clock.v end })
    o.add_template({ id = "weizen", title = "Weizen liefern", train = "GZ-001", stops = { { station = "Weizenhof" } } })
    local first, fresh1 = o.request("weizen", "R1")
    t.eq(fresh1, true)
    t.eq(first.state, "angefordert")
    t.eq(first.id, "A-1")
    local second, fresh2 = o.request("weizen", "R2")
    t.eq(fresh2, false)
    t.eq(second.id, first.id, "nicht noch eine Fahrt")
    local third, fresh3 = o.request("weizen", "R1")
    t.eq(third.id, first.id); t.eq(fresh3, false)
    local missing, why = o.request("nix", "R9")
    t.eq(missing, nil); t.contains(why, "Unbekannte Vorlage")
    -- nach dem Abschluss ist eine neue Fahrt moeglich
    o.transition(first.id, "in_pruefung"); o.transition(first.id, "abgelehnt", "Test")
    local next_order, fresh4 = o.request("weizen", "R3")
    t.eq(fresh4, true)
    t.eq(next_order.id, "A-2")
    t.eq(o.request("weizen", "R1").id, "A-1", "alte Anforderungskennung zeigt weiter den alten Auftrag")
  end },
  { "Lebenszyklus: erlaubte Uebergaenge, Verlauf mit Zeit und Grund", function()
    local fs, store = fresh()
    local clock = { v = 0 }
    local o = orderslib.new({ store = store, path = "/crn_data/orders.lua", now = function() return clock.v end })
    o.add_template({ id = "w", title = "W", train = "GZ-001", stops = { { station = "A" } } })
    local order = o.request("w", "R")
    local path = { "in_pruefung", "vorbereitet", "fahrplan_uebergeben", "abfahrt_freigegeben", "unterwegs", "am_ziel", "abfahrt_freigegeben", "unterwegs", "am_ziel", "abgeschlossen" }
    for i, state in ipairs(path) do
      clock.v = i
      t.eq(o.transition(order.id, state, "Schritt " .. i), true, "Uebergang nach " .. state)
    end
    t.eq(order.state, "abgeschlossen")
    t.eq(order.history[#order.history].reason, "Schritt " .. #path)
    t.eq(order.history[#order.history].t, #path)
    t.eq(order.since, #path)
  end },
  { "nicht vorgesehene Uebergaenge werden abgewiesen, gleicher Zustand ist kein Fehler", function()
    local fs, store = fresh()
    local o = orderslib.new({ store = store, path = "/crn_data/orders.lua", now = function() return 0 end })
    o.add_template({ id = "w", title = "W", train = "GZ-001", stops = { { station = "A" } } })
    local order = o.request("w", "R")
    local ok, why = o.transition(order.id, "unterwegs")
    t.eq(ok, nil); t.contains(why, "nicht vorgesehen")
    t.eq(order.state, "angefordert")
    t.eq(o.transition(order.id, "angefordert"), true)
    o.transition(order.id, "abgelehnt", "x")
    ok, why = o.transition(order.id, "in_pruefung")
    t.eq(ok, nil, "beendete Auftraege bleiben beendet")
    t.eq(o.transition("A-99", "in_pruefung"), nil)
  end },
  { "Stornieren nur vor der Fahrplanuebergabe, danach Aenderungswunsch", function()
    local fs, store = fresh()
    local o = orderslib.new({ store = store, path = "/crn_data/orders.lua", now = function() return 0 end })
    o.add_template({ id = "w", title = "W", train = "GZ-001", stops = { { station = "A" } } })
    local order = o.request("w", "R1")
    local ok, text = o.cancel(order.id)
    t.eq(ok, true); t.eq(text, "storniert")
    t.eq(order.state, "storniert")
    local second = o.request("w", "R2")
    o.transition(second.id, "in_pruefung"); o.transition(second.id, "vorbereitet"); o.transition(second.id, "fahrplan_uebergeben")
    ok, text = o.cancel(second.id)
    t.eq(ok, true); t.contains(text, "Aenderungswunsch")
    t.eq(second.state, "fahrplan_uebergeben", "der Zustand aendert sich nicht")
    t.eq(second.change_request, true)
    ok, text = o.cancel(order.id)
    t.eq(ok, nil); t.contains(text, "schon beendet")
    t.eq(o.cancel("A-99"), nil)
  end },
  { "Auftraege bleiben nach einem Neustart erhalten, beendete werden begrenzt", function()
    local fs, store = fresh()
    local clock = { v = 0 }
    local function open() return orderslib.new({ store = store, path = "/crn_data/orders.lua", now = function() return clock.v end, max_finished = 3 }) end
    local o = open()
    o.add_template({ id = "w", title = "W", train = "GZ-001", stops = { { station = "A" } } })
    for i = 1, 8 do
      local order = o.request("w", "R" .. i)
      o.cancel(order.id)
    end
    local running = o.request("w", "R9")
    o.transition(running.id, "in_pruefung")
    local again = open()
    t.eq(#again.templates(), 1)
    t.eq(again.active_for("w").id, running.id)
    local finished = 0
    for _, order in ipairs(again.list()) do if order.state == "storniert" then finished = finished + 1 end end
    t.ok(finished <= 4, "beendete Auftraege sind begrenzt: " .. finished)
    t.eq(again.request("w", "R10").id, running.id)
  end },
  { "Auftraege: Speicherfehler beim Anfordern legt nichts an", function()
    local failing = { load = function() return nil end, save = function() return nil, "voll" end }
    local o = orderslib.new({ store = failing, path = "/x", now = function() return 0 end })
    o.templates()
    local ok = pcall(o.add_template, { id = "w", title = "W", train = "G", stops = { { station = "A" } } })
    local order, why = o.request("w", "R")
    t.eq(order, nil)
  end },
  { "Halte aus Text lesen: Bahnhof, Wartezeit, Menge", function()
    local orders = require("domain.orders")
    local stops = orders.parse_stops("Weizenhof:5:640; Zentrallager:3 ;Depot")
    t.eq(#stops, 3)
    t.eq(stops[1].station, "Weizenhof"); t.eq(stops[1].wait, 5); t.eq(stops[1].cargo.count, 640)
    t.eq(stops[2].wait, 3); t.eq(stops[2].cargo, nil)
    t.eq(stops[3].station, "Depot"); t.eq(stops[3].wait, nil)
    t.eq((orders.parse_stops("")), nil)
    t.eq((orders.parse_stops("A:x")), nil)
    t.eq((orders.parse_stops("A:5:0")), nil)
    t.eq((orders.parse_stops("A:5:6:7")), nil)
    t.eq((orders.parse_stops(":5")), nil)
  end },
  { "Mengenbedingung finden und Zahl eindeutig zuordnen", function()
    local cond = { id = "create:item_threshold", data = { operator = 0, threshold = "7", measure = 0, item = { id = "minecraft:wheat" } } }
    local sched = { entries = { { conditions = { { { id = "create:delay", data = { value = 5 } }, cond, { id = "create:powered", data = {} } } } } } }
    t.eq(schedule.find_cargo(sched), cond)
    t.eq(schedule.find_cargo(schedule.waiting("A", 5)), nil)
    local path = schedule.locate_unique(cond, "7")
    t.eq(table.concat(path, "."), "data.threshold")
    local p0, why = schedule.locate_unique(cond, "0")
    t.eq(p0, nil); t.contains(why, "mehrfach")
    p0, why = schedule.locate_unique(cond, "99")
    t.eq(p0, nil); t.contains(why, "nicht vor")
  end },
}
