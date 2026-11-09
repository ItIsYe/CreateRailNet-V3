--[[
Purpose: Verhalten bei nicht geladenen Chunks (Computer laufen nicht, Funk und Geraeteereignisse gehen verloren, beim Laden startet der Computer kalt neu): Leitstelle weg, Bahnhof weg, beides weg, Abfahrt waehrend des Ausfalls, Anmeldung nach dem Neustart der Leitstelle.
]]

local t = dofile("tests/lib/t.lua")
local H = dofile("tests/lib/harness.lua")
local ser = require("core.ser")

local SAMPLE_COND = { id = "create:item_threshold", data = { operator = 0, threshold = "7", measure = 0, item = { id = "minecraft:wheat" } } }

local function build()
  local h = H.new()
  local z = h.add_node({ id = "hauptstelle", roles = { "zentrale" }, tracks = {} })
  local w = h.add_node({
    id = "weizenhof", roles = { "bahnhof", "anmeldung" }, central = "hauptstelle", registration = "Gleis 1",
    tracks = { { name = "Gleis 1", station_name = "Weizenhof", known = { Zentrallager = 100, Weizenhof = 0 } } },
  })
  local l = h.add_node({
    id = "lager", roles = { "bahnhof" }, central = "hauptstelle",
    tracks = { { name = "Gleis 1", station_name = "Zentrallager", known = { Weizenhof = 100, Zentrallager = 0 } } },
  })
  local sim = h.sim({ { node = "weizenhof", name = "Weizenhof" }, { node = "lager", name = "Zentrallager" } }, 20)
  sim.add_train("Unnamed Train", "Weizenhof", nil, 0)
  h.step(20)
  w.node.roles.anmeldung.submit_registration({ id = "GZ-001", create_name = "GZ-001", display_name = "Weizenpendel", usage = "fracht", mode = "bedarf", length = 4 })
  t.ok(h.until_true(function() local tr = z.node.roles.zentrale.register.get("GZ-001") return tr and tr.state == "gesteuert" end, 60), "Zug angemeldet")
  local zentrale = z.node.roles.zentrale
  zentrale.set_sample("item_threshold", { condition = SAMPLE_COND, path = { "data", "threshold" } })
  zentrale.orders.add_template({ id = "weizen", title = "Weizen liefern", train = "GZ-001", return_to_start = true,
    stops = { { station = "Weizenhof", wait = 5, cargo = { count = 640 } }, { station = "Zentrallager", wait = 3 } } })
  return h, z, w, l, sim
end

-- Auftrag starten und bis zur Freigabe am Weizenhof bringen
local function released(h, z, w)
  w.node.roles.anmeldung.press("weizen")
  local order
  t.ok(h.until_true(function() order = z.node.roles.zentrale.orders.active_for("weizen") return order and order.state == "abfahrt_freigegeben" end, 90), "Freigabe gesetzt")
  return order.id
end

local function order_of(z, id) return z.node.roles.zentrale.orders.get(id) end

local function texts(node, from)
  local out = {}
  for i = (from or 0) + 1, #node.messages do out[#out + 1] = node.messages[i].text end
  return table.concat(out, "|")
end

