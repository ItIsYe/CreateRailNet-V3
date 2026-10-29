--[[
Purpose: Stufe 7 im Testnetz: Depot und manuelle Zuege. Abstellen als normaler Auftrag, abgestellte Zuege bleiben nach einem Neustart abgestellt und bekommen keine Auftraege, Aktivieren prueft Identitaet und Fahrplan, Ausschleusen und Aufnehmen nur an bestaetigtem Haltepunkt und mit Bestaetigung, Betriebsart nur am Haltepunkt, fremde Zuege werden nie zugeordnet.
]]

local t = dofile("tests/lib/t.lua")
local H = dofile("tests/lib/harness.lua")
local schedule = require("domain.schedule")

local function build()
  local h = H.new()
  local z = h.add_node({ id = "hauptstelle", roles = { "zentrale" }, tracks = {} })
  local w = h.add_node({
    id = "weizenhof", roles = { "gueterbahnhof", "anmeldung" }, central = "hauptstelle", registration = "Gleis 1",
    tracks = { { name = "Gleis 1", station_name = "Weizenhof", release_side = "back", known = { ["Depot Gleis 1"] = 100, Weizenhof = 0 } } },
  })
  local d = h.add_node({
    id = "depot1", roles = { "depot" }, central = "hauptstelle",
    tracks = { { name = "Abstell 1", station_name = "Depot Gleis 1", release_side = "back", known = { Weizenhof = 100, ["Depot Gleis 1"] = 0 } } },
  })
  local sim = h.sim({ { node = "weizenhof", name = "Weizenhof" }, { node = "depot1", name = "Depot Gleis 1" } }, 12)
  return h, z, w, d, sim
end

local function register_train(h, z, w, sim)
  sim.add_train("Unnamed Train", "Weizenhof", nil, 0)
  h.step(20)
  w.node.roles.anmeldung.submit_registration({ id = "GZ-001", create_name = "GZ-001", display_name = "Weizenpendel", usage = "fracht", mode = "bedarf", length = 4 })
  t.ok(h.until_true(function() local tr = z.node.roles.zentrale.register.get("GZ-001") return tr and tr.state == "gesteuert" end, 60))
  h.step(8)
end

local function parked(h, z, w, d, sim)
  register_train(h, z, w, sim)
  local zentrale = z.node.roles.zentrale
  local order, why = zentrale.park("GZ-001", "Depot Gleis 1")
  t.ok(order, why)
  t.ok(h.until_true(function() return order.state == "abgeschlossen" end, 200), order.state .. " " .. tostring(order.reason))
  return zentrale, order
end

local function add_template(zentrale)
  t.eq(zentrale.orders.add_template({ id = "fahrt", title = "Fahrt", train = "GZ-001", return_to_start = true, stops = { { station = "Weizenhof", wait = 0 }, { station = "Depot Gleis 1", wait = 2 } } }), true)
end

