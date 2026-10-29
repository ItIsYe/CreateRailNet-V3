--[[
Purpose: Geraeteschicht (src/dev): Erkennung, Bahnhof, Signal, Beobachter, Ausgang, Ereigniszuordnung, Bindung. Die Fake-Welt verhaelt sich wie die Messung (docs/MESSWERTE.md).
]]

local t = dofile("tests/lib/t.lua")
local create = dofile("tests/fakes/create.lua")
local detect = require("dev.detect")
local stationlib = require("dev.station")
local signallib = require("dev.signal")
local observerlib = require("dev.observer")
local outlib = require("dev.out")
local eventslib = require("dev.events")
local bind = require("dev.bind")

local SCHEDULE = {
  cyclic = true,
  entries = {
    { instruction = { id = "create:destination", data = { text = "Abstell 11" } }, conditions = { { { id = "create:delay", data = { value = 5, time_unit = 1 } } } } },
    { instruction = { id = "create:destination", data = { text = "Abstell 10" } }, conditions = { { { id = "create:delay", data = { value = 5, time_unit = 1 } } } } },
  },
}

local function world()
  local w = create.world()
  w.add_station("Create_Station_1", { station_name = "Abstell 11", known = { ["Abstell 11"] = 0, ["Abstell 10"] = 120 } })
  w.add_signal("Create_Signal_5")
  w.add_observer("Create_TrainObserver_1")
  w.add_modem("left", true)
  w.add_modem("right", false, true)
  w.add_monitor("monitor_0", 51, 19)
  return w
end

local function env(w) return { peripheral = w.peripheral, redstone = w.redstone } end

