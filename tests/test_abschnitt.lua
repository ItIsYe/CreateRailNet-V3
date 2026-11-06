--[[
Purpose: Abschnittsfahrplan der Freigabe per Fahrplan (docs/FREIGABE_PER_FAHRPLAN.md, Messwerte H1 bis H5 und M20): Eintrag 1 ist der eigene Bahnhof mit den Haltebedingungen (immer mindestens eine Wartezeit von 1 s, wie gemessen), Eintrag 2 der naechste Bahnhof mit create:powered als Halt. Pruefung, Restwartezeit und die Streckenkennung, mit der der Zielbahnhof den Zug wiedererkennt.
]]

local t = dofile("tests/lib/t.lua")
local schedule = require("domain.schedule")

local function has_text(list, part)
  for _, p in ipairs(list) do if p:find(part, 1, true) then return true end end
  return false
end

local SAMPLE = {
  item_threshold = {
    condition = { id = "create:item_threshold", data = { threshold = "0", operator = 0, item = { id = "minecraft:air" }, measure = 0 } },
    path = { "data", "threshold" },
  },
}

return {
  { "Abschnitt ohne Haltebedingung: Eintrag 1 wartet 1 s am eigenen Bahnhof, Eintrag 2 haelt mit create:powered", function()
    local s, err = schedule.section("Bahnhof A", { wait = 0 }, "Bahnhof B")
    t.ok(s, tostring(err))
    t.eq(s.cyclic, false)
    t.eq(#s.entries, 2)
    t.eq(s.entries[1].instruction.data.text, "Bahnhof A")
    t.eq(#s.entries[1].conditions, 1, "genau eine Gruppe")
    t.eq(#s.entries[1].conditions[1], 1)
    t.eq(s.entries[1].conditions[1][1].id, "create:delay")
    t.eq(s.entries[1].conditions[1][1].data.value, 1)
    t.eq(s.entries[1].conditions[1][1].data.time_unit, 1, "Sekunden")
    t.eq(s.entries[2].instruction.data.text, "Bahnhof B")
    t.eq(#s.entries[2].conditions, 1)
    t.eq(s.entries[2].conditions[1][#s.entries[2].conditions[1]].id, "create:powered")
    t.eq(#schedule.check_section(s), 0)
  end },
  { "Haltezeit wird uebernommen, kleiner als 1 s wird 1 s", function()
    local s = schedule.section("A", { wait = 30 }, "B")
    t.eq(s.entries[1].conditions[1][1].data.value, 30)
    local z = schedule.section("A", { wait = 0.4 }, "B")
    t.eq(z.entries[1].conditions[1][1].data.value, 1)
  end },
  { "Mengenbedingung folgt der Wartezeit in derselben Gruppe; ohne Muster Fehler", function()
    local s, err = schedule.section("A", { wait = 5, cargo = { count = 100 } }, "B", SAMPLE)
    t.ok(s, tostring(err))
    t.eq(#s.entries[1].conditions, 1)
    t.eq(s.entries[1].conditions[1][1].id, "create:delay")
    t.eq(s.entries[1].conditions[1][2].id, "create:item_threshold")
    t.eq(#schedule.check_section(s), 0)
    local none, why = schedule.section("A", { wait = 5, cargo = { count = 100 } }, "B", {})
    t.eq(none, nil)
    t.ok(why and why ~= "", "Grund genannt")
  end },
  { "Gleicher Bahnhof hintereinander ist unzulaessig (M20), auch im Aufbau", function()
    local s, err = schedule.section("A", { wait = 0 }, "A")
    t.eq(s, nil)
    t.contains(err, "A")
    local manual = schedule.section("A", { wait = 0 }, "B")
    manual.entries[2].instruction.data.text = "A"
    t.ok(has_text(schedule.check_section(manual), "nennen beide A"))
  end },
  { "check_section verlangt zwei Eintraege, eine Gruppe je Eintrag, Wartebedingung vorn und create:powered hinten", function()
    local base = schedule.section("A", { wait = 0 }, "B")
    local one = { cyclic = false, entries = { base.entries[1] } }
    t.ok(has_text(schedule.check_section(one), "zwei Eintraege"))
    local no_delay = schedule.section("A", { wait = 0 }, "B")
    no_delay.entries[1].conditions = { {} }
    t.ok(has_text(schedule.check_section(no_delay), "Eintrag 1"), "leere Gruppe unzulaessig (nicht gemessen)")
    local powered_front = schedule.section("A", { wait = 0 }, "B")
    table.insert(powered_front.entries[1].conditions[1], schedule.powered())
    t.ok(has_text(schedule.check_section(powered_front), "create:powered"), "vorn kein create:powered, sonst kein Abfahren")
    local no_hold = schedule.section("A", { wait = 0 }, "B")
    no_hold.entries[2].conditions = { { schedule.delay(1) } }
    t.ok(has_text(schedule.check_section(no_hold), "Eintrag 2"), "hinten muss create:powered halten")
    local two_groups = schedule.section("A", { wait = 0 }, "B")
    two_groups.entries[2].conditions[2] = { schedule.delay(1) }
    t.ok(has_text(schedule.check_section(two_groups), "genau eine"))
    local cyc = schedule.section("A", { wait = 0 }, "B")
    cyc.cyclic = true
    t.ok(has_text(schedule.check_section(cyc), "nicht umlaufend"))
  end },
  { "Restwartezeit ersetzt nur den Wert der ersten Wartebedingung und aendert das Original nicht", function()
    local s = schedule.section("A", { wait = 30, cargo = { count = 7 } }, "B", SAMPLE)
    local r = schedule.with_rest_wait(s, 12.6)
    t.eq(r.entries[1].conditions[1][1].data.value, 13, "aufgerundet auf volle Sekunden")
    t.eq(r.entries[1].conditions[1][2].id, "create:item_threshold")
    t.eq(s.entries[1].conditions[1][1].data.value, 30, "Original unveraendert")
    t.eq(schedule.with_rest_wait(s, 0).entries[1].conditions[1][1].data.value, 1, "mindestens 1 s")
    t.eq(schedule.with_rest_wait(s, -5).entries[1].conditions[1][1].data.value, 1)
    t.eq(schedule.with_rest_wait(s, 99).entries[1].conditions[1][1].data.value, 30, "nie laenger als die Soll-Haltezeit")
    t.eq(#schedule.check_section(r), 0)
  end },
  { "Streckenkennung: gleich bei anderer Restzeit, verschieden bei anderem Ziel oder Start oder Warteauftrag", function()
    local a = schedule.section("A", { wait = 30 }, "B")
    local b = schedule.with_rest_wait(a, 3)
    t.eq(schedule.route_hash(a), schedule.route_hash(b))
    t.ok(schedule.route_hash(a) ~= schedule.route_hash(schedule.section("A", { wait = 30 }, "C")))
    t.ok(schedule.route_hash(a) ~= schedule.route_hash(schedule.section("X", { wait = 30 }, "B")))
    t.ok(schedule.route_hash(a) ~= schedule.route_hash(schedule.waiting("B", 0)))
    t.eq(schedule.route_hash(nil), nil)
  end },
  { "Warteauftrag haelt den Zug: ein umlaufender Eintrag, letzte Bedingung create:powered", function()
    for _, wait in ipairs({ 0, 10 }) do
      local w = schedule.waiting("A", wait)
      t.eq(w.cyclic, true); t.eq(#w.entries, 1); t.eq(#w.entries[1].conditions, 1)
      local group = w.entries[1].conditions[1]
      t.eq(group[#group].id, "create:powered")
    end
  end },
}