return {
  { "Ein entladener Computer laeuft nicht: kein Takt, Funk und Geraeteereignisse gehen verloren, beim Laden startet er kalt", function()
    local h, z, w, l, sim = build()
    local boots = w.node.clock.boot_id()
    local before = w.node.clock.now()
    h.unload("weizenhof")
    h.step(30)
    t.eq(w.node.clock.now(), before, "die Betriebsuhr steht")
    h.load("weizenhof")
    t.eq(w.node.clock.boot_id(), boots + 1, "ein neuer Start")
  end },
  { "Leitstelle entladen und wieder geladen: die Fahrt geht weiter, nichts wird doppelt oder blind wiederholt", function()
    for _, down in ipairs({ 20, 130 }) do
      local h, z, w, l, sim = build()
      local id = released(h, z, w)
      h.unload("hauptstelle")
      sim.set_cargo("Unnamed Train", 800)
      h.step(down)
      h.load("hauptstelle")
      t.ok(h.until_true(function() return order_of(z, id).state == "abgeschlossen" end, 300), "nach " .. down .. " s: Zustand " .. order_of(z, id).state .. " " .. tostring(order_of(z, id).reason))
      t.eq(#z.node.roles.zentrale.orders.list(), 1, "kein doppelter Auftrag")
      t.eq(w.node.roles.station.tracks[1].p.release_set, false); t.eq(l.node.roles.station.tracks[1].p.release_set, false)
    end
  end },
  { "Leitstelle neu geladen: sie kennt die Nodes nach wenigen Sekunden (die Anmeldung wird erbeten), nicht erst nach zwei Minuten", function()
    local h, z, w, l, sim = build()
    h.step(30)
    local asked = 0
    h.bus.filter = function(from, to, text)
      local ok, m = pcall(ser.decode, text)
      if ok and type(m) == "table" and m.payload and m.payload.kind == "hallo_senden" then asked = asked + 1 end
      return false
    end
    h.unload("hauptstelle")
    h.step(10)
    h.load("hauptstelle")
    local zentrale = z.node.roles.zentrale
    t.eq(zentrale.info().nodes.weizenhof, nil, "frisch gestartet: noch keine Node bekannt")
    t.ok(h.until_true(function() local i = zentrale.info() return i.nodes.weizenhof and i.nodes.lager and i.dir["Weizenhof"] and i.dir["Zentrallager"] end, 20), "Nodes und Bahnhoefe bekannt")
    t.ok(asked >= 2 and asked <= 4, "jede Node wurde einmal gebeten: " .. asked)
    -- bekannte Nodes werden nicht mehr gefragt
    local before = asked
    h.step(120)
    t.eq(asked, before, "keine weiteren Bitten")
  end },
  { "Die Bitte um Anmeldung gilt nur unbekannten Nodes (bei einer Zustandsmeldung), hoechstens alle 30 Sekunden, und nicht stillgelegten", function()
    local h, z, w, l, sim = build()
    h.step(30)
    local zentrale = z.node.roles.zentrale
    local asked = {}
    local real = z.node.send_to
    z.node.send_to = function(target, kind, payload, extra)
      if payload and payload.kind == "hallo_senden" then asked[#asked + 1] = target end
      return real(target, kind, payload, extra)
    end
    local function from(sender, kind)
      local m = w.node.factory.make("meldung", "hauptstelle", { kind = kind, node = sender, tracks = {}, t = 1 })
      m.senderNodeId = sender
      zentrale.on_message(m, "ok")
    end
    -- jede dieser Meldungen einer unbekannten Node loest die Bitte aus, nicht aber die Meldung einer bekannten
    from("x1", "zustand"); from("x2", "zustand"); from("x3", "zustand")
    t.eq(#asked, 3, "drei unbekannte Nodes, drei Bitten")
    from("weizenhof", "zustand")
    t.eq(#asked, 3, "bekannte Nodes werden nicht gebeten")
    -- hoechstens alle 30 Sekunden je Node
    from("x1", "zustand"); from("x1", "zustand")
    t.eq(#asked, 3, "innerhalb von 30 Sekunden nicht noch einmal")
    h.step(10)
    from("x1", "zustand")
    t.eq(#asked, 3, "auch nach 10 Sekunden nicht")
    h.step(21)
    from("x1", "zustand")
    t.eq(#asked, 4, "nach mehr als 30 Sekunden wieder")
    t.eq(asked[4], "x1")
    -- stillgelegt: nie
    zentrale.info().nodes.x4 = { name = "x4" }
    t.eq(zentrale.retire("x4"), true)
    zentrale.info().nodes.x4 = nil
    from("x4", "zustand")
    t.eq(#asked, 4, "stillgelegte Nodes werden nicht gebeten")
  end },
  { "Bahnhof entladen, waehrend der Zug mit Freigabe abfaehrt: nach dem Laden ist die Freigabe verbraucht, die Leitstelle klaert statt zu haengen", function()
    for _, down in ipairs({ 20, 130 }) do
      local h, z, w, l, sim = build()
      local id = released(h, z, w)
      t.eq(w.node.roles.station.tracks[1].p.release_set, true)
      local from = #w.node.messages
      h.unload("weizenhof")
      sim.set_cargo("Unnamed Train", 800)
      h.step(down)
      t.eq(w.node.roles.station.tracks[1].p.release_set, true, "ohne Betrieb bleibt die Freigabe, wie sie war")
      h.load("weizenhof")
      t.ok(h.until_true(function() return order_of(z, id).state == "klaerung" end, 20), "nach " .. down .. " s: Klaerung, Zustand " .. order_of(z, id).state)
      t.contains(order_of(z, id).reason, "nicht mehr am Bahnhof")
      t.eq(w.node.roles.station.tracks[1].p.release_set, false, "Freigabe verbraucht (der Zug gehoerte nicht mehr dazu)")
      t.contains(texts(w.node, from), "fiel in die Zeit ohne Betrieb")
      t.eq(#w.node.journal.pending(), 0)
    end
  end },
  { "Beim Laden steht ein anderer Zug am Gleis: die Freigabe ist verbraucht, der fremde Zug faehrt nicht ohne Freigabe ab", function()
    local h, z, w, l, sim = build()
    local id = released(h, z, w)
    local stay_before = w.node.roles.station.tracks[1].p.stay
    h.unload("weizenhof")
    sim.set_cargo("Unnamed Train", 800)
    h.step(30)                                         -- der freigegebene Zug ist weg
    sim.add_train("Fremdzug", "Weizenhof", nil, 0)     -- ein anderer kommt an
    h.step(5)
    h.load("weizenhof")
    h.step(3)
    t.eq(w.node.roles.station.tracks[1].p.release_set, false, "Freigabe verbraucht, bevor der fremde Zug etwas davon haben kann")
    t.eq(w.world.devices["Create_Station_1"].state.train.name, "Fremdzug", "der fremde Zug steht noch")
    t.eq(order_of(z, id).state, "klaerung")
    -- der fremde Zug ist ein neuer Aufenthalt und der Leitstelle als Ankunft gemeldet
    t.eq(w.node.roles.station.tracks[1].train, "Fremdzug")
    t.eq(w.node.roles.station.tracks[1].p.stay, stay_before + 1, "neuer Aufenthalt")
    t.contains(texts(z.node), "Unerwarteter Zug Fremdzug")
  end },
  { "Bahnhof entladen, der freigegebene Zug steht beim Laden noch da: Freigabe bleibt, die Fahrt geht weiter", function()
    local h, z, w, l, sim = build()
    local id = released(h, z, w)
    h.unload("weizenhof")
    h.step(40)
    h.load("weizenhof")
    h.step(5)
    t.eq(w.node.roles.station.tracks[1].p.release_set, true, "Freigabe bleibt (Zug wartet auf Ladung)")
    t.eq(order_of(z, id).state, "abfahrt_freigegeben")
    sim.set_cargo("Unnamed Train", 800)
    t.ok(h.until_true(function() return order_of(z, id).state == "abgeschlossen" end, 300), "Zustand " .. order_of(z, id).state)
  end },
  { "Abfahrtsmeldung ging verloren (Leitstelle und Bahnhof entladen): der Zustand traegt die Abfahrt nach, die Fahrt wird zu Ende gefuehrt", function()
    local h, z, w, l, sim = build()
    local id = released(h, z, w)
    h.unload("hauptstelle")
    sim.set_cargo("Unnamed Train", 800)
    t.ok(h.until_true(function() return w.world.devices["Create_Station_1"].state.train == nil end, 40), "der Zug ist abgefahren")
    h.step(1)                                           -- die Abfahrtsmeldung steht unbestaetigt im Speicher des Bahnhofs
    h.unload("weizenhof")                               -- und geht mit dem Neustart verloren
    h.step(40)
    h.load("weizenhof"); h.load("hauptstelle")
    t.ok(h.until_true(function() return order_of(z, id).state == "abgeschlossen" end, 300), "Zustand " .. order_of(z, id).state .. ": " .. tostring(order_of(z, id).reason))
  end },
  { "Bahnhof vor der Pruefung entladen: bis etwa 96 Sekunden wird gewartet, danach ehrliche Klaerung", function()
    local h, z, w, l, sim = build()
    w.node.roles.anmeldung.press("weizen")
    h.unload("weizenhof")
    h.step(1)
    local id = z.node.roles.zentrale.orders.active_for("weizen").id
    h.step(60)
    h.load("weizenhof")
    t.ok(h.until_true(function() return order_of(z, id).state == "abfahrt_freigegeben" end, 90), "nach 60 s: weiter, Zustand " .. order_of(z, id).state)
    local h2, z2, w2 = build()
    w2.node.roles.anmeldung.press("weizen")
    h2.unload("weizenhof")
    h2.step(1)
    local id2 = z2.node.roles.zentrale.orders.active_for("weizen").id
    h2.step(130)
    t.eq(order_of(z2, id2).state, "klaerung")
    t.contains(order_of(z2, id2).reason, "Keine Rueckmeldung von weizenhof")
  end },
  { "Erscheint das Funkmodem erst nach dem Start (Chunk geladen, Kabelnetz verbindet sich spaeter), oeffnet der Node es nachtraeglich", function()
    local h, z, w, l = build()
    h.step(10)
    t.ok(z.node.roles.zentrale.info().nodes.weizenhof, "vorher bekannt")
    -- Neustart ohne angeschlossenes Modem
    w.world.detach("left"); w.world.detach("right")
    h.unload("weizenhof"); h.load("weizenhof")
    t.eq(#w.node.net_info.opened, 0, "kein Modem beim Start")
    -- das Modem erscheint
    w.world.add_modem("left", true)
    w.node.handle({ "peripheral", "left" })
    t.eq(w.node.net_info.opened[1], "left")
    local text = ""
    for _, m in ipairs(w.node.messages) do text = text .. "|" .. m.text end
    t.contains(text, "Funkmodem angeschlossen: left")
    -- ein weiteres Geraet aendert nichts am Funk und meldet nichts Doppeltes
    local count = 0
    for _, m in ipairs(w.node.messages) do if m.text:find("Funkmodem angeschlossen", 1, true) then count = count + 1 end end
    w.world.add_signal("Create_Signal_9"); w.node.handle({ "peripheral", "Create_Signal_9" })
    local count2 = 0
    for _, m in ipairs(w.node.messages) do if m.text:find("Funkmodem angeschlossen", 1, true) then count2 = count2 + 1 end end
    t.eq(count2, count)
  end },
}
