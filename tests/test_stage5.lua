--[[
Purpose: Stufe 5 im Testnetz: Bahnhof mit mehreren Gleisen (Gleiswahl nach Rangfolge, Belegung, Zuweisung, Sperre, Zuglaenge), gemeinsames Zielgleis zweier Zuege, Prioritaet mit Aufholen, Linien im Takt (Termine, ausgelassene Termine, keine Nachholwelle), Tafel mit Plan und Ist.
]]

local t = dofile("tests/lib/t.lua")
local H = dofile("tests/lib/harness.lua")
local orderslib = require("domain.orders")
local lineslib = require("domain.lines")
local stationslib = require("domain.stations")
local ser = require("core.ser")

local function build(opts)
  opts = opts or {}
  local h = H.new(opts)
  local z = h.add_node({ id = "hauptstelle", roles = { "zentrale" }, tracks = {} })
  local known = { ["Hbf Gleis 1"] = 10, ["Hbf Gleis 2"] = 10, ["Hbf Gleis 3"] = 10, Zentrallager = 100 }
  local hbf = h.add_node({
    id = "hbf", roles = { "passagierbahnhof" }, central = "hauptstelle",
    tracks = {
      { name = "Gleis 1", station_name = "Hbf Gleis 1", release_side = "back", length = opts.lengths and opts.lengths[1] or 8, known = known },
      { name = "Gleis 2", station_name = "Hbf Gleis 2", release_side = "front", length = opts.lengths and opts.lengths[2] or 8, known = known },
      { name = "Gleis 3", station_name = "Hbf Gleis 3", release_side = "top", length = opts.lengths and opts.lengths[3] or 8, known = known },
    },
  })
  local lager = h.add_node({
    id = "lager", roles = { "gueterbahnhof" }, central = "hauptstelle",
    tracks = { { name = "Gleis 1", station_name = "Zentrallager", release_side = "back", known = { ["Hbf Gleis 1"] = 100, ["Hbf Gleis 2"] = 100, ["Hbf Gleis 3"] = 100, Zentrallager = 0 } } },
  })
  local sim = h.sim({
    { node = "hbf", name = "Hbf Gleis 1", device = "Create_Station_1", side = "back" },
    { node = "hbf", name = "Hbf Gleis 2", device = "Create_Station_2", side = "front" },
    { node = "hbf", name = "Hbf Gleis 3", device = "Create_Station_3", side = "top" },
    { node = "lager", name = "Zentrallager" },
  }, 12)
  local zentrale = z.node.roles.zentrale
  zentrale.stations.set("Hauptbahnhof", { "Hbf Gleis 1", "Hbf Gleis 2", "Hbf Gleis 3" })
  return h, z, hbf, lager, sim, zentrale
end

-- Zug ohne Anmeldestelle direkt ins Register und in den Warteauftrag bringen (die Anmeldung selbst testet test_e2e_station)
local function put_train(h, z, hbf, sim, id, station, track_id, length)
  sim.add_train(id, station, nil, 0)
  h.step(8)
  local zentrale = z.node.roles.zentrale
  local ok, err = zentrale.register.register({
    id = id, create_name = id, display_name = id, usage = "fracht", mode = "bedarf", length = length or 4,
    evidence = { present = true, train_name = id, where = "hbf:" .. track_id, source = "abfrage", t = 0 },
  })
  t.ok(ok, err)
  local m = z.node.send_to("hbf", "auftrag", { kind = "warteauftrag", track = track_id, train = id, wait = 0, handover = true })
  h.step(4)
  zentrale.register.set_state(id, "gesteuert")
end

local function template(zentrale, id, train, stops, priority)
  local ok, err = zentrale.orders.add_template({ id = id, title = id, train = train, return_to_start = true, priority = priority, stops = stops })
  t.ok(ok, err)
end

local function wait_state(h, order, state, max)
  return h.until_true(function() return order.state == state end, max or 120)
end

