--[[
Purpose: Gleisseite der Bahnhofs-Rolle einzeln gegen eine Test-Leitstelle: Voraussetzungen jeder Aufgabe (richtiger Zug, kein blindes Ueberschreiben, Aufenthaltsbindung, Mindestaufenthalt, bestaetigter Ausgang), Berichte bei unplanmaessiger Abfahrt und verschwundenem Zug.
]]

local t = dofile("tests/lib/t.lua")
local H = dofile("tests/lib/harness.lua")
local schedule = require("domain.schedule")

local function build()
  local h = H.new()
  local z = h.add_node({ id = "hauptstelle", roles = { "zentrale" }, tracks = {} })
  local w = h.add_node({
    id = "bf", roles = { "gueterbahnhof" }, central = "hauptstelle",
    tracks = { { name = "Gleis 1", station_name = "Bahnhof A", release_side = "back", known = { ["Bahnhof B"] = 10, ["Bahnhof A"] = 0 } } },
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
    t.ok(not a.output)
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
    t.eq(w.world.sides.back, false)
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
  { "Fahrplan: nur aus dem bekannten Warteauftrag, nie blind", function()
    local h, z, w = with_train("GZ-1")
    local st = w.world.devices["Create_Station_1"].state
    local order = schedule.order({ { station = "Bahnhof A", wait = 0 }, { station = "Bahnhof B", wait = 0 } }, {})
    st.train.schedule = schedule.waiting("Bahnhof A", 77)      -- kein bekannter Zustand
    local a = ask(h, z, "auftrag", { kind = "fahrplan", track = "gleis1", train = "GZ-1", orderId = "A-1", schedule = order })
    t.eq(a.status, "abgelehnt"); t.eq(a.klaerung, true)
    t.eq(st.train.schedule.entries[1].conditions[1][1].data.value, 77)
    -- nach dem Warteauftrag ist die Ausgangslage bekannt
    t.eq(ask(h, z, "auftrag", { kind = "warteauftrag", track = "gleis1", train = "GZ-1", wait = 0, handover = true }).status, "uebergeben")
    local b = ask(h, z, "auftrag", { kind = "fahrplan", track = "gleis1", train = "GZ-1", orderId = "A-1", schedule = order })
    t.eq(b.status, "uebergeben")
    -- Wiederholung desselben Fahrplans ist unschaedlich
    t.eq(ask(h, z, "auftrag", { kind = "fahrplan", track = "gleis1", train = "GZ-1", orderId = "A-1", schedule = order }).status, "uebergeben")
  end },
  { "Fahrplan: unzulaessiger Inhalt wird abgelehnt", function()
    local h, z, w = with_train("GZ-1")
    ask(h, z, "auftrag", { kind = "warteauftrag", track = "gleis1", train = "GZ-1", wait = 0, handover = true })
    local sets = w.world.devices["Create_Station_1"].state.sets or 0
    local bad = { cyclic = false, entries = { { instruction = { id = "create:destination", data = { text = "Bahnhof B" } }, conditions = {} } } }
    local a = ask(h, z, "auftrag", { kind = "fahrplan", track = "gleis1", train = "GZ-1", orderId = "A-1", schedule = bad })
    t.eq(a.status, "abgelehnt"); t.contains(a.grund, "unzulaessig")
    t.eq(w.world.devices["Create_Station_1"].state.sets or 0, sets)
  end },
  { "Freigabe: Aufenthaltsbindung, Mindestaufenthalt und Wiederholung", function()
    local h, z, w = with_train("GZ-1")
    local stay = stay_of(w)
    local old = ask(h, z, "auftrag", { kind = "freigabe", track = "gleis1", train = "GZ-1", stay = stay - 1, orderId = "A-1" })
    t.eq(old.status, "abgelehnt"); t.contains(old.grund, "anderer Aufenthalt")
    t.eq(w.world.sides.back, false)
    local early = ask(h, z, "auftrag", { kind = "freigabe", track = "gleis1", train = "GZ-1", stay = stay, orderId = "A-1", min_stay = 500 })
    t.eq(early.status, "zurueckgestellt"); t.ok(early.retry_in > 0)
    t.eq(w.world.sides.back, false)
    local ok = ask(h, z, "auftrag", { kind = "freigabe", track = "gleis1", train = "GZ-1", stay = stay, orderId = "A-1" })
    t.eq(ok.status, "freigabe_gesetzt"); t.eq(ok.abfahrt_bestaetigt, false)
    t.eq(w.world.sides.back, true)
    local again = ask(h, z, "auftrag", { kind = "freigabe", track = "gleis1", train = "GZ-1", stay = stay, orderId = "A-1" })
    t.eq(again.status, "freigabe_gesetzt"); t.eq(again.hinweis, "schon gesetzt")
  end },
  { "Freigabe: der gesetzte Ausgang gilt nur fuer Zug und Aufenthalt der Freigabe", function()
    local h, z, w = with_train("GZ-1")
    local stay = stay_of(w)
    ask(h, z, "auftrag", { kind = "freigabe", track = "gleis1", train = "GZ-1", stay = stay, orderId = "A-1" })
    local other = ask(h, z, "auftrag", { kind = "freigabe", track = "gleis1", train = "GZ-2", stay = stay, orderId = "A-2" })
    t.eq(other.status, "abgelehnt", "ein anderer Zug bekommt keine 'schon gesetzt'-Antwort")
    local other_stay = ask(h, z, "auftrag", { kind = "freigabe", track = "gleis1", train = "GZ-1", stay = stay + 1, orderId = "A-2" })
    t.eq(other_stay.status, "abgelehnt")
  end },
  { "Freigabe: Ausgang reagiert nicht oder war schon aus anderem Grund an", function()
    local h, z, w = with_train("GZ-1")
    local stay = stay_of(w)
    w.world.stuck = { back = true }
    local a = ask(h, z, "auftrag", { kind = "freigabe", track = "gleis1", train = "GZ-1", stay = stay, orderId = "A-1" })
    t.eq(a.status, "abgelehnt"); t.contains(a.grund, "nicht bestaetigt")
    t.eq(w.node.roles.station.tracks["gleis1"].p.release_set, false, "ohne Bestaetigung kein Sollzustand")
    w.world.stuck = nil
    w.world.sides.back = true        -- fremd eingeschaltet
    local b = ask(h, z, "auftrag", { kind = "freigabe", track = "gleis1", train = "GZ-1", stay = stay, orderId = "A-1" })
    t.eq(b.status, "abgelehnt"); t.contains(b.grund, "anderem Grund")
    local c = ask(h, z, "auftrag", { kind = "warteauftrag", track = "gleis1", train = "GZ-1", wait = 0, handover = true })
    t.eq(c.status, "abgelehnt"); t.contains(c.grund, "Freigabeausgang")
    t.eq(w.world.devices["Create_Station_1"].state.sets or 0, 0)
  end },
  { "Abfahrt ohne Freigabe wird als unplanmaessig gemeldet, mit Freigabe nicht; der Ausgang geht zurueck", function()
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
    ask(h, z, "auftrag", { kind = "freigabe", track = "gleis1", train = "GZ-1", stay = stay, orderId = "A-1" })
    t.eq(w.world.sides.back, true)
    seen = collect(z)
    w.world.depart("Create_Station_1")
    h.step(3)
    for _, p in ipairs(seen) do if p.kind == "abfahrt" then dep = p end end
    t.eq(dep.released, true); t.eq(dep.unplanned, nil)
    t.eq(w.world.sides.back, false)
  end },
  { "Zug verschwindet ohne Ereignis: 'zug_weg' wird gemeldet und der Ausgang zurueckgenommen", function()
    local h, z, w = with_train("GZ-1")
    local stay = stay_of(w)
    ask(h, z, "auftrag", { kind = "freigabe", track = "gleis1", train = "GZ-1", stay = stay, orderId = "A-1" })
    local seen = collect(z)
    w.world.devices["Create_Station_1"].state.train = nil
    h.step(4)
    local gone
    for _, p in ipairs(seen) do if p.kind == "zug_weg" then gone = p end end
    t.ok(gone); t.eq(gone.train, "GZ-1")
    t.eq(w.world.sides.back, false)
  end },
}
