--[[
Purpose: Betreiberbeobachtung (docs/MESSWERTE.md M20): Create schickt einen Zug, der an Bahnhof 10 steht, nicht direkt wieder zu Bahnhof 10; er muss erst zu einem anderen Bahnhof (11) und kann von dort wieder nach 10. Die Regel gilt in der Fahrplanpruefung (zwei aufeinanderfolgende Eintraege mit demselben Bahnhof), beim Anlegen von Vorlagen (auch mit der Rueckfahrt zum Start), bei der Gleiswahl (ein Gleis, auf dem der Zug schon steht, wird nicht als naechstes Ziel gewaehlt) und beim Abstellen am selben Bahnhof.
]]

local t = dofile("tests/lib/t.lua")
local H = dofile("tests/lib/harness.lua")
local schedule = require("domain.schedule")

-- Meldungen wie die Fahrplanpruefung der Vorlagen: "Eintrag i und j" fuer das erste Paar gleicher Bahnhoefe hintereinander
local function problems_of(names, cyclic)
  local i, j = schedule.first_repeat(names, cyclic)
  if not i then return {} end
  return { "Eintrag " .. i .. " und " .. j .. " nennen beide " .. names[i] }
end

local function has_text(list, part)
  for _, p in ipairs(list) do if p:find(part, 1, true) then return true end end
  return false
end

local function build()
  local h = H.new()
  local z = h.add_node({ id = "hauptstelle", roles = { "zentrale" }, tracks = {} })
  local w = h.add_node({
    id = "weizenhof", roles = { "bahnhof", "anmeldung" }, central = "hauptstelle", registration = "Gleis 1",
    tracks = { { name = "Gleis 1", station_name = "Weizenhof", known = { ["Depot Gleis 1"] = 100, Weizenhof = 0 } } },
  })
  local d = h.add_node({
    id = "depot1", roles = { "bahnhof" }, central = "hauptstelle",
    tracks = { { name = "Abstell 1", station_name = "Depot Gleis 1", known = { Weizenhof = 100, ["Depot Gleis 1"] = 0 } } },
  })
  local sim = h.sim({ { node = "weizenhof", name = "Weizenhof" }, { node = "depot1", name = "Depot Gleis 1" } }, 12)
  sim.add_train("Unnamed Train", "Weizenhof", nil, 0)
  h.step(20)
  w.node.roles.anmeldung.submit_registration({ id = "GZ-001", create_name = "GZ-001", display_name = "Weizenpendel", usage = "fracht", mode = "bedarf", length = 4 })
  t.ok(h.until_true(function() local tr = z.node.roles.zentrale.register.get("GZ-001") return tr and tr.state == "gesteuert" end, 60))
  h.step(8)
  return h, z.node.roles.zentrale
end

return {
  { "Fahrplanpruefung: zwei gleiche Bahnhoefe hintereinander sind ein Fehler, A-B-A ist erlaubt", function()
    t.eq(#problems_of({ "A", "B", "A" }), 0, "10 -> 11 -> 10 geht")
    local p = problems_of({ "A", "A", "B" })
    t.ok(has_text(p, "Eintrag 1 und 2"), "zwei gleiche Eintraege am Anfang: " .. table.concat(p, " | "))
    t.ok(has_text(p, "A"), "nennt den Bahnhof")
    t.ok(has_text(problems_of({ "A", "B", "B" }), "Eintrag 2 und 3"))
    t.ok(has_text(problems_of({ "A", "B", "A", "A" }), "Eintrag 3 und 4"), "auch die Rueckfahrt zum Start")
  end },
  { "Fahrplanpruefung: ein umlaufender Fahrplan darf auch nicht mit demselben Bahnhof enden und beginnen", function()
    t.ok(has_text(problems_of({ "A", "B", "A" }, true), "Eintrag 3 und 1"), "A am Ende, A am Anfang")
    t.eq(#problems_of({ "A", "B", "C" }, true), 0)
  end },
  { "Vorlage: ein einziger Halt mit Rueckfahrt zum Start waere A, A und wird abgelehnt", function()
    local h, z = build()
    local ok, err = z.create_template({ id = "nur-eins", title = "Nur eins", train = "GZ-001", stops = "Weizenhof" })
    t.ok(not ok, "abgelehnt")
    t.contains(err, "Weizenhof zweimal hintereinander")
    t.contains(err, "Rueckfahrt")
  end },
  { "Vorlage: gleiche Halte hintereinander werden abgelehnt, mit dazwischenliegendem Bahnhof geht es", function()
    local h, z = build()
    local ok, err = z.create_template({ id = "doppelt", title = "Doppelt", train = "GZ-001", stops = "Weizenhof;Weizenhof;Depot Gleis 1" })
    t.ok(not ok)
    t.contains(err, "Weizenhof zweimal hintereinander (Halt 1, 2)")
    local ok2, err2 = z.create_template({ id = "hinten", title = "Hinten", train = "GZ-001", stops = "Weizenhof;Depot Gleis 1;Depot Gleis 1" })
    t.ok(not ok2)
    t.contains(err2, "Depot Gleis 1 zweimal hintereinander (Halt 2, 3)")
    local ok3, err3 = z.create_template({ id = "gut", title = "Gut", train = "GZ-001", stops = "Weizenhof;Depot Gleis 1" })
    t.ok(ok3, tostring(err3))
  end },
  { "Vorlage: endet die Liste mit dem Startbahnhof, folgt die Rueckfahrt zum Start direkt darauf", function()
    local h, z = build()
    local ok, err = z.create_template({ id = "ende", title = "Ende", train = "GZ-001", stops = "Weizenhof;Depot Gleis 1;Weizenhof" })
    t.ok(not ok)
    t.contains(err, "Weizenhof zweimal hintereinander (Halt 3, Rueckfahrt)")
  end },
  { "Abstellen am Bahnhof, an dem der Zug steht: abgelehnt mit klarem Grund, kein Auftrag", function()
    local h, z = build()
    local order, why = z.park("GZ-001", "Weizenhof")
    t.ok(not order)
    t.contains(why, "Der Zug steht schon an Weizenhof")
    t.eq(#z.orders.active(), 0, "kein Auftrag angelegt")
  end },
  { "Zielwahl: ein Gleis der Gruppe, auf dem der Zug schon steht, wird nicht als naechstes Ziel gewaehlt", function()
    local h, z = build()
    -- Gruppe "Hof": Weizenhof zuerst, dann das Depotgleis; der Zug steht an Weizenhof
    local ok_g, err_g = z.stations.set("Hof", { "Weizenhof", "Depot Gleis 1" })
    t.ok(ok_g, tostring(err_g))
    local ok, err = z.create_template({ id = "hof", title = "Hof", train = "GZ-001", stops = "Weizenhof;Hof" })
    t.ok(ok, tostring(err))
    local order = z.demand("hof")
    t.ok(order, "Auftrag angelegt")
    t.ok(h.until_true(function() return order.plan ~= nil end, 60), "Plan entstanden: " .. tostring(order.state) .. " " .. tostring(order.reason))
    t.eq(order.plan[1].station, "Weizenhof")
    t.eq(order.plan[2].station, "Depot Gleis 1", "nicht wieder Weizenhof, sondern das andere Gleis der Gruppe")
    local section = schedule.section(order.plan[1].station, { wait = 0 }, order.plan[2].station)
    t.ok(section, "Abschnitt der ersten Etappe laesst sich bauen")
    t.eq(#schedule.check_section(section), 0)
  end },
}