return {
  { "Bahnhof mit drei Gleisen: Zug steht auf Gleis 2, Rueckkehr auf das bevorzugte freie Gleis 1", function()
    local h, z, hbf, lager, sim, zentrale = build()
    put_train(h, z, hbf, sim, "GZ-1", "Hbf Gleis 2", "gleis2")
    template(zentrale, "fahrt", "GZ-1", { { station = "Hauptbahnhof", wait = 0 }, { station = "Zentrallager", wait = 3 } })
    local order = zentrale.orders.request("fahrt", nil)
    t.ok(wait_state(h, order, "abgeschlossen", 250), order.state .. " " .. tostring(order.reason))
    t.eq(order.plan[1].station, "Hbf Gleis 2", "Start ist das Gleis, auf dem der Zug nachweislich stand")
    t.eq(order.plan[3].station, "Hbf Gleis 1", "Rueckfahrt zum bevorzugten Gleis")
    local st = hbf.world.devices["Create_Station_1"].state
    t.ok(st.train and st.train.name == "GZ-1", "Zug steht auf Gleis 1")
    t.eq(st.train.schedule.entries[1].instruction.data.text, "Hbf Gleis 1")
    t.eq(zentrale.register.get("GZ-1").position.where, "hbf:gleis1")
  end },
  { "belegtes bevorzugtes Gleis wird uebersprungen, ein gesperrtes ebenso", function()
    local h, z, hbf, lager, sim, zentrale = build()
    put_train(h, z, hbf, sim, "GZ-1", "Hbf Gleis 2", "gleis2")
    put_train(h, z, hbf, sim, "GZ-2", "Hbf Gleis 1", "gleis1")
    zentrale.set_closed("Hbf Gleis 2", true)
    template(zentrale, "fahrt", "GZ-1", { { station = "Hauptbahnhof", wait = 0 }, { station = "Zentrallager", wait = 3 } })
    local order = zentrale.orders.request("fahrt", nil)
    t.ok(h.until_true(function() return order.plan ~= nil end, 120), order.state .. " " .. tostring(order.reason))
    t.eq(order.plan[3].station, "Hbf Gleis 3", "Gleis 1 belegt, Gleis 2 gesperrt")
    zentrale.set_closed("Hbf Gleis 2", false)
    t.eq(zentrale.is_closed("Hbf Gleis 2"), false)
  end },
  { "Zuglaenge: ein zu kurzes Gleis wird nicht zugewiesen", function()
    local h, z, hbf, lager, sim, zentrale = build({ lengths = { 4, 8, 8 } })
    put_train(h, z, hbf, sim, "GZ-1", "Hbf Gleis 3", "gleis3", 6)
    template(zentrale, "fahrt", "GZ-1", { { station = "Hauptbahnhof", wait = 0 }, { station = "Zentrallager", wait = 3 } })
    local order = zentrale.orders.request("fahrt", nil)
    t.ok(h.until_true(function() return order.plan ~= nil end, 120), order.state .. " " .. tostring(order.reason))
    t.eq(order.plan[3].station, "Hbf Gleis 2", "Gleis 1 ist mit 4 Wagen zu kurz fuer 6")
  end },
  { "kein geeignetes Gleis: der Auftrag wartet mit Gruenden und laeuft weiter, sobald eins frei ist", function()
    local h, z, hbf, lager, sim, zentrale = build()
    put_train(h, z, hbf, sim, "GZ-1", "Hbf Gleis 1", "gleis1")
    zentrale.set_closed("Hbf Gleis 2", true)
    zentrale.set_closed("Hbf Gleis 3", true)
    zentrale.set_closed("Zentrallager", true)
    template(zentrale, "fahrt", "GZ-1", { { station = "Hauptbahnhof", wait = 0 }, { station = "Zentrallager", wait = 3 } })
    local order = zentrale.orders.request("fahrt", nil)
    t.ok(wait_state(h, order, "wartend", 30))
    t.contains(order.reason, "Kein geeignetes Gleis fuer Zentrallager")
    t.contains(order.reason, "gesperrt")
    t.eq(hbf.world.devices["Create_Station_1"].state.sets, 1, "es wurde nichts uebergeben")
    zentrale.set_closed("Zentrallager", false)
    t.ok(wait_state(h, order, "abfahrt_freigegeben", 60), order.state .. " " .. tostring(order.reason))
  end },
  { "zwei Zuege, ein Zielgleis: der zweite wartet, bis das Ziel frei ist, dann fahren beide", function()
    local h, z, hbf, lager, sim, zentrale = build()
    put_train(h, z, hbf, sim, "GZ-1", "Hbf Gleis 1", "gleis1")
    put_train(h, z, hbf, sim, "GZ-2", "Hbf Gleis 2", "gleis2")
    template(zentrale, "a", "GZ-1", { { station = "Hauptbahnhof", wait = 0 }, { station = "Zentrallager", wait = 3 } })
    template(zentrale, "b", "GZ-2", { { station = "Hauptbahnhof", wait = 0 }, { station = "Zentrallager", wait = 3 } })
    local oa = zentrale.orders.request("a", nil)
    local ob = zentrale.orders.request("b", nil)
    t.ok(h.until_true(function() return ob.state == "wartend" or oa.state == "wartend" end, 30))
    local waiting_order = ob.state == "wartend" and ob or oa
    t.contains(waiting_order.reason, "zugewiesen")
    t.ok(h.until_true(function() return oa.state == "abgeschlossen" and ob.state == "abgeschlossen" end, 700),
      oa.state .. "/" .. ob.state .. " " .. tostring(oa.reason) .. " | " .. tostring(ob.reason))
  end },
  { "Prioritaet: bevorzugt gewinnt das knappe Ziel; ein lange wartender normaler Auftrag holt auf", function()
    t.ok(orderslib.rank({ priority = "bevorzugt", created = 100 }, 100) > orderslib.rank({ priority = "normal", created = 100 }, 100))
    t.ok(orderslib.rank({ priority = "normal", created = 0 }, 130) > orderslib.rank({ priority = "bevorzugt", created = 125 }, 130), "nach genug Wartezeit hat der normale Auftrag Vorrang")
    local h, z, hbf, lager, sim, zentrale = build()
    put_train(h, z, hbf, sim, "GZ-1", "Hbf Gleis 1", "gleis1")
    put_train(h, z, hbf, sim, "GZ-2", "Hbf Gleis 2", "gleis2")
    template(zentrale, "norm", "GZ-1", { { station = "Hauptbahnhof", wait = 0 }, { station = "Zentrallager", wait = 3 } }, "normal")
    template(zentrale, "pri", "GZ-2", { { station = "Hauptbahnhof", wait = 0 }, { station = "Zentrallager", wait = 3 } }, "bevorzugt")
    local on = zentrale.orders.request("norm", nil)      -- zuerst angelegt, aber ohne Vorrang
    local op = zentrale.orders.request("pri", nil)
    t.eq(op.priority, "bevorzugt"); t.eq(on.priority, "normal")
    t.ok(h.until_true(function() return op.plan ~= nil or on.plan ~= nil end, 30))
    t.ok(op.plan ~= nil, "der bevorzugte Auftrag bekommt das Zielgleis")
    t.eq(on.plan, nil)
  end },
  { "Linie im Takt: Termine erzeugen je einen Auftrag, Zuege wechseln sich ab, nichts doppelt", function()
    local h, z, hbf, lager, sim, zentrale = build()
    put_train(h, z, hbf, sim, "GZ-1", "Hbf Gleis 1", "gleis1")
    put_train(h, z, hbf, sim, "GZ-2", "Hbf Gleis 2", "gleis2")
    template(zentrale, "pendel", "GZ-1", { { station = "Hauptbahnhof", wait = 0 }, { station = "Zentrallager", wait = 3 } })
    t.ok(zentrale.lines.set({ id = "pendel", title = "Pendel", template = "pendel", trains = { "GZ-1", "GZ-2" }, interval = 90, offset = 5 }))
    h.step(400)
    local orders = zentrale.orders.list()
    t.ok(#orders >= 3, "mindestens drei Termine bedient: " .. #orders)
    local seen = {}
    for _, o in ipairs(orders) do
      t.eq(o.source, "linie")
      t.ok(not seen[o.request_id], "Termin nur einmal: " .. tostring(o.request_id))
      seen[o.request_id] = true
      t.ok(o.request_id:match("^linie%-pendel%-%d+$"))
    end
    local trains = {}
    for _, o in ipairs(orders) do trains[o.train] = true end
    t.ok(trains["GZ-1"] and trains["GZ-2"], "beide Zuege fahren")
    local done = 0
    for _, o in ipairs(orders) do if o.state == "abgeschlossen" then done = done + 1 end end
    t.ok(done >= 2, "Fahrten werden abgeschlossen: " .. done)
    t.eq(zentrale.lines.get("pendel").missed, 0)
  end },
  { "Linie ohne bereiten Zug: Termin wird ausgelassen und gezaehlt, nie nachgeholt", function()
    local h, z, hbf, lager, sim, zentrale = build()
    put_train(h, z, hbf, sim, "GZ-1", "Hbf Gleis 1", "gleis1")
    template(zentrale, "pendel", "GZ-1", { { station = "Hauptbahnhof", wait = 0 }, { station = "Zentrallager", wait = 3 } })
    zentrale.register.set_state("GZ-1", "abgestellt")      -- nicht mehr gesteuert
    zentrale.lines.set({ id = "pendel", title = "Pendel", template = "pendel", trains = { "GZ-1" }, interval = 60, offset = 5 })
    h.step(200)
    t.eq(#zentrale.orders.list(), 0)
    local line = zentrale.lines.get("pendel")
    t.ok(line.missed >= 2, "ausgelassene Termine gezaehlt: " .. line.missed)
    t.contains(line.note, "kein Zug bereit")
    zentrale.register.set_state("GZ-1", "gesteuert")
    h.step(70)
    t.eq(#zentrale.orders.list(), 1, "nach der Rueckkehr gibt es genau eine Fahrt, keine Nachholwelle")
  end },
  { "Tafel: Plan (Termin) und Ist (Auftrag) getrennt, auch als Abfrage eines Bahnhofs", function()
    local h, z, hbf, lager, sim, zentrale = build()
    put_train(h, z, hbf, sim, "GZ-1", "Hbf Gleis 1", "gleis1")
    template(zentrale, "pendel", "GZ-1", { { station = "Hauptbahnhof", wait = 0 }, { station = "Zentrallager", wait = 3 } })
    zentrale.lines.set({ id = "pendel", title = "Pendel", template = "pendel", trains = { "GZ-1" }, interval = 200, offset = 20 })
    local rows = zentrale.board("Zentrallager")
    t.eq(#rows, 1)
    t.ok(rows[1].in_seconds > 0 and rows[1].in_seconds <= 20, "Plan: Termin in " .. rows[1].in_seconds .. " s")
    t.eq(rows[1].order, nil, "noch kein Ist")
    h.step(40)
    rows = zentrale.board("Zentrallager")
    t.ok(rows[1].order, "Ist: Auftrag laeuft")
    t.eq(rows[1].order.train, "GZ-1")
    t.eq(rows[1].order.legs, 3)
    t.eq(#zentrale.board("Nirgendwo"), 0, "Linien anderer Bahnhoefe stehen nicht auf der Tafel")
    local m = lager.node.send_to("hauptstelle", "abfrage", { kind = "tafel", station = "Zentrallager" })
    local answer
    table.insert(lager.node.hooks.on_message, 1, function(r) if r.correlationId == m.messageId then answer = r.payload end end)
    h.step(3)
    t.ok(answer and #answer.rows == 1, "Antwort der Leitstelle")
  end },
  { "Bahnhofsgruppen: Pruefungen und Speichern", function()
    local cc = dofile("tests/fakes/cc.lua")
    local storelib = require("core.store")
    local fs = cc.fs()
    fs.makeDir("/crn_data")
    local s = stationslib.new({ store = storelib.new(fs), path = "/crn_data/b.lua" })
    t.eq(s.set("Hbf", { "A", "B" }), true)
    t.eq((s.set("", { "A" })), nil)
    t.eq((s.set("X", {})), nil)
    local ok, why = s.set("Y", { "A" })
    t.eq(ok, nil); t.contains(why, "gehoert schon zum Bahnhof Hbf")
    ok, why = s.set("Z", { "C", "C" })
    t.eq(ok, nil); t.contains(why, "doppelt")
    t.eq(s.set("Hbf", { "B", "A" }), true, "Umsortieren ist erlaubt")
    local c, group = s.candidates("Hbf")
    t.eq(c[1], "B"); t.eq(group, true)
    c, group = s.candidates("Einzel")
    t.eq(c[1], "Einzel"); t.eq(group, false)
    local again = stationslib.new({ store = storelib.new(fs), path = "/crn_data/b.lua" })
    t.eq(again.get("Hbf").members[1], "B")
    t.eq(stationslib.choose({ "A", "B" }, function(n) return n == "A" and { problem = "belegt" } or {} end), "B")
    local none, reasons = stationslib.choose({ "A" }, function() return { problem = "belegt" } end)
    t.eq(none, nil); t.eq(reasons[1], "A: belegt")
  end },
  { "Linienlogik: faellig, naechster Termin in der Zukunft, ausgelassene werden gezaehlt", function()
    local cc = dofile("tests/fakes/cc.lua")
    local storelib = require("core.store")
    local fs = cc.fs()
    fs.makeDir("/crn_data")
    local clock = 100
    local l = lineslib.new({ store = storelib.new(fs), path = "/crn_data/l.lua", now = function() return clock end })
    t.eq((l.set({ id = "x", template = "v", interval = 10 })), nil, "zu kurzes Intervall")
    t.eq(l.set({ id = "x", template = "v", interval = 60, offset = 30 }), true)
    t.eq(#l.due(), 0)
    clock = 130
    t.eq(#l.due(), 1)
    local info = l.advance("x", true)
    t.eq(info.term, 130); t.eq(info.skipped, 0)
    t.eq(l.get("x").next_due, 190)
    clock = 500          -- lange Unterbrechung: 5 Termine ausgelassen, genau ein naechster Termin
    t.eq(#l.due(), 1)
    info = l.advance("x", true)
    t.eq(info.skipped, 5)
    t.eq(l.get("x").next_due, 550)
    t.eq(l.get("x").missed, 5)
    clock = 560
    l.advance("x", false)
    t.eq(l.get("x").missed, 6 + 0, "ein nicht bedienter Termin zaehlt als ausgelassen")
    t.eq((l.remove("nix")), nil)
    t.eq(l.remove("x"), true)
  end },
  { "Seite Bahnhoefe: anlegen, sperren, loeschen, Fehlertexte", function()
    local h, z, hbf, lager, sim, zentrale = build()
    zentrale.stations.remove("Hauptbahnhof")
    local v = H.open_page(z, "bahnhoefe")
    z.tap(v, "act:neu")
    z.type(v, "name", "Hauptbahnhof")
    z.type(v, "members", "Hbf Gleis 1; Hbf Gleis 2;Hbf Gleis 3")
    z.tap(v, "act:f_speichern")
    local g = zentrale.stations.get("Hauptbahnhof")
    t.eq(#g.members, 3); t.eq(g.members[2], "Hbf Gleis 2")
    t.ok(z.has(v, "Hauptbahnhof"), z.text(v))
    z.tap(v, "act:neu")
    z.type(v, "name", "Doppelt")
    z.type(v, "members", "Hbf Gleis 1")
    z.tap(v, "act:f_speichern")
    t.contains(v.hint, "gehoert schon zum Bahnhof Hauptbahnhof")
    z.tap(v, "act:f_zurueck")
    z.tap(v, "act:sperren")
    t.eq(zentrale.is_closed("Hbf Gleis 1"), true)
    t.ok(z.has(v, "gesperrt"), z.text(v))
    z.tap(v, "act:sperren")
    t.eq(zentrale.is_closed("Hbf Gleis 1"), false)
    z.tap(v, "act:loeschen")
    t.eq(zentrale.stations.get("Hauptbahnhof"), nil)
  end },
  { "Seite Linien: anlegen, ausschalten, loeschen; Vorlage bevorzugen", function()
    local h, z, hbf, lager, sim, zentrale = build()
    put_train(h, z, hbf, sim, "GZ-1", "Hbf Gleis 1", "gleis1")
    template(zentrale, "pendel", "GZ-1", { { station = "Hauptbahnhof", wait = 0 }, { station = "Zentrallager", wait = 3 } })
    local v = H.open_page(z, "vorlagen")
    z.tap(v, "act:prio")
    t.eq(zentrale.orders.template("pendel").priority, "bevorzugt")
    t.ok(z.has(v, "(bevorzugt)"), z.text(v))
    v = H.open_page(z, "linien")
    z.tap(v, "act:neu")
    z.type(v, "id", "pendel")
    z.type(v, "title", "Pendel")
    z.type(v, "template", "gibtsnicht")
    z.tap(v, "act:f_weiter")
    z.type(v, "trains", "GZ-1")
    z.type(v, "interval", "20")
    z.tap(v, "act:f_speichern")
    t.contains(v.hint, "gibtsnicht")
    z.tap(v, "act:f_zurueck")
    z.type(v, "template", "pendel")
    z.tap(v, "act:f_weiter")
    z.tap(v, "act:f_speichern")
    t.contains(v.hint, "mindestens 30")
    z.type(v, "interval", "120")
    z.tap(v, "act:f_speichern")
    local line = zentrale.lines.get("pendel")
    t.ok(line); t.eq(line.interval, 120); t.eq(line.trains[1], "GZ-1")
    t.ok(z.has(v, "alle 120 s"), z.text(v))
    z.tap(v, "act:aus")
    t.eq(zentrale.lines.get("pendel").active, false)
    h.step(200)
    t.eq(#zentrale.orders.list(), 0, "eine angehaltene Linie erzeugt keine Auftraege")
    z.tap(v, "act:aus")
    t.eq(zentrale.lines.get("pendel").active, true)
    z.tap(v, "act:loeschen")
    t.eq(zentrale.lines.get("pendel"), nil)
  end },
  { "Tafel-Seiten: Leitstelle und Bahnhof zeigen Plan und Ist getrennt", function()
    local h, z, hbf, lager, sim, zentrale = build()
    put_train(h, z, hbf, sim, "GZ-1", "Hbf Gleis 1", "gleis1")
    template(zentrale, "pendel", "GZ-1", { { station = "Hauptbahnhof", wait = 0 }, { station = "Zentrallager", wait = 3 } })
    zentrale.lines.set({ id = "pendel", title = "Pendel", template = "pendel", trains = { "GZ-1" }, interval = 300, offset = 30 })
    local zv = H.open_page(z, "tafel")
    t.ok(z.has(zv, "Plan:"), z.text(zv))
    t.ok(z.has(zv, "kein Zug unterwegs"), z.text(zv))
    local lv = H.open_page(lager, "tafel")
    h.step(14)
    lager.node.render()
    t.ok(lager.has(lv, "Pendel"), lager.text(lv))
    t.ok(lager.has(lv, "Plan: naechster Termin in"), lager.text(lv))
    h.step(40)
    lager.node.render()
    t.ok(lager.has(lv, "GZ-1:"), lager.text(lv))
    t.ok(lager.has(lv, "Ist:"), lager.text(lv))
    z.node.render()
    t.ok(z.has(zv, "GZ-1:"), z.text(zv))
  end },
}