return {
  -- Erkennung ---------------------------------------------------------------------------------------------------------------
  { "Scan: Namen, Typen (auch mehrere), Arten und Methoden", function()
    local w = world()
    local scan = detect.scan(w.peripheral)
    t.eq(#scan, 6)
    local right = detect.find(scan, "right")
    t.eq(right.types[1], "modem"); t.eq(right.types[2], "peripheral_hub")
    t.eq(right.kind, "modem")
    local station = detect.find(scan, "Create_Station_1")
    t.eq(station.kind, "station")
    t.eq(station.methods.getSchedule, true)
    t.eq(detect.find(scan, "monitor_0").kind, "monitor")
    t.eq(detect.find(scan, "Create_Signal_5").kind, "signal")
    t.eq(detect.find(scan, "Create_TrainObserver_1").kind, "observer")
  end },
  { "Art ergibt sich aus jedem Typ, nicht nur aus dem ersten", function()
    local w = create.world()
    w.devices["x"] = { name = "x", types = { "peripheral_hub", "modem" }, methods = { isWireless = function() return false end }, state = {} }
    t.eq(detect.scan(w.peripheral)[1].kind, "modem")
  end },
  { "Scan liefert die Geraete nach Namen sortiert, egal in welcher Reihenfolge das Spiel sie nennt", function()
    local p = {
      getNames = function() return { "b", "c", "a" } end,
      getType = function() return "modem" end,
      getMethods = function() return {} end,
    }
    local scan = detect.scan(p)
    t.eq(scan[1].name .. scan[2].name .. scan[3].name, "abc")
  end },
  { "alle erwarteten Methoden sind in der Fake-Welt vorhanden (A01)", function()
    local w = world()
    local scan = detect.scan(w.peripheral)
    for _, kind in ipairs({ "station", "signal", "observer" }) do
      for _, d in ipairs(scan) do
        if d.kind == kind then t.eq(#detect.missing(kind, d), 0, d.name) end
      end
    end
  end },
  { "fehlende Methoden werden genannt", function()
    local w = world()
    w.devices["Create_Signal_5"].methods.setForcedRed = nil
    local d = detect.find(detect.scan(w.peripheral), "Create_Signal_5")
    local missing = detect.missing("signal", d)
    t.eq(#missing, 1); t.eq(missing[1], "setForcedRed")
    t.contains(table.concat(detect.summary(detect.scan(w.peripheral)), "\n"), "fehlt: setForcedRed")
  end },
  { "unbekannter Typ hat keine Art, Geraet ohne Typ wird uebersprungen", function()
    local w = create.world()
    w.devices["x"] = { name = "x", types = { "ding" }, methods = {}, state = {} }
    local scan = detect.scan(w.peripheral)
    t.eq(#scan, 1)
    t.eq(scan[1].kind, nil)
    local broken = { getNames = function() return { "a" } end, getType = function() return nil end, getMethods = function() return {} end }
    t.eq(#detect.scan(broken), 0)
  end },
  { "Geraet verschwindet waehrend des Scans: der Scan laeuft weiter", function()
    local w = world()
    local p = w.peripheral
    local getType = p.getType
    p.getType = function(name)
      if name == "Create_Signal_5" then error("weg") end
      return getType(name)
    end
    local scan = detect.scan(p)
    t.eq(detect.find(scan, "Create_Signal_5"), nil)
    t.ok(detect.find(scan, "Create_Station_1"))
    t.eq(#detect.scan({ getNames = function() error("kaputt") end }), 0)
  end },
  { "Unterschied zwischen zwei Scans", function()
    local w = world()
    local before = detect.scan(w.peripheral)
    w.detach("Create_Signal_5")
    w.add_signal("Create_Signal_6")
    local added, removed = detect.diff(before, detect.scan(w.peripheral))
    t.eq(added[1], "Create_Signal_6")
    t.eq(removed[1], "Create_Signal_5")
  end },
  -- Bahnhof -------------------------------------------------------------------------------------------------------------------
  { "Bahnhof ohne Zug: Zustand lesbar, keine Fehler, kein geratener Zug", function()
    local w = world()
    local s = stationlib.new(env(w), "Create_Station_1")
    local state = s.read()
    t.eq(state.available, true)
    t.eq(state.present, false)
    t.eq(state.train, nil)
    t.eq(state.has_schedule, nil)
    t.eq(#state.errors, 0, "der Fehler 'kein Zug' ist ein normaler Zustand")
    t.eq(state.enroute, false)
  end },
  { "Bahnhof mit Zug: Name und Fahrplan", function()
    local w = world()
    w.arrive("Create_Station_1", "Zug 5", SCHEDULE)
    local s = stationlib.new(env(w), "Create_Station_1")
    local state = s.read()
    t.eq(state.present, true)
    t.eq(state.train, "Zug 5")
    t.eq(state.has_schedule, true)
    t.eq(s.schedule().entries[2].instruction.data.text, "Abstell 10")
  end },
  { "Bahnhof nicht verfuegbar (Peripheral weg)", function()
    local w = world()
    local s = stationlib.new(env(w), "Create_Station_1")
    w.detach("Create_Station_1")
    local state = s.read()
    t.eq(state.available, false)
    t.eq(state.present, nil)
    t.contains(state.errors[1], "No peripheral named")
    local result, why = s.set_schedule(SCHEDULE)
    t.eq(result, nil)
    t.eq(why, "Bahnhof nicht verfuegbar")
  end },
  { "Fahrplan setzen: uebernommen, danach bereits, nie blind ein zweites Mal", function()
    local w = world()
    w.arrive("Create_Station_1", "Zug 5", { cyclic = false, entries = {} })
    local s = stationlib.new(env(w), "Create_Station_1")
    t.eq(s.set_schedule(SCHEDULE), "uebernommen")
    t.eq(w.devices["Create_Station_1"].state.sets, 1)
    t.eq(s.set_schedule(SCHEDULE), "bereits")
    t.eq(w.devices["Create_Station_1"].state.sets, 1, "bereits gleicher Fahrplan wird nicht noch einmal uebergeben")
  end },
  { "Fahrplan setzen ohne Zug", function()
    local w = world()
    local s = stationlib.new(env(w), "Create_Station_1")
    local result, why = s.set_schedule(SCHEDULE)
    t.eq(result, nil)
    t.eq(why, "kein Zug am Bahnhof")
    t.eq(w.devices["Create_Station_1"].state.sets, nil)
  end },
  { "Fahrplan setzen: Uebergabe ohne Wirkung wird am Zuruecklesen erkannt", function()
    local w = create.world()
    w.add_station("S", { ignore_set = true })
    w.arrive("S", "Z", { cyclic = false, entries = {} })
    local s = stationlib.new(env(w), "S")
    local result, why = s.set_schedule(SCHEDULE)
    t.eq(result, nil)
    t.contains(why, "weicht ab")
  end },
  { "Erreichbarkeit: zwei Rueckgaben, Fehlergrund", function()
    local w = world()
    w.arrive("Create_Station_1", "Zug 5", SCHEDULE)
    local s = stationlib.new(env(w), "Create_Station_1")
    t.eq((s.can_reach("Abstell 10")), true)
    local ok, why = s.can_reach("Gibt Es Nicht")
    t.eq(ok, false); t.eq(why, "no-target")
    t.eq((s.distance("Abstell 10")), 120)
    local d, reason = s.distance("Gibt Es Nicht")
    t.eq(d, nil); t.eq(reason, "no-target")
  end },
  { "Erreichbarkeit ohne Zug ist ein Fehler, kein 'unerreichbar'", function()
    local w = world()
    local s = stationlib.new(env(w), "Create_Station_1")
    local ok, why = s.can_reach("Abstell 10")
    t.eq(ok, nil)
    t.contains(why, "no train present")
  end },
  { "Zug umbenennen wird zurueckgelesen", function()
    local w = world()
    w.arrive("Create_Station_1", "Unnamed Train", SCHEDULE)
    local s = stationlib.new(env(w), "Create_Station_1")
    t.eq(s.rename_train("GZ-001"), true)
    t.eq(s.read().train, "GZ-001")
    t.eq(s.station_name(), "Abstell 11")
  end },
  -- Signal ---------------------------------------------------------------------------------------------------------------------
  { "Signal lesen", function()
    local w = world()
    local g = signallib.new(env(w), "Create_Signal_5")
    local state = g.read()
    t.eq(state.available, true)
    t.eq(state.state, "GREEN")
    t.eq(state.forced, false)
    t.eq(state.signal_type, "ENTRY_SIGNAL")
    t.eq(#state.blocking, 0)
  end },
  { "Zwangsrot setzen: bestaetigt nur nach dem Zuruecklesen von isForcedRed", function()
    local w = world()
    local g = signallib.new(env(w), "Create_Signal_5")
    local r = g.hold()
    t.eq(r.requested, true); t.eq(r.confirmed, true); t.eq(r.forced, true)
    t.eq(g.read().state, "RED")
    local r2 = g.release()
    t.eq(r2.confirmed, true); t.eq(r2.forced, false)
    t.eq(g.read().state, "GREEN")
  end },
  { "Zwangsrot ohne Wirkung wird nicht bestaetigt, obwohl der Aufruf klappt", function()
    local w = create.world()
    w.add_signal("S", { ignore_hold = true })
    local g = signallib.new(env(w), "S")
    local r = g.hold()
    t.eq(r.requested, true)
    t.eq(r.confirmed, false)
  end },
  { "Aufheben der Sperre macht ein belegtes Signal nicht gruen", function()
    local w = world()
    w.set_base("Create_Signal_5", "RED")        -- Zug im Abschnitt
    local g = signallib.new(env(w), "Create_Signal_5")
    g.hold()
    local r = g.release()
    t.eq(r.confirmed, true)
    t.eq(g.read().state, "RED", "nur die zusaetzliche Sperre ist weg")
    t.eq(g.read().forced, false)
  end },
  { "Signal: Fehler beim Setzen wird gemeldet", function()
    local w = world()
    w.devices["Create_Signal_5"].methods.setForcedRed = function() error("Signal gehoert zu keinem Block", 0) end
    local g = signallib.new(env(w), "Create_Signal_5")
    local r = g.hold()
    t.eq(r.confirmed, false)
    t.contains(r.error, "keinem Block")
  end },
  { "Signal nicht verfuegbar", function()
    local w = world()
    local g = signallib.new(env(w), "Create_Signal_5")
    w.detach("Create_Signal_5")
    t.eq(g.read().available, false)
    local r = g.hold()
    t.eq(r.confirmed, false)
    t.ok(r.error)
  end },
  -- Beobachter --------------------------------------------------------------------------------------------------------------------
  { "Beobachter", function()
    local w = world()
    local o = observerlib.new(env(w), "Create_TrainObserver_1")
    t.eq(o.read().passing, false)
    w.pass("Create_TrainObserver_1", "Zug 5")
    local state = o.read()
    t.eq(state.passing, true); t.eq(state.train, "Zug 5")
    w.detach("Create_TrainObserver_1")
    t.eq(o.read().available, false)
  end },
  -- Ausgang --------------------------------------------------------------------------------------------------------------------------
  { "Ausgang an einer Computerseite", function()
    local w = world()
    local o = outlib.new(env(w), { side = "back" })
    t.eq(o.get(), false)
    local r = o.set(true)
    t.eq(r.requested, true); t.eq(r.confirmed, true)
    t.eq(w.sides.back, true)
    t.eq(o.set(false).confirmed, true)
  end },
  { "Ausgang, der den Wert nicht uebernimmt, wird nicht bestaetigt", function()
    local stuck = { getOutput = function() return false end, setOutput = function() end }
    local r = outlib.new({ redstone = stuck }, { side = "back" }).set(true)
    t.eq(r.requested, true)
    t.eq(r.confirmed, false)
  end },
  { "Ausgang an einem Redstone Relay", function()
    local w = world()
    w.add_relay("redstone_relay_0")
    local o = outlib.new(env(w), { relay = "redstone_relay_0", side = "front" })
    t.eq(o.set(true).confirmed, true)
    t.eq(o.get(), true)
    t.eq(w.sides.front, false, "die Computerseite bleibt unberuehrt")
  end },
  { "Ausgang: ungueltige Seite und fehlendes Relay", function()
    local w = world()
    local r = outlib.new(env(w), { side = "oben" }).set(true)
    t.eq(r.confirmed, false)
    t.ok(r.error)
    local r2 = outlib.new(env(w), { relay = "weg", side = "front" }).set(true)
    t.eq(r2.confirmed, false)
    t.eq(outlib.new(env(w), { relay = "weg", side = "front" }).get(), nil)
  end },
  -- Ereignisse ------------------------------------------------------------------------------------------------------------------------
  { "Ereignisse werden Gleis und Art zugeordnet", function()
    local w = world()
    local now = 10
    local router = eventslib.router({
      bindings = { Create_Station_1 = { id = "gleis1.bahnhof", kind = "station" }, Create_Signal_5 = { id = "gleis1.signal", kind = "signal" }, Create_TrainObserver_1 = { id = "gleis1.melder", kind = "observer" } },
      now = function() return now end,
    })
    w.arrive("Create_Station_1", "Zug 5", SCHEDULE)
    w.pass("Create_TrainObserver_1", "Zug 5")
    w.devices["Create_Signal_5"].methods.setForcedRed(true)
    local seen = {}
    while true do
      local ev = w.pull()
      if not ev then break end
      seen[#seen + 1] = router.route(ev)
    end
    t.eq(seen[1].type, "train_imminent"); t.eq(seen[1].id, "gleis1.bahnhof"); t.eq(seen[1].train, "Zug 5"); t.eq(seen[1].t, 10)
    t.eq(seen[2].type, "train_arrival")
    t.eq(seen[3].kind, "observer")
    t.eq(seen[4].type, "train_signal_state_change"); t.eq(seen[4].state, "RED"); t.eq(seen[4].id, "gleis1.signal")
    t.eq(seen[4].source, "ereignis")
    for _, ev in ipairs(seen) do t.eq(ev.problem, nil) end
  end },
  { "unbekanntes Geraet und falsche Art werden gemeldet, andere Ereignisse ignoriert", function()
    local router = eventslib.router({ bindings = { X = { id = "a", kind = "signal" } }, now = function() return 0 end })
    local unknown = router.route({ "train_arrival", "Fremd", "Zug 9" })
    t.eq(unknown.problem, "unbekanntes Geraet")
    t.eq(unknown.id, nil)
    local wrong = router.route({ "train_arrival", "X", "Zug 9" })
    t.eq(wrong.problem, "Ereignis passt nicht zur Art des Geraets")
    t.eq(router.route({ "key", 65 }), nil)
    t.eq(router.route({ "monitor_touch", "m", 1, 1 }), nil)
  end },
  -- Bindung ------------------------------------------------------------------------------------------------------------------------------
  { "Bindung pruefen: ok, fehlt, falscher Typ, Methoden fehlen", function()
    local w = world()
    w.devices["Create_Signal_5"].methods.cycleSignalType = nil
    local config = {
      ["gleis1.bahnhof"] = { kind = "station", device = "Create_Station_1" },
      ["gleis1.signal"] = { kind = "signal", device = "Create_Signal_5" },
      ["gleis2.signal"] = { kind = "signal", device = "Create_Signal_9" },
      ["gleis3.signal"] = { kind = "signal", device = "Create_TrainObserver_1" },
    }
    local result = bind.check(config, detect.scan(w.peripheral))
    t.eq(result["gleis1.bahnhof"].status, "ok")
    t.eq(result["gleis1.signal"].status, "methoden_fehlen")
    t.eq(result["gleis1.signal"].detail, "cycleSignalType")
    t.eq(result["gleis2.signal"].status, "fehlt")
    t.eq(result["gleis3.signal"].status, "falscher_typ")
  end },
  { "nicht zugeordnete Geraete werden aufgelistet (ohne Modems und Monitore)", function()
    local w = world()
    w.add_signal("Create_Signal_6")
    local config = { ["a"] = { kind = "signal", device = "Create_Signal_5" } }
    local list = bind.unbound(config, detect.scan(w.peripheral))
    local names = {}
    for _, d in ipairs(list) do names[#names + 1] = d.name end
    t.eq(table.concat(names, ","), "Create_Signal_6,Create_Station_1,Create_TrainObserver_1")
  end },
  { "Ersatzgeraet: Rebind nur mit richtiger Art, vollstaendig, nicht doppelt", function()
    local w = world()
    w.add_signal("Create_Signal_6")
    local config = {
      a = { kind = "signal", device = "Create_Signal_5" },
      b = { kind = "signal", device = "Create_Signal_7" },
    }
    w.add_signal("Create_Signal_7")
    local scan = detect.scan(w.peripheral)
    t.eq(bind.rebind(config, "a", "Create_Signal_6", scan), true)
    t.eq(config.a.device, "Create_Signal_6")
    local ok, why = bind.rebind(config, "a", "Create_Station_1", scan)
    t.eq(ok, nil); t.contains(why, "falsche Art")
    ok, why = bind.rebind(config, "a", "Create_Signal_7", scan)
    t.eq(ok, nil); t.contains(why, "gehoert schon zu b")
    ok, why = bind.rebind(config, "a", "Create_Signal_99", scan)
    t.eq(ok, nil); t.contains(why, "nicht gefunden")
    ok, why = bind.rebind(config, "zzz", "Create_Signal_6", scan)
    t.eq(ok, nil); t.contains(why, "unbekannte Kennung")
    w.devices["Create_Signal_6"].methods.getState = nil
    ok, why = bind.rebind(config, "a", "Create_Signal_6", detect.scan(w.peripheral))
    t.eq(ok, nil)
    t.contains(why, "Methoden fehlen")
  end },
  { "Routen aus der Bindung", function()
    local routes = bind.routes({ a = { kind = "signal", device = "S1" }, b = { kind = "station", device = "B1" } })
    t.eq(routes.S1.id, "a"); t.eq(routes.S1.kind, "signal"); t.eq(routes.B1.kind, "station")
  end },
}
