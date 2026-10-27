--[[
Purpose: Stufe 4 im Zusammenspiel (Leitstelle, zwei Bahnhofs-Nodes, Anmeldung, Schienensimulation): Anmeldung eines Zuges, Weizenfahrt von der Taste bis zum Abschluss, Pruefung vor der Fahrt, Verlust und Verdopplung von Nachrichten, Neustart der Leitstelle und eines Bahnhofs, fremde Zuege, unklare Ausgangslage.
]]

local t = dofile("tests/lib/t.lua")
local H = dofile("tests/lib/harness.lua")
local ser = require("core.ser")
local schedule = require("domain.schedule")

local SAMPLE_COND = { id = "create:item_threshold", data = { operator = 0, threshold = "7", measure = 0, item = { id = "minecraft:wheat" } } }

local function build(opts)
  opts = opts or {}
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
  local sim = h.sim({ { node = "weizenhof", name = "Weizenhof" }, { node = "lager", name = "Zentrallager" } }, 20)
  return h, z, w, l, sim
end

local function register_train(h, z, w, sim)
  sim.add_train("Unnamed Train", "Weizenhof", nil, 0)
  h.step(20)    -- Hallo und erste Zustandsmeldungen
  local m = w.node.roles.anmeldung.submit_registration({ id = "GZ-001", create_name = "GZ-001", display_name = "Weizenpendel", usage = "fracht", mode = "bedarf", length = 4 })
  t.ok(m, "Anmeldung gesendet")
  local ok = h.until_true(function()
    local train = z.node.roles.zentrale.register.get("GZ-001")
    return train and train.state == "gesteuert"
  end, 60)
  t.ok(ok, "Zug wird angemeldet und in den Warteauftrag gebracht")
end

local function add_template(z)
  local zentrale = z.node.roles.zentrale
  zentrale.set_sample("item_threshold", { condition = SAMPLE_COND, path = { "data", "threshold" } })
  t.eq(zentrale.orders.add_template({
    id = "weizen", title = "Weizen liefern", train = "GZ-001", return_to_start = true,
    stops = { { station = "Weizenhof", wait = 5, cargo = { count = 640 } }, { station = "Zentrallager", wait = 3 } },
  }), true)
end

local function open_page(w, id)
  local v = w.view()
  for _ = 1, 8 do
    if v.touch.find and v.touch.find("nav:" .. id) then break end
    local ok = pcall(w.tap, v, "nav:" .. id)
    if ok then return v end
    w.tap(v, "navscroll:next")
  end
  w.tap(v, "nav:" .. id)
  return v
end

