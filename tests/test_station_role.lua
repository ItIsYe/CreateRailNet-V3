--[[
Purpose: Gleisseite der Bahnhofs-Rolle einzeln gegen eine Test-Leitstelle: Voraussetzungen jeder Aufgabe (richtiger Zug, kein blindes Ueberschreiben, Aufenthaltsbindung, Restwartezeit, bestaetigter Abschnittsfahrplan als Freigabe), Berichte bei unplanmaessiger Abfahrt und verschwundenem Zug.
]]

local t = dofile("tests/lib/t.lua")
local H = dofile("tests/lib/harness.lua")
local schedule = require("domain.schedule")

local function build()
  local h = H.new()
  local z = h.add_node({ id = "hauptstelle", roles = { "zentrale" }, tracks = {} })
  local w = h.add_node({
    id = "bf", roles = { "bahnhof" }, central = "hauptstelle",
    tracks = { { name = "Gleis 1", station_name = "Bahnhof A", known = { ["Bahnhof B"] = 10, ["Bahnhof A"] = 0 } } },
  })
  local sim = h.sim({ { node = "bf", name = "Bahnhof A" } }, 10)
  return h, z, w, sim
end

-- sendet eine Aufgabe und liefert die Antwortnutzdaten
local function ask(h, z, kind_type, payload)
  local m = z.node.send_to("bf", kind_type, payload)
  local answer
  table.insert(z.node.hooks.on_message, 1, function(r) if r.correlationId == m.messageId then answer = r.payload end end)
  h.step(3)
  table.remove(z.node.hooks.on_message, 1)
  return answer
end

