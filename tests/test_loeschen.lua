--[[
Purpose: Alles, was bei der Einrichtung angelegt wird, laesst sich auch wieder loeschen, ohne Sackgasse: Vorlagen (nicht, solange ein Auftrag oder eine Linie sie braucht), Nodes in der Leitstelle (nur stillgelegt oder ausgefallen; danach ist die Betriebsstelle frei und die Kennung gesperrt), die Einrichtung eines Computers (zweistufig, Kennung und Rollendaten bleiben, danach laesst er sich neu einrichten).
]]

local t = dofile("tests/lib/t.lua")
local H = dofile("tests/lib/harness.lua")
local cc = dofile("tests/fakes/cc.lua")
local storelib = require("core.store")
local orderslib = require("domain.orders")
local netz = require("domain.netz")

local function build()
  local h = H.new()
  local z = h.add_node({ id = "hauptstelle", roles = { "zentrale" }, tracks = {} })
  local w = h.add_node({
    id = "weizenhof", roles = { "gueterbahnhof", "anmeldung" }, central = "hauptstelle", registration = "Gleis 1",
    tracks = { { name = "Gleis 1", station_name = "Weizenhof", known = { Zentrallager = 100, Weizenhof = 0 } } },
  })
  local l = h.add_node({
    id = "lager", roles = { "gueterbahnhof" }, central = "hauptstelle",
    tracks = { { name = "Gleis 1", station_name = "Zentrallager", known = { Weizenhof = 100, Zentrallager = 0 } } },
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

local function setup_orders()
  local fs = cc.fs()
  fs.makeDir("/crn_data")
  local store = storelib.new(fs)
  local o = orderslib.new({ store = store, path = "/crn_data/auftraege.lua", now = function() return 0 end })
  return o, store, fs
end

local TEMPLATE = { id = "weizen", title = "Weizen", train = "GZ-001", return_to_start = true, stops = { { station = "Weizenhof", wait = 0 }, { station = "Zentrallager", wait = 2 } } }

return {
  { "Vorlage loeschen: unbekannte Vorlage und laufender Auftrag werden abgelehnt, sonst ist sie weg (auch nach dem Neuladen)", function()
    local o, store = setup_orders()
    t.eq(o.add_template(TEMPLATE), true)
    local ok, why = o.remove_template("gibtsnicht")
    t.eq(ok, nil); t.contains(why, "Unbekannte Vorlage")
    local order = o.request("weizen", "r1")
    t.ok(order)
    ok, why = o.remove_template("weizen")
    t.eq(ok, nil); t.contains(why, "laeuft der Auftrag " .. order.id)
    t.ok(o.template("weizen"), "die Vorlage ist noch da")
    o.transition(order.id, "storniert", "Test")
    t.eq(o.remove_template("weizen"), true)
    t.eq(o.template("weizen"), nil)
    local again = orderslib.new({ store = store, path = "/crn_data/auftraege.lua", now = function() return 0 end })
    t.eq(again.template("weizen"), nil, "gespeichert")
    t.eq(again.get(order.id).template, "weizen", "der beendete Auftrag behaelt seine Kennung")
  end },

  { "Vorlagen-Seite: Loeschen ist zweistufig; eine Linie haelt die Vorlage fest, danach geht es", function()
    local h, z, w, l, sim = build()
    local zentrale = ready(h, z, w, sim)
    zentrale.lines.set({ id = "pendel", title = "Pendel", template = "fahrt", trains = { "GZ-001" }, interval = 300 })
    local v = H.open_page(z, "vorlagen")
    z.node.render()
    t.ok(z.has(v, "Loeschen"), z.text(v))
    z.tap(v, "act:vl_loeschen")
    t.ok(zentrale.orders.template("fahrt"), "erster Druck loescht nichts")
    z.tap(v, "act:vl_loeschen")
    t.ok(zentrale.orders.template("fahrt"), "die Linie haelt die Vorlage fest")
    t.contains(v.hint or "", "Pendel")
    zentrale.lines.remove("pendel")
    z.tap(v, "act:vl_loeschen")
    z.tap(v, "act:vl_loeschen")
    t.eq(zentrale.orders.template("fahrt"), nil)
    z.node.render()
    t.ok(z.has(v, "Noch keine Vorlage"), z.text(v))
  end },

  { "Verzeichnis: eine aktivierte Node laesst sich entfernen, danach ist die Betriebsstelle frei und die Anforderung abgewiesen", function()
    local fs = cc.fs()
    fs.makeDir("/crn_data")
    local n = netz.new({ store = storelib.new(fs), path = "/crn_data/netz.lua" })
    local bf = n.add_station({ name = "Weizenhof", kind = "gueterbahnhof" })
    local entry = n.claim_node({ claim = "c1-00000100000001", role = "anmeldung", station = bf, legacy = "weizenhof" })
    t.ok(entry, "angefordert")
    t.eq(n.mark_active(entry.id), true)
    t.eq(n.node(entry.id).state, "aktiv")
    local ok, why = n.remove_station(bf)
    t.eq(ok, nil); t.contains(why, entry.id); t.contains(why, "unter Netz entfernen")
    t.eq(n.remove_node("weizenhof"), true, "auch ueber die bisherige Kennung")
    t.eq(n.node(entry.id).state, "verworfen")
    local again, why2 = n.remove_node(entry.id)
    t.eq(again, nil); t.contains(why2, "schon entfernt")
    t.eq(n.remove_node("N9999"), nil)
    t.eq(n.remove_station(bf), true, "die Betriebsstelle ist frei")
    local rejected, why3 = n.claim_node({ claim = "c1-00000100000001", role = "gueterbahnhof" })
    t.eq(rejected, nil); t.contains(why3, "verworfen")
    local fresh = n.claim_node({ claim = "c1-00000100000002", role = "gueterbahnhof" })
    t.ok(fresh and fresh.id ~= entry.id, "eine neue Anforderung bekommt eine neue Kennung")
  end },

  { "Leitstelle: laufende Node nicht entfernen; stillgelegte schon (Gleise, Sicherung und Zustand weg, bleibt abgewiesen)", function()
    local h, z, w, l, sim = build()
    local zentrale = ready(h, z, w, sim)
    h.step(40)
    t.ok(zentrale.backup_of("weizenhof"), "Sicherung angekommen")
    local ok, why = zentrale.forget_node("weizenhof")
    t.eq(ok, nil); t.contains(why, "laeuft noch")
    t.ok(zentrale.info().nodes.weizenhof)
    -- ueber die Seite Netz: Entfernen ist erst nach Stilllegen moeglich
    local nv = H.open_page(z, "netz")
    z.node.render()
    z.tap(nv, "sel:netz:2")
    z.tap(nv, "act:entfernen")
    z.tap(nv, "act:entfernen")
    t.ok(zentrale.info().nodes.weizenhof, "eine laufende Node bleibt")
    z.tap(nv, "act:stilllegen")
    z.tap(nv, "act:stilllegen")
    t.eq(zentrale.info().nodes.weizenhof.retired, true)
    z.tap(nv, "act:entfernen")
    t.ok(zentrale.info().nodes.weizenhof, "erster Druck entfernt nichts")
    z.tap(nv, "act:entfernen")
    t.eq(zentrale.info().nodes.weizenhof, nil, "entfernt")
    t.eq(zentrale.info().track_state["weizenhof:gleis1"], nil, "Gleiszustand weg")
    t.eq(zentrale.backup_of("weizenhof"), nil, "Sicherung weg")
    t.eq(zentrale.info().dir.Weizenhof, nil, "der Bahnhofsname ist nicht mehr zugeordnet")
    -- die alte Node meldet sich weiter: sie wird abgewiesen und taucht nicht wieder auf
    h.step(130)
    t.eq(zentrale.info().nodes.weizenhof, nil, "bleibt entfernt")
    z.node.render()
    local rows = 0
    for _ in z.text(nv):gmatch("1 Gleise") do rows = rows + 1 end
    t.eq(rows, 1, "nur der Lager-Node steht noch in der Liste: " .. z.text(nv))
  end },

  { "Einrichtung loeschen: zweistufig, Kennung bleibt, danach ist der Computer wieder nicht eingerichtet und laesst sich neu einrichten", function()
    local h, z, w, l, sim = build()
    ready(h, z, w, sim)
    local node = w.node
    local claim = node.config.node.claim
    local v = H.open_page(w, "einrichtung")
    node.render()
    t.ok(w.has(v, "Einrichtung loeschen"), w.text(v))
    w.tap(v, "act:loeschen")
    t.ok(node.config, "erster Druck loescht nichts")
    node.render()
    t.ok(w.has(v, "Wirklich?"), w.text(v))
    w.tap(v, "act:loeschen")
    t.eq(node.config, nil, "Einrichtung geloescht")
    t.ok(not node.store.load("/crn_data/config.lua"), "die Datei ist weg")
    t.eq(node.net, nil, "kein Funk mehr, so wie nach einem Start ohne Einrichtung")
    t.eq(next(node.roles), nil, "keine Rollen")
    if claim then t.eq(node.claim(), claim, "die Anforderungskennung bleibt") end
    node.render()
    t.ok(w.has(v, "noch nicht eingerichtet"), w.text(v))
    t.ok(w.has(v, "Einrichtung starten"), w.text(v))
    t.ok(not w.has(v, "Einrichtung loeschen"), "ohne Einrichtung gibt es nichts zu loeschen")
    -- neu einrichten ist moeglich
    w.tap(v, "act:start")
    node.render()
    t.ok(node.setup.session().wiz, "der Assistent startet")
    -- in der Leitstelle wird die Node ausgefallen und laesst sich dann entfernen
    local zentrale = z.node.roles.zentrale
    h.step(70)
    local ok, err = zentrale.forget_node("weizenhof")
    t.eq(ok, true, tostring(err))
  end },
}