local function states_of(order)
  local out = {}
  for _, h in ipairs(order.history) do out[#out + 1] = h.state end
  return table.concat(out, ">")
end

return {
  { "Netz meldet sich an: die Leitstelle kennt Nodes, Gleise und Bahnhofsnamen", function()
    local h, z, w, l = build()
    h.step(10)
    local info = z.node.roles.zentrale.info()
    t.ok(info.nodes.weizenhof, "Weizenhof gemeldet")
    t.ok(info.nodes.lager)
    t.eq(info.dir["Weizenhof"].node, "weizenhof")
    t.eq(info.dir["Zentrallager"].node, "lager")
    t.eq(info.dir["Zentrallager"].ambiguous, false)
  end },
  { "Anmeldung: Standardname wird umbenannt, der Zug registriert und in den Warteauftrag gebracht", function()
    local h, z, w, l, sim = build()
    sim.add_train("Unnamed Train", "Weizenhof", nil, 0)
    h.step(15)
    local station = w.world.devices["Create_Station_1"].state
    t.eq(station.train.name, "Unnamed Train")
    t.ok(w.node.roles.anmeldung.submit_registration({ id = "GZ-001", create_name = "GZ-001", display_name = "Weizenpendel", usage = "fracht", mode = "bedarf", length = 4 }))
    t.ok(h.until_true(function() local tr = z.node.roles.zentrale.register.get("GZ-001") return tr and tr.state == "gesteuert" end, 60))
    t.eq(station.train.name, "GZ-001", "umbenannt")
    local train = z.node.roles.zentrale.register.get("GZ-001")
    t.eq(train.display_name, "Weizenpendel")
    t.eq(train.length, 4)
    t.eq(train.position.kind, "am_bahnhof")
    local waiting = station.train.schedule
    t.eq(#schedule.check(waiting), 0)
    t.eq(waiting.entries[1].instruction.data.text, "Weizenhof")
    t.eq(w.world.sides.back, false, "der Freigabeausgang bleibt aus")
    -- die Anmeldeseite zeigt das Ergebnis
    local v = open_page(w, "anmeldung")
    t.ok(w.has(v, "Angemeldet: GZ-001"), w.text(v))
  end },
  { "Anmeldung: doppelter Name, doppelte Kennung, ohne Zug", function()
    local h, z, w, l, sim = build()
    h.step(10)
    local m, why = w.node.roles.anmeldung.submit_registration({ id = "GZ-001", create_name = "GZ-001" })
    t.eq(m, nil); t.contains(why, "kein Zug")
    sim.add_train("Unnamed Train", "Weizenhof", nil, 0)
    h.step(5)
    w.node.roles.anmeldung.submit_registration({ id = "GZ-001", create_name = "Unnamed Train" })
    h.step(15)
    t.eq(z.node.roles.zentrale.register.get("GZ-001"), nil, "Standardname wird abgewiesen")
    local found = false
    for _, msg in ipairs(w.node.messages) do end
    local v = open_page(w, "anmeldung")
    t.ok(w.has(v, "Abgelehnt: Der Standardname"), w.text(v))
  end },
  { "Weizenfahrt von der Taste bis zum Abschluss", function()
    local h, z, w, l, sim = build()
    register_train(h, z, w, sim)
    add_template(z)
    local zentrale = z.node.roles.zentrale
    t.contains(w.node.roles.anmeldung.press("weizen"), "Angefordert")
    -- Der Fahrplan ist uebergeben, die Freigabe gesetzt; der Zug wartet auf die Ladung (Create prueft sie vor create:powered)
    t.ok(h.until_true(function() local o = zentrale.orders.active_for("weizen") return o and o.state == "abfahrt_freigegeben" end, 60))
    local order = zentrale.orders.active_for("weizen")
    t.eq(w.world.sides.back, true, "Freigabe ist gesetzt (Sollzustand)")
    h.step(30)
    t.eq(order.state, "abfahrt_freigegeben", "ohne Ladung faehrt der Zug nicht, und die Leitstelle meldet keine Abfahrt")
    t.ok(w.world.devices["Create_Station_1"].state.train, "der Zug steht noch")
    local sched = w.world.devices["Create_Station_1"].state.train.schedule
    t.eq(#schedule.check(sched), 0)
    t.eq(sched.entries[1].conditions[1][2].data.threshold, "640", "Mindestens 640 als groesser als 639... (Muster fuehrt den Wert als Text)")
    -- Ladung vorhanden: Abfahrt
    sim.set_cargo("Unnamed Train", 700)
    t.ok(h.until_true(function() return order.state == "unterwegs" end, 30))
    t.eq(w.world.sides.back, false, "Freigabeausgang nach der bestaetigten Abfahrt zurueckgesetzt")
    -- Ankunft im Zentrallager, Freigabe dort, Rueckfahrt
    t.ok(h.until_true(function() return order.state == "am_ziel" or (order.leg or 0) >= 2 end, 60))
    t.ok(h.until_true(function() return order.state == "abfahrt_freigegeben" and order.leg == 2 end, 30), "Freigabe im Zentrallager")
    t.eq(l.world.sides.back, true)
    t.ok(h.until_true(function() return order.state == "unterwegs" and order.leg == 2 end, 40), "Abfahrt aus dem Zentrallager")
    t.eq(l.world.sides.back, false)
    t.ok(h.until_true(function() return order.state == "abgeschlossen" end, 100), "Rueckkehr und Abschluss; Zustand " .. order.state .. ": " .. tostring(order.reason))
    t.contains(states_of(order), "angefordert>in_pruefung>vorbereitet>fahrplan_uebergeben>abfahrt_freigegeben>unterwegs>am_ziel>abfahrt_freigegeben>unterwegs>am_ziel>abgeschlossen")
    -- nach dem Abschluss wartet der Zug am Weizenhof mit dem Warteauftrag
    h.step(5)
    local final = w.world.devices["Create_Station_1"].state.train
    t.ok(final, "Zug ist zurueck")
    t.eq(final.schedule.cyclic, true)
    t.eq(final.schedule.entries[1].instruction.data.text, "Weizenhof")
    t.eq(zentrale.register.get("GZ-001").state, "gesteuert")
    t.eq(w.world.sides.back, false)
    t.eq(l.world.sides.back, false)
    -- die Taste ist wieder frei: neuer Auftrag
    local again = zentrale.orders.request("weizen", nil)
    t.ok(again.id ~= order.id)
  end },
  { "zwei Tastendruecke ergeben genau einen Auftrag; der zweite zeigt den laufenden", function()
    local h, z, w, l, sim = build()
    register_train(h, z, w, sim)
    add_template(z)
    local first = w.node.roles.anmeldung.press("weizen")
    local second = w.node.roles.anmeldung.press("weizen")
    h.step(20)
    t.eq(#z.node.roles.zentrale.orders.list(), 1)
    h.step(15)
    local third = w.node.roles.anmeldung.press("weizen")
    t.contains(third, "Auftrag A-1 laeuft")
    t.eq(#z.node.roles.zentrale.orders.list(), 1)
    t.eq(w.world.devices["Create_Station_1"].state.sets, 2, "Warteauftrag und ein Fahrplan, nie ein dritter")
  end },
  { "Pruefung: Ziel nicht erreichbar laesst den Auftrag warten, danach geht es weiter", function()
    local h, z, w, l, sim = build()
    register_train(h, z, w, sim)
    add_template(z)
    w.world.devices["Create_Station_1"].state.known = { Weizenhof = 0 }     -- Zentrallager nicht erreichbar
    w.node.roles.anmeldung.press("weizen")
    local order
    t.ok(h.until_true(function() order = z.node.roles.zentrale.orders.active_for("weizen") return order and order.state == "wartend" end, 30))
    t.contains(order.reason, "Ziel Zentrallager nicht erreichbar")
    t.contains(order.reason, "no-target")
    t.eq(w.world.devices["Create_Station_1"].state.sets, 1, "es wurde nichts uebergeben")
    w.world.devices["Create_Station_1"].state.known = { Zentrallager = 100, Weizenhof = 0 }
    t.ok(h.until_true(function() return order.state == "abfahrt_freigegeben" end, 60))
  end },
  { "Pruefung: anderer Zug am Start wird nicht ueberschrieben", function()
    local h, z, w, l, sim = build()
    register_train(h, z, w, sim)
    add_template(z)
    -- GZ-001 faehrt weg (von Hand), ein fremder Zug mit eigenem Fahrplan steht am Start
    local st = w.world.devices["Create_Station_1"].state
    st.train.name = "Fremdzug"
    st.train.schedule = schedule.waiting("Weizenhof", 99)
    w.node.roles.anmeldung.press("weizen")
    local order
    t.ok(h.until_true(function() order = z.node.roles.zentrale.orders.active_for("weizen") return order and order.state == "wartend" end, 30))
    t.contains(order.reason, "Fremdzug")
    t.eq(st.sets, 1, "kein fremder Fahrplan wurde ueberschrieben")
    t.eq(st.train.schedule.entries[1].conditions[1][1].data.value, 99)
  end },
  { "unklare Ausgangslage: unbekannter Fahrplan des registrierten Zuges fuehrt zur Klaerung, nichts wird ueberschrieben", function()
    local h, z, w, l, sim = build()
    register_train(h, z, w, sim)
    add_template(z)
    local st = w.world.devices["Create_Station_1"].state
    st.train.schedule = schedule.waiting("Weizenhof", 42)     -- nicht der bekannte Warteauftrag
    w.node.roles.anmeldung.press("weizen")
    local order
    t.ok(h.until_true(function() order = z.node.roles.zentrale.orders.active_for("weizen") return order and order.state == "klaerung" end, 30))
    t.contains(order.reason, "unbekannten Fahrplan")
    t.eq(st.train.schedule.entries[1].conditions[1][1].data.value, 42, "unveraendert")
    t.eq(st.sets, 1)
  end },
  { "Bedarf ohne Muster fuer die Mengenbedingung wird abgelehnt", function()
    local h, z, w, l, sim = build()
    register_train(h, z, w, sim)
    z.node.roles.zentrale.orders.add_template({
      id = "weizen", title = "Weizen liefern", train = "GZ-001", return_to_start = true,
      stops = { { station = "Weizenhof", wait = 5, cargo = { count = 640 } }, { station = "Zentrallager", wait = 3 } },
    })
    w.node.roles.anmeldung.press("weizen")
    local order
    t.ok(h.until_true(function() order = z.node.roles.zentrale.orders.list()[1] return order and order.state == "abgelehnt" end, 30))
    t.contains(order.reason, "Musterfahrplan")
  end },
  { "Nachrichtenverlust, Verdopplung und Vertauschen: die Fahrt gelingt, nichts wird doppelt ausgefuehrt", function()
    for seed = 1, 12 do
      local h, z, w, l, sim = build({ bus = { seed = seed, drop = 0.25, dup = 0.3, reorder = true } })
      sim.add_train("Unnamed Train", "Weizenhof", nil, 0)
      h.step(30)
      w.node.roles.anmeldung.submit_registration({ id = "GZ-001", create_name = "GZ-001", display_name = "Weizenpendel", usage = "fracht", mode = "bedarf", length = 4 })
      local ok = h.until_true(function() local tr = z.node.roles.zentrale.register.get("GZ-001") return tr and tr.state == "gesteuert" end, 200)
      t.ok(ok, "Anmeldung trotz Verlusten (Seed " .. seed .. ")")
      add_template(z)
      w.node.roles.anmeldung.press("weizen")
      local order
      t.ok(h.until_true(function()
        order = z.node.roles.zentrale.orders.list()[1]
        if not order and w.node.roles.anmeldung.demand_state("weizen") then w.node.roles.anmeldung.press("weizen") end     -- wie ein Mensch, der noch einmal drueckt
        return order and order.state == "abfahrt_freigegeben"
      end, 300), "Freigabe (Seed " .. seed .. ")")
      sim.set_cargo("Unnamed Train", 800)
      t.ok(h.until_true(function() return order.state == "abgeschlossen" end, 600), "Abschluss (Seed " .. seed .. "), Zustand " .. order.state .. ": " .. tostring(order.reason))
      t.eq(#z.node.roles.zentrale.orders.list(), 1, "genau ein Auftrag (Seed " .. seed .. ")")
      t.eq(w.world.devices["Create_Station_1"].state.sets, 3, "Warteauftrag, Fahrplan, Warteauftrag (Seed " .. seed .. ")")
      t.eq(w.world.sides.back, false)
      t.eq(l.world.sides.back, false)
    end
  end },
  { "Neustart der Leitstelle waehrend 'Abfahrt freigegeben': kein doppelter Auftrag, kein blindes Freigeben, die Fahrt geht weiter", function()
    local h, z, w, l, sim = build()
    register_train(h, z, w, sim)
    add_template(z)
    w.node.roles.anmeldung.press("weizen")
    t.ok(h.until_true(function() local o = z.node.roles.zentrale.orders.active_for("weizen") return o and o.state == "abfahrt_freigegeben" end, 60))
    local epoch_before = z.node.roles.zentrale.info and z.node.own_epoch
    h.restart("hauptstelle")
    t.ok(z.node.own_epoch > epoch_before, "neue Epoche nach dem Neustart")
    h.step(15)
    t.eq(#z.node.roles.zentrale.orders.list(), 1, "kein doppelter Auftrag")
    local order = z.node.roles.zentrale.orders.active_for("weizen")
    t.eq(order.state, "abfahrt_freigegeben", "Zustand bleibt, es wurde nichts blind wiederholt")
    t.eq(w.world.devices["Create_Station_1"].state.sets, 2)
    sim.set_cargo("Unnamed Train", 800)
    t.ok(h.until_true(function() return order.state == "abgeschlossen" end, 200), "die Fahrt wird nach dem Neustart zu Ende gefuehrt: " .. order.state .. " " .. tostring(order.reason))
  end },
  { "Neustart eines Bahnhofs mit gesetzter Freigabe: Ausgang bleibt, Journal wird abgeglichen", function()
    local h, z, w, l, sim = build()
    register_train(h, z, w, sim)
    add_template(z)
    w.node.roles.anmeldung.press("weizen")
    t.ok(h.until_true(function() local o = z.node.roles.zentrale.orders.active_for("weizen") return o and o.state == "abfahrt_freigegeben" end, 60))
    t.eq(w.world.sides.back, true)
    h.restart("weizenhof")
    t.eq(w.world.sides.back, true, "kein pauschales Ausschalten nach dem Neustart")
    t.eq(#w.node.journal.pending(), 0, "offene Vorgaenge wurden abgeglichen")
    sim.set_cargo("Unnamed Train", 800)
    local order = z.node.roles.zentrale.orders.active_for("weizen")
    t.ok(h.until_true(function() return order.state == "unterwegs" end, 60), "Abfahrt wird nach dem Neustart gemeldet: " .. order.state)
    t.eq(w.world.sides.back, false, "Ausgang nach der Abfahrt zurueckgesetzt")
  end },
  { "unbekannter Zug faehrt ein: Meldung, keine Zuordnung", function()
    local h, z, w, l, sim = build()
    h.step(10)
    sim.add_train("Fremdzug", "Zentrallager", nil, 0)
    h.step(15)
    local texts = {}
    for _, m in ipairs(z.node.messages) do texts[#texts + 1] = m.text end
    t.contains(table.concat(texts, "|"), "Unerwarteter Zug Fremdzug")
    t.eq(z.node.roles.zentrale.register.by_create_name("Fremdzug"), nil)
  end },
  { "Zug verschwindet nach der Freigabe ohne Abfahrtsmeldung: Klaerung statt Erfolg", function()
    local h, z, w, l, sim = build()
    register_train(h, z, w, sim)
    add_template(z)
    w.node.roles.anmeldung.press("weizen")
    local order
    t.ok(h.until_true(function() order = z.node.roles.zentrale.orders.active_for("weizen") return order and order.state == "abfahrt_freigegeben" end, 60))
    -- der Zug wird von Hand entfernt (kein Ereignis)
    w.world.devices["Create_Station_1"].state.train = nil
    t.ok(h.until_true(function() return order.state == "klaerung" end, 30))
    t.contains(order.reason, "nicht mehr am Bahnhof")
    t.eq(w.world.sides.back, false, "der Ausgang wird zurueckgenommen, damit er keinen spaeteren Zug startet")
  end },
  { "Abfahrt ohne Freigabe (von Hand) waehrend 'Fahrplan uebergeben' fuehrt zur Klaerung", function()
    local h, z, w, l, sim = build()
    register_train(h, z, w, sim)
    add_template(z)
    -- Mindestaufenthalt verzoegert die Freigabe: der Zug wird vorher von Hand gestartet
    z.node.roles.zentrale.orders.add_template({ id = "lang", title = "Lang", train = "GZ-001", return_to_start = true,
      stops = { { station = "Weizenhof", wait = 400 }, { station = "Zentrallager", wait = 3 } } })
    w.node.roles.anmeldung.press("lang")
    local order
    t.ok(h.until_true(function() order = z.node.roles.zentrale.orders.active_for("lang") return order and order.state == "fahrplan_uebergeben" end, 60))
    w.world.depart("Create_Station_1")
    t.ok(h.until_true(function() return order.state == "klaerung" end, 20))
    t.contains(order.reason, "ohne Freigabe abgefahren")
  end },
  { "Freigabe eines frueheren Aufenthalts wirkt nicht auf einen spaeteren (Aufenthaltsbindung)", function()
    local h, z, w, l, sim = build()
    register_train(h, z, w, sim)
    h.step(10)
    local station_role = w.node.roles.station
    local track = station_role.tracks["gleis1"]
    local stay = track.p.stay
    -- Freigabe fuer einen alten Aufenthalt
    local requester = z.node.factory.make("auftrag", "weizenhof", { kind = "freigabe", orderId = "A-9", track = "gleis1", train = "GZ-001", stay = stay - 1 })
    z.node.send_message(requester)
    h.step(5)
    t.eq(w.world.sides.back, false, "alte Freigabe setzt nichts")
  end },
  { "Zielankunft an der falschen Station fuehrt zur Klaerung, nicht zum Erfolg", function()
    local h, z, w, l, sim = build()
    register_train(h, z, w, sim)
    add_template(z)
    w.node.roles.anmeldung.press("weizen")
    local order
    t.ok(h.until_true(function() order = z.node.roles.zentrale.orders.active_for("weizen") return order and order.state == "abfahrt_freigegeben" end, 60))
    sim.set_cargo("Unnamed Train", 800)
    t.ok(h.until_true(function() return order.state == "unterwegs" end, 30))
    l.node.send_to("hauptstelle", "meldung", { kind = "ankunft", node = "lager", track = "gleis1", train = "GZ-001", station_name = "Falschdorf", stay = 77, t = 1 })
    t.ok(h.until_true(function() return order.state == "klaerung" end, 10))
    t.contains(order.reason, "unerwarteten Station")
  end },
  { "Abfahrtsmeldung ohne bestaetigte Freigabe bringt den Auftrag nicht auf 'unterwegs'", function()
    local h, z, w, l, sim = build()
    register_train(h, z, w, sim)
    add_template(z)
    w.node.roles.anmeldung.press("weizen")
    local order
    t.ok(h.until_true(function() order = z.node.roles.zentrale.orders.active_for("weizen") return order and order.state == "abfahrt_freigegeben" end, 60))
    w.node.send_to("hauptstelle", "meldung", { kind = "abfahrt", node = "weizenhof", track = "gleis1", train = "GZ-001", released = false, unplanned = true, stay = 1, t = 1 })
    h.step(5)
    t.eq(order.state, "abfahrt_freigegeben")
  end },
  { "eingeschalteter Freigabeausgang am Start haelt den Auftrag zurueck", function()
    local h, z, w, l, sim = build()
    register_train(h, z, w, sim)
    add_template(z)
    w.world.sides.back = true
    w.node.roles.anmeldung.press("weizen")
    local order
    t.ok(h.until_true(function() order = z.node.roles.zentrale.orders.list()[1] return order and order.state == "wartend" end, 30))
    t.contains(order.reason, "Freigabeausgang")
    t.eq(w.world.devices["Create_Station_1"].state.sets, 1, "kein Fahrplan wurde uebergeben")
  end },
  { "unbeantwortete Anforderung wird selbst wiederholt, ohne zweiten Auftrag", function()
    local opts = { seed = 3, drop = 0, dup = 0 }
    local h, z, w, l, sim = build({ bus = opts })
    register_train(h, z, w, sim)
    add_template(z)
    opts.drop = 1
    w.node.roles.anmeldung.press("weizen")
    h.step(3)
    t.eq(#z.node.roles.zentrale.orders.list(), 0)
    opts.drop = 0
    h.step(12)
    t.eq(#z.node.roles.zentrale.orders.list(), 1, "die Wiederholung kam an")
    h.step(30)
    t.eq(#z.node.roles.zentrale.orders.list(), 1)
  end },
  { "Bedienung: Muster lesen und Vorlage anlegen ueber die Seite, danach die Fahrt", function()
    local h, z, w, l, sim = build()
    -- der Bediener hat in Create am Zug einen Fahrplan mit Weizen-Bedingung (Zahl 7) angelegt
    sim.add_train("Unnamed Train", "Weizenhof", nil, 0)
    local manual = { cyclic = true, entries = { { instruction = { id = "create:destination", data = { text = "Weizenhof" } }, conditions = { { { id = "create:item_threshold", data = { operator = 0, threshold = "7", measure = 0, item = { id = "minecraft:wheat" } } } } } } } }
    w.world.devices["Create_Station_1"].state.train.schedule = manual
    h.step(15)
    local v = open_page(z, "vorlagen")
    z.tap(v, "act:muster")
    z.type(v, "station", "Weizenhof")
    z.type(v, "count", "7")
    z.tap(v, "act:lesen")
    h.step(5)
    z.node.render()
    t.ok(z.has(v, "Muster gespeichert"), z.text(v))
    local sample = z.node.roles.zentrale.info().samples.item_threshold
    t.eq(table.concat(sample.path, "."), "data.threshold")
    z.tap(v, "act:vl_zurueck")
    -- Zug anmelden (Uebergabe aus der Anmeldung)
    w.node.roles.anmeldung.submit_registration({ id = "GZ-001", create_name = "GZ-001", display_name = "Weizenpendel", usage = "fracht", mode = "bedarf", length = 4 })
    t.ok(h.until_true(function() local tr = z.node.roles.zentrale.register.get("GZ-001") return tr and tr.state == "gesteuert" end, 60))
    -- Vorlage anlegen
    z.tap(v, "act:neu")
    z.type(v, "id", "weizen")
    z.type(v, "title", "Weizen liefern")
    z.tap(v, "act:vl_weiter")
    z.type(v, "train", "GZ-001")
    z.type(v, "stops", "Weizenhof:5:640; Zentrallager:3")
    z.tap(v, "act:vl_speichern")
    t.eq(#z.node.roles.zentrale.orders.templates(), 1)
    t.contains(z.text(v), "Weizen liefern")
    -- Anfordern ueber die Seite
    z.tap(v, "act:anfordern")
    local order
    t.ok(h.until_true(function() order = z.node.roles.zentrale.orders.list()[1] return order and order.state == "abfahrt_freigegeben" end, 60), "Freigabe: " .. tostring(order and order.state) .. " " .. tostring(order and order.reason))
    sim.set_cargo("Unnamed Train", 700)
    t.ok(h.until_true(function() return order.state == "abgeschlossen" end, 200), order.state .. " " .. tostring(order.reason))
  end },
  { "Vorlage: Mengenangabe ohne Muster und unbekannter Zug werden abgelehnt", function()
    local h, z, w, l, sim = build()
    register_train(h, z, w, sim)
    local zentrale = z.node.roles.zentrale
    local ok, why = zentrale.create_template({ id = "x", title = "X", train = "GZ-001", stops = "Weizenhof:5:640; Zentrallager:3" })
    t.eq(ok, nil); t.contains(why, "Muster")
    ok, why = zentrale.create_template({ id = "x", title = "X", train = "GZ-999", stops = "Weizenhof; Zentrallager" })
    t.eq(ok, nil); t.contains(why, "nicht angemeldet")
    ok, why = zentrale.create_template({ id = "x", title = "X", train = "GZ-001", stops = "Weizenhof:abc" })
    t.eq(ok, nil); t.contains(why, "keine Zahl")
    t.eq(zentrale.create_template({ id = "x", title = "X", train = "GZ-001", stops = "Weizenhof; Zentrallager:3" }), true)
  end },
  { "Muster lesen: Zahl nicht eindeutig oder keine Mengenbedingung", function()
    local h, z, w, l, sim = build()
    sim.add_train("Unnamed Train", "Weizenhof", nil, 0)
    local st = w.world.devices["Create_Station_1"].state
    st.train.schedule = schedule.waiting("Weizenhof", 5)
    h.step(10)
    local zentrale = z.node.roles.zentrale
    zentrale.read_sample("Weizenhof", "7")
    h.step(4)
    t.contains(zentrale.sample_status.text, "keine Mengenbedingung")
    st.train.schedule = { cyclic = true, entries = { { instruction = { id = "create:destination", data = { text = "Weizenhof" } }, conditions = { { { id = "create:item_threshold", data = { operator = 0, threshold = "0", measure = 0, item = { id = "x" } } } } } } } }
    zentrale.read_sample("Weizenhof", "0")
    h.step(4)
    t.contains(zentrale.sample_status.text, "mehrfach")
    zentrale.read_sample("Nirgendwo", "7")
    t.contains(zentrale.sample_status.text, "Nirgendwo")
    t.eq(zentrale.info().samples.item_threshold, nil)
  end },
}