local function collect(z)
  local seen = {}
  table.insert(z.node.hooks.on_message, 1, function(r) if r.messageType == "meldung" then seen[#seen + 1] = r.payload end end)
  return seen
end

local function stay_of(w) return w.node.roles.station.tracks["gleis1"].p.stay end

local function with_train(name)
  local h, z, w, sim = build()
  sim.add_train(name, "Bahnhof A", nil, 0)
  h.step(6)
  return h, z, w, sim
end

return {
  { "Pruefung: Zug, Ziele und Ausgangslage werden gemeldet", function()
    local h, z, w = with_train("GZ-1")
    local a = ask(h, z, "abfrage", { kind = "pruefen", track = "gleis1", targets = { "Bahnhof B", "Nirgendwo" } })
    t.eq(a.present, true); t.eq(a.train, "GZ-1"); t.ok(not a.has_schedule)
    t.eq(a.reach["Bahnhof B"].ok, true)
    t.eq(a.reach["Nirgendwo"].ok, false)
  end },
  { "Fahrplan fuer einen anderen als den angegebenen Zug wird abgelehnt", function()
    local h, z, w = with_train("GZ-1")
    local a = ask(h, z, "auftrag", { kind = "warteauftrag", track = "gleis1", train = "GZ-2", wait = 0 })
    t.eq(a.status, "abgelehnt"); t.contains(a.grund, "GZ-1")
    t.eq(w.world.devices["Create_Station_1"].state.sets or 0, 0)
  end },
  { "ohne Zug am Bahnhof wird nichts uebergeben oder freigegeben", function()
    local h, z, w = build()
    h.step(6)
    local a = ask(h, z, "auftrag", { kind = "warteauftrag", track = "gleis1", train = "GZ-1", wait = 0 })
    t.eq(a.status, "abgelehnt"); t.contains(a.grund, "kein Zug")
    local f = ask(h, z, "auftrag", { kind = "freigabe", track = "gleis1", train = "GZ-1", stay = 0, orderId = "A-1" })
    t.eq(f.status, "abgelehnt")
    t.eq(w.node.roles.station.tracks["gleis1"].p.release_set, false)
  end },
  { "Warteauftrag: unbekannter Fahrplan verlangt Klaerung, mit Uebergabe geht es", function()
    local h, z, w = with_train("GZ-1")
    local st = w.world.devices["Create_Station_1"].state
    st.train.schedule = schedule.waiting("Bahnhof A", 77)
    local a = ask(h, z, "auftrag", { kind = "warteauftrag", track = "gleis1", train = "GZ-1", wait = 0 })
    t.eq(a.status, "abgelehnt"); t.eq(a.klaerung, true)
    t.eq(st.sets or 0, 0)
    local b = ask(h, z, "auftrag", { kind = "warteauftrag", track = "gleis1", train = "GZ-1", wait = 0, handover = true })
    t.eq(b.status, "uebergeben")
    t.eq(st.sets, 1)
  end },
  { "Auftrag annehmen: nur aus dem bekannten Warteauftrag, gesetzt wird dabei kein Fahrplan", function()
    local h, z, w = with_train("GZ-1")
    local st = w.world.devices["Create_Station_1"].state
    st.train.schedule = schedule.waiting("Bahnhof A", 77)      -- kein bekannter Zustand
    local a = ask(h, z, "auftrag", { kind = "fahrplan", track = "gleis1", train = "GZ-1", orderId = "A-1" })
    t.eq(a.status, "abgelehnt"); t.eq(a.klaerung, true)
    t.eq(st.train.schedule.entries[1].conditions[1][1].data.value, 77)
    -- nach dem Warteauftrag ist die Ausgangslage bekannt
    t.eq(ask(h, z, "auftrag", { kind = "warteauftrag", track = "gleis1", train = "GZ-1", wait = 0, handover = true }).status, "uebergeben")
    local sets = st.sets
    local b = ask(h, z, "auftrag", { kind = "fahrplan", track = "gleis1", train = "GZ-1", orderId = "A-1" })
    t.eq(b.status, "uebergeben"); t.eq(b.ergebnis, "haelt")
    t.eq(st.sets, sets, "der Zug behaelt den Warteauftrag")
    t.eq(ask(h, z, "auftrag", { kind = "fahrplan", track = "gleis1", train = "GZ-1", orderId = "A-1" }).status, "uebergeben", "Wiederholung ist unschaedlich")
  end },
  { "Freigabe: unzulaessiger Abschnitt, falscher Bahnhof und unklare Lage werden abgelehnt, es wird nichts gesetzt", function()
    local h, z, w = with_train("GZ-1")
    local st = w.world.devices["Create_Station_1"].state
    local stay = stay_of(w)
    ask(h, z, "auftrag", { kind = "warteauftrag", track = "gleis1", train = "GZ-1", wait = 0, handover = true })
    local sets = st.sets
    local bad = { cyclic = false, entries = { { instruction = { id = "create:destination", data = { text = "Bahnhof B" } }, conditions = {} } } }
    local a = ask(h, z, "auftrag", { kind = "freigabe", track = "gleis1", train = "GZ-1", stay = stay, orderId = "A-1", schedule = bad })
    t.eq(a.status, "abgelehnt"); t.contains(a.grund, "unzulaessig")
    local none = ask(h, z, "auftrag", { kind = "freigabe", track = "gleis1", train = "GZ-1", stay = stay, orderId = "A-1" })
    t.eq(none.status, "abgelehnt"); t.contains(none.grund, "unzulaessig")
    local elsewhere = ask(h, z, "auftrag", { kind = "freigabe", track = "gleis1", train = "GZ-1", stay = stay, orderId = "A-1", schedule = schedule.section("Bahnhof C", { wait = 500 }, "Bahnhof B") })
    t.eq(elsewhere.status, "abgelehnt"); t.contains(elsewhere.grund, "beginnt in Bahnhof C")
    st.train.schedule = schedule.waiting("Bahnhof A", 77)      -- unbekannter Fahrplan
    local unknown = ask(h, z, "auftrag", { kind = "freigabe", track = "gleis1", train = "GZ-1", stay = stay, orderId = "A-1", schedule = schedule.section("Bahnhof A", { wait = 500 }, "Bahnhof B") })
    t.eq(unknown.status, "abgelehnt"); t.eq(unknown.klaerung, true)
    t.eq(st.sets, sets, "nichts gesetzt")
    t.eq(st.train.schedule.entries[1].conditions[1][1].data.value, 77, "fremder Fahrplan blieb")
    t.eq(w.node.roles.station.tracks["gleis1"].p.release_set, false)
  end },
  { "Freigabe: Abschnittsfahrplan mit Restwartezeit, Aufenthaltsbindung und Wiederholung", function()
    local h, z, w = with_train("GZ-1")
    local st = w.world.devices["Create_Station_1"].state
    local stay = stay_of(w)
    ask(h, z, "auftrag", { kind = "warteauftrag", track = "gleis1", train = "GZ-1", wait = 0, handover = true })
    local section = schedule.section("Bahnhof A", { wait = 500 }, "Bahnhof B")
    local old = ask(h, z, "auftrag", { kind = "freigabe", track = "gleis1", train = "GZ-1", stay = stay - 1, orderId = "A-1", schedule = section, wait = 500 })
    t.eq(old.status, "abgelehnt"); t.contains(old.grund, "anderer Aufenthalt")
    local ok = ask(h, z, "auftrag", { kind = "freigabe", track = "gleis1", train = "GZ-1", stay = stay, orderId = "A-1", schedule = section, wait = 500 })
    t.eq(ok.status, "freigabe_gesetzt"); t.eq(ok.abfahrt_bestaetigt, false)
    local set = st.train.schedule
    t.eq(set.entries[1].instruction.data.text, "Bahnhof A")
    t.eq(set.entries[2].instruction.data.text, "Bahnhof B")
    local delay = set.entries[1].conditions[1][1].data.value
    t.ok(delay < 500 and delay > 400, "nur die Restzeit steht im Fahrplan: " .. tostring(delay))
    t.eq(#schedule.check_section(set), 0)
    local tr = w.node.roles.station.tracks["gleis1"]
    t.eq(tr.p.release_set, true); t.eq(tr.p.release_train, "GZ-1"); t.eq(tr.p.release_stay, stay)
    local again = ask(h, z, "auftrag", { kind = "freigabe", track = "gleis1", train = "GZ-1", stay = stay, orderId = "A-1", schedule = section, wait = 500 })
    t.eq(again.status, "freigabe_gesetzt"); t.eq(again.hinweis, "schon gesetzt")
  end },
  { "Freigabe: gilt nur fuer Zug und Aufenthalt der Freigabe; Folgeabschnitt braucht die Streckenkennung des vorigen", function()
    local h, z, w, sim = with_train("GZ-1")
    local st = w.world.devices["Create_Station_1"].state
    local stay = stay_of(w)
    ask(h, z, "auftrag", { kind = "warteauftrag", track = "gleis1", train = "GZ-1", wait = 0, handover = true })
    local section = schedule.section("Bahnhof A", { wait = 500 }, "Bahnhof B")
    ask(h, z, "auftrag", { kind = "freigabe", track = "gleis1", train = "GZ-1", stay = stay, orderId = "A-1", schedule = section, wait = 500 })
    local other = ask(h, z, "auftrag", { kind = "freigabe", track = "gleis1", train = "GZ-2", stay = stay, orderId = "A-2", schedule = section, wait = 500 })
    t.eq(other.status, "abgelehnt", "ein anderer Zug bekommt keine 'schon gesetzt'-Antwort")
    local other_stay = ask(h, z, "auftrag", { kind = "freigabe", track = "gleis1", train = "GZ-1", stay = stay + 1, orderId = "A-2", schedule = section, wait = 500 })
    t.eq(other_stay.status, "abgelehnt")
    -- der Zug kommt in einem neuen Aufenthalt wieder, mit dem Abschnittsfahrplan eines anderen Bahnhofs im Fahrplan
    local prior = schedule.section("Bahnhof C", { wait = 0 }, "Bahnhof A")
    w.world.depart("Create_Station_1")
    h.step(3)
    w.world.arrive("Create_Station_1", "GZ-1", prior)
    sim.trains["GZ-1"].last = require("core.ser").encode(prior)       -- die Simulation soll den Fahrplan nicht als neuen Auftrag lesen
    sim.trains["GZ-1"].progress = 2
    h.step(3)
    local stay2 = stay_of(w)
    local next_section = schedule.section("Bahnhof A", { wait = 500 }, "Bahnhof B")
    local before = st.sets
    local blind = ask(h, z, "auftrag", { kind = "freigabe", track = "gleis1", train = "GZ-1", stay = stay2, orderId = "A-3", schedule = next_section, wait = 500 })
    t.eq(blind.status, "abgelehnt"); t.eq(blind.klaerung, true, tostring(blind.grund))
    t.eq(st.sets, before)
    local known = ask(h, z, "auftrag", { kind = "freigabe", track = "gleis1", train = "GZ-1", stay = stay2, orderId = "A-3", schedule = next_section, wait = 500, expect = schedule.route_hash(prior) })
    t.eq(known.status, "freigabe_gesetzt")
  end },
  { "Freigabe: der Fahrplan wird nicht uebernommen (Bahnhof liest etwas anderes): keine Freigabe, kein Sollzustand", function()
    local h, z, w = with_train("GZ-1")
    local st = w.world.devices["Create_Station_1"].state
    local stay = stay_of(w)
    ask(h, z, "auftrag", { kind = "warteauftrag", track = "gleis1", train = "GZ-1", wait = 0, handover = true })
    st.ignore_set = true
    local a = ask(h, z, "auftrag", { kind = "freigabe", track = "gleis1", train = "GZ-1", stay = stay, orderId = "A-1", schedule = schedule.section("Bahnhof A", { wait = 500 }, "Bahnhof B"), wait = 500 })
    t.eq(a.status, "abgelehnt"); t.contains(a.grund, "nicht uebernommen")
    t.eq(w.node.roles.station.tracks["gleis1"].p.release_set, false, "ohne Bestaetigung kein Sollzustand")
  end },
  { "Warteauftrag: bei offener Freigabe erst zuruecknehmen", function()
    local h, z, w = with_train("GZ-1")
    local stay = stay_of(w)
    ask(h, z, "auftrag", { kind = "warteauftrag", track = "gleis1", train = "GZ-1", wait = 0, handover = true })
    ask(h, z, "auftrag", { kind = "freigabe", track = "gleis1", train = "GZ-1", stay = stay, orderId = "A-1", schedule = schedule.section("Bahnhof A", { wait = 500 }, "Bahnhof B"), wait = 500 })
    local c = ask(h, z, "auftrag", { kind = "warteauftrag", track = "gleis1", train = "GZ-1", wait = 0 })
    t.eq(c.status, "abgelehnt"); t.contains(c.grund, "zuruecknehmen")
  end },
  { "Abfahrt ohne Freigabe wird als unplanmaessig gemeldet, mit Freigabe nicht; die Freigabe ist danach verbraucht", function()
    local h, z, w = with_train("GZ-1")
    local seen = collect(z)
    w.world.depart("Create_Station_1")
    h.step(3)
    local dep
    for _, p in ipairs(seen) do if p.kind == "abfahrt" then dep = p end end
    t.ok(dep, "Abfahrt gemeldet")
    t.eq(dep.unplanned, true); t.eq(dep.released, false)
    -- zweiter Aufenthalt mit Freigabe
    w.world.arrive("Create_Station_1", "GZ-1")
    h.step(3)
    local stay = stay_of(w)
    ask(h, z, "auftrag", { kind = "warteauftrag", track = "gleis1", train = "GZ-1", wait = 0, handover = true })
    ask(h, z, "auftrag", { kind = "freigabe", track = "gleis1", train = "GZ-1", stay = stay, orderId = "A-1", schedule = schedule.section("Bahnhof A", { wait = 500 }, "Bahnhof B"), wait = 500 })
    local tr = w.node.roles.station.tracks["gleis1"]
    t.eq(tr.p.release_set, true)
    seen = collect(z)
    w.world.depart("Create_Station_1")
    h.step(3)
    for _, p in ipairs(seen) do if p.kind == "abfahrt" then dep = p end end
    t.eq(dep.released, true); t.eq(dep.unplanned, nil)
    t.eq(tr.p.release_set, false); t.eq(tr.p.release_train, nil)
  end },
  { "Zug verschwindet ohne Ereignis: 'zug_weg' wird gemeldet, die Freigabe ist verbraucht", function()
    local h, z, w = with_train("GZ-1")
    local stay = stay_of(w)
    ask(h, z, "auftrag", { kind = "warteauftrag", track = "gleis1", train = "GZ-1", wait = 0, handover = true })
    ask(h, z, "auftrag", { kind = "freigabe", track = "gleis1", train = "GZ-1", stay = stay, orderId = "A-1", schedule = schedule.section("Bahnhof A", { wait = 500 }, "Bahnhof B"), wait = 500 })
    local seen = collect(z)
    w.world.devices["Create_Station_1"].state.train = nil
    h.step(4)
    local gone
    for _, p in ipairs(seen) do if p.kind == "zug_weg" then gone = p end end
    t.ok(gone); t.eq(gone.train, "GZ-1")
    t.eq(w.node.roles.station.tracks["gleis1"].p.release_set, false)
  end },
  { "Freigabe zuruecknehmen (Bediener): der stehende Zug bekommt wieder den Warteauftrag", function()
    local h, z, w = with_train("GZ-1")
    local st = w.world.devices["Create_Station_1"].state
    local stay = stay_of(w)
    ask(h, z, "auftrag", { kind = "warteauftrag", track = "gleis1", train = "GZ-1", wait = 0, handover = true })
    ask(h, z, "auftrag", { kind = "freigabe", track = "gleis1", train = "GZ-1", stay = stay, orderId = "A-1", schedule = schedule.section("Bahnhof A", { wait = 500 }, "Bahnhof B"), wait = 500 })
    local tr = w.node.roles.station.tracks["gleis1"]
    t.eq(tr.p.release_set, true)
    local page = w.node.roles.station.pages[1]
    local view = { page_state = function() return { list = { index = 1 }, tracks = { tr } } end }
    local actions = page.actions(view)
    t.eq(actions[1].id, "freigabe_weg"); t.eq(actions[1].enabled, true)
    page.on_action(view, "act:freigabe_weg")          -- erster Druck: nur scharf
    t.eq(tr.p.release_set, true)
    page.on_action(view, "act:freigabe_weg")
    t.eq(tr.p.release_set, false)
    t.ok(schedule.same(st.train.schedule, schedule.waiting("Bahnhof A", 0)), "Warteauftrag steht wieder")
    t.eq(ask(h, z, "auftrag", { kind = "fahrplan", track = "gleis1", train = "GZ-1", orderId = "A-1" }).status, "uebergeben")
  end },
}