return {
  { "Abstellen: normaler Auftrag, danach ist der Zug abgestellt und wartet am Abstellgleis", function()
    local h, z, w, d, sim = build()
    local zentrale, order = parked(h, z, w, d, sim)
    t.eq(zentrale.register.get("GZ-001").state, "abgestellt")
    t.eq(order.source, "abstellen")
    t.eq(#order.plan, 2, "keine Rueckfahrt")
    local st = d.world.devices["Create_Station_1"].state
    t.ok(st.train and st.train.name == "GZ-001", "Zug steht im Depot")
    t.eq(st.train.schedule.cyclic, true)
    t.eq(st.train.schedule.entries[1].instruction.data.text, "Depot Gleis 1")
    t.eq(zentrale.register.get("GZ-001").position.where, "depot1:gleis1")
    t.eq(w.world.sides.back, false); t.eq(d.world.sides.back, false)
  end },
  { "Abstellen: Voraussetzungen werden geprueft", function()
    local h, z, w, d, sim = build()
    register_train(h, z, w, sim)
    local zentrale = z.node.roles.zentrale
    local ok, why = zentrale.park("GZ-999", "Depot Gleis 1")
    t.eq(ok, nil); t.contains(why, "Unbekannter Zug")
    ok, why = zentrale.park("GZ-001", "Nirgendwo")
    t.eq(ok, nil); t.contains(why, "unbekannt")
    add_template(zentrale)
    local order = zentrale.orders.request("fahrt", nil)
    ok, why = zentrale.park("GZ-001", "Depot Gleis 1")
    t.eq(ok, nil); t.contains(why, "laufenden Auftrag")
    t.ok(order)
  end },
  { "Abgestellte Zuege bleiben nach einem Neustart abgestellt und bekommen keine Auftraege", function()
    local h, z, w, d, sim = build()
    local zentrale = parked(h, z, w, d, sim)
    add_template(zentrale)
    h.restart("hauptstelle")
    h.step(20)
    zentrale = z.node.roles.zentrale
    t.eq(zentrale.register.get("GZ-001").state, "abgestellt")
    local order, why = zentrale.demand("fahrt", nil)
    t.eq(order, nil); t.contains(why, "nicht im gesteuerten Betrieb")
    -- eine Linie startet den Zug ebenfalls nicht
    zentrale.lines.set({ id = "pendel", title = "Pendel", template = "fahrt", trains = { "GZ-001" }, interval = 60, offset = 5 })
    h.step(150)
    t.eq(#zentrale.orders.list(), 1, "nur der Abstellauftrag")
    t.eq(zentrale.register.get("GZ-001").state, "abgestellt")
  end },
  { "Aktivieren prueft Identitaet und Fahrplan, dann ist der Zug wieder gesteuert", function()
    local h, z, w, d, sim = build()
    local zentrale = parked(h, z, w, d, sim)
    local st = d.world.devices["Create_Station_1"].state
    -- anderer Zug am Gleis
    st.train.name = "Fremdzug"
    h.step(6)                    -- Umbenennung gemeldet: Position unbekannt, Zuordnung ungeklaert
    local refused, why = zentrale.activate("GZ-001")
    t.eq(refused, nil); t.contains(why, "unbekannt")
    t.eq(zentrale.register.get("GZ-001").state, "abgestellt")
    st.train.name = "GZ-001"
    h.step(8)                    -- der Zustandsbericht belegt den Zug wieder am Gleis
    -- unbekannter Fahrplan
    local waiting = st.train.schedule
    st.train.schedule = schedule.waiting("Depot Gleis 1", 77)
    zentrale.activate("GZ-001")
    h.step(4)
    t.contains(zentrale.depot_status.text, "Warteauftrag")
    t.eq(zentrale.register.get("GZ-001").state, "abgestellt")
    -- alles in Ordnung
    st.train.schedule = waiting
    zentrale.activate("GZ-001")
    h.step(4)
    t.eq(zentrale.register.get("GZ-001").state, "gesteuert")
    t.contains(zentrale.depot_status.text, "aktiv")
    local ok, why = zentrale.activate("GZ-001")
    t.eq(ok, nil); t.contains(why, "nicht abgestellt")
  end },
  { "Aktivieren ohne Zug am Abstellgleis wird abgelehnt", function()
    local h, z, w, d, sim = build()
    local zentrale = parked(h, z, w, d, sim)
    d.world.devices["Create_Station_1"].state.train = nil
    zentrale.activate("GZ-001")
    h.step(4)
    t.contains(zentrale.depot_status.text, "kein Zug")
    t.eq(zentrale.register.get("GZ-001").state, "abgestellt")
  end },
  { "Ausschleusen: nicht waehrend eines Auftrags, sonst an bestaetigtem Haltepunkt; danach keine Auftraege", function()
    local h, z, w, d, sim = build()
    register_train(h, z, w, sim)
    local zentrale = z.node.roles.zentrale
    add_template(zentrale)
    local order = zentrale.demand("fahrt", nil)
    local ok, why = zentrale.eject("GZ-001")
    t.eq(ok, nil); t.contains(why, "laufenden Auftrag")
    t.ok(h.until_true(function() return order.state == "abgeschlossen" end, 300), order.state .. " " .. tostring(order.reason))
    ok, why = zentrale.eject("GZ-001")
    t.eq(ok, true, why)
    local train = zentrale.register.get("GZ-001")
    t.eq(train.state, "ausgeschleust"); t.eq(train.mode, "manuell")
    t.contains(why, "Fahrplan bleibt unveraendert")
    local o, e = zentrale.demand("fahrt", nil)
    t.eq(o, nil); t.contains(e, "nicht im gesteuerten Betrieb")
    ok, e = zentrale.eject("GZ-001")
    t.eq(ok, nil); t.contains(e, "schon nicht mehr")
  end },
  { "Aufnehmen: Wiederaufnahme nur mit nachgewiesenem Zug am Haltepunkt, dann Warteauftrag und gesteuert", function()
    local h, z, w, d, sim = build()
    register_train(h, z, w, sim)
    local zentrale = z.node.roles.zentrale
    t.eq(zentrale.eject("GZ-001"), true)
    -- der Zug wird von Hand umgestellt: anderer Fahrplan
    local st = w.world.devices["Create_Station_1"].state
    st.train.schedule = schedule.waiting("Weizenhof", 99)
    local ok, why = zentrale.take_over("GZ-001")
    t.eq(ok, true, why)
    h.step(5)
    local train = zentrale.register.get("GZ-001")
    t.eq(train.state, "gesteuert"); t.eq(train.mode, "bedarf")
    t.eq(st.train.schedule.entries[1].conditions[1][1].data.value, nil, "der vereinbarte Warteauftrag ersetzt den alten Fahrplan nach Uebergabe")
    -- Zug fehlt am Haltepunkt
    t.eq(zentrale.eject("GZ-001"), true)
    st.train = nil
    h.step(6)
    ok, why = zentrale.take_over("GZ-001")
    t.eq(ok, nil); t.contains(why, "nicht nachgewiesen")
    t.eq(zentrale.register.get("GZ-001").state, "ausgeschleust")
  end },
  { "Betriebsart wechselt nur am Haltepunkt und nicht waehrend eines Auftrags", function()
    local h, z, w, d, sim = build()
    register_train(h, z, w, sim)
    local zentrale = z.node.roles.zentrale
    t.eq(zentrale.cycle_mode("GZ-001"), true)
    t.eq(zentrale.register.get("GZ-001").mode, "linie")
    t.eq(zentrale.cycle_mode("GZ-001"), true)
    t.eq(zentrale.register.get("GZ-001").mode, "manuell")
    local o, e = zentrale.demand("fahrt", nil)
    add_template(zentrale)
    o, e = zentrale.demand("fahrt", nil)
    t.eq(o, nil); t.contains(e, "manuell")
    t.eq(zentrale.cycle_mode("GZ-001"), true)
    t.eq(zentrale.register.get("GZ-001").mode, "bedarf")
    -- der Zug faehrt von Hand weg: Position unbekannt, kein Wechsel
    w.world.depart("Create_Station_1")
    h.step(4)
    local ok, why = zentrale.cycle_mode("GZ-001")
    t.eq(ok, nil); t.contains(why, "Haltepunkt")
  end },
  { "manuell gefahrener Zug bleibt beobachtbar: Position folgt den Meldungen, keine Auftraege", function()
    local h, z, w, d, sim = build()
    register_train(h, z, w, sim)
    local zentrale = z.node.roles.zentrale
    zentrale.cycle_mode("GZ-001"); zentrale.cycle_mode("GZ-001")
    w.world.depart("Create_Station_1")
    h.step(4)
    t.eq(zentrale.register.get("GZ-001").position.kind, "unbekannt")
    d.world.arrive("Create_Station_1", "GZ-001", nil)
    h.step(4)
    t.eq(zentrale.register.get("GZ-001").position.where, "depot1:gleis1")
    add_template(zentrale)
    zentrale.lines.set({ id = "pendel", title = "Pendel", template = "fahrt", trains = { "GZ-001" }, interval = 60, offset = 5 })
    h.step(130)
    t.eq(#zentrale.orders.list(), 0)
  end },
  { "fremde Zuege: werden beobachtet, nie zugeordnet; vergessen nur wenn sie weg sind", function()
    local h, z, w, d, sim = build()
    h.step(8)
    local zentrale = z.node.roles.zentrale
    d.world.arrive("Create_Station_1", "Fremdzug", nil)
    h.step(6)
    local list = zentrale.unknown_list()
    t.eq(#list, 1); t.eq(list[1].name, "Fremdzug"); t.eq(list[1].present, true); t.eq(list[1].station, "Depot Gleis 1")
    local ok, why = zentrale.forget_unknown("Fremdzug")
    t.eq(ok, nil); t.contains(why, "steht noch")
    d.world.depart("Create_Station_1")
    h.step(6)
    list = zentrale.unknown_list()
    t.eq(list[1].present, false)
    t.eq(zentrale.forget_unknown("Fremdzug"), true)
    t.eq(#zentrale.unknown_list(), 0)
    t.eq(zentrale.register.by_create_name("Fremdzug"), nil)
  end },
  { "Seite Depot: Abstellen, Ausschleusen und Aufnehmen mit Bestaetigung", function()
    local h, z, w, d, sim = build()
    register_train(h, z, w, sim)
    local zentrale = z.node.roles.zentrale
    local v = H.open_page(z, "depot")
    t.ok(z.has(v, "GZ-001"), z.text(v))
    z.tap(v, "act:dp_abstellen")
    z.type(v, "ziel", "Depot Gleis 1")
    z.tap(v, "act:dp_los")
    t.ok(h.until_true(function() return zentrale.register.get("GZ-001").state == "abgestellt" end, 200))
    z.node.render()
    t.ok(z.has(v, "abgestellt"), z.text(v))
    z.tap(v, "act:dp_aktivieren")
    h.step(4)
    t.eq(zentrale.register.get("GZ-001").state, "gesteuert")
    z.tap(v, "act:dp_ausschleusen")
    t.eq(zentrale.register.get("GZ-001").state, "gesteuert", "erster Druck aendert nichts")
    z.tap(v, "act:dp_ausschleusen")
    t.eq(zentrale.register.get("GZ-001").state, "ausgeschleust")
    z.tap(v, "act:dp_aufnehmen")
    t.eq(zentrale.register.get("GZ-001").state, "ausgeschleust", "erster Druck aendert nichts")
    z.tap(v, "act:dp_aufnehmen")
    h.step(4)
    t.eq(zentrale.register.get("GZ-001").state, "gesteuert")
    local fv = H.open_page(z, "unbekannt")
    t.ok(z.has(fv, "Keine fremden Zuege"), z.text(fv))
  end },
}
