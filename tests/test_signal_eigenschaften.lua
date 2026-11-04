--[[
Purpose: Funktion, Wirkrichtung und Standort eines Signals (Konzept 5.4): Vorgabe aus der Gleisrichtung, bei "beide" muss die Wirkrichtung gewaehlt werden; Aenderung der Gleisrichtung bewertet neu; Anzeige in der Einrichtung und in der Leitstelle.
]]

local t = dofile("tests/lib/t.lua")
local H = dofile("tests/lib/harness.lua")
local cc = dofile("tests/fakes/cc.lua")
local create = dofile("tests/fakes/create.lua")
local wizardlib = require("setup.wizard")
local model = require("setup.model")
local detect = require("dev.detect")

local function wiz_with(tracks)
  local w = create.world()
  w.add_modem("left", true)
  for i = 1, 4 do w.add_signal("Create_Signal_" .. i) end
  local wiz = wizardlib.new({
    scan = function() return detect.scan(w.peripheral) end,
    env = { peripheral = w.peripheral, redstone = w.redstone },
    now = function() return 0 end,
  })
  wiz.set_network("Testnetz", "hauptstelle", nil)
  wiz.guided_begin({
    area = { id = "B0001", name = "West-Ost", ends = { "Westbahnhof", "Ostbahnhof" } },
    claim = "c1-123456789012",
    node = { id = "N0017", name = "Signal West-Ost N0017", label = "N0017 | SIG | B0001" },
    tracks = tracks,
  })
  return wiz
end

local TRACKS = {
  { id = "A0001", name = "Gleis 1", direction = "Ostbahnhof" },
  { id = "A0002", name = "Gleis 2", direction = "Westbahnhof" },
  { id = "A0003", name = "Gleis 3", direction = "beide" },
}


-- Oberflaeche: Bereich mit Gleisen "beide" (Wirkrichtung nicht ableitbar)
local function ui_setup(pattern)
  local h = H.new()
  local z = h.add_node({ id = "hauptstelle", roles = { "zentrale" }, tracks = {} })
  local netz = z.node.roles.zentrale.netz
  netz.add_area({ name = "West-Ost", ends = { "Westbahnhof", "Ostbahnhof" }, count = 2, pattern = pattern })
  local d = h.add_blank({ id = "neu" })
  d.world.add_signal("Create_Signal_1"); d.world.add_signal("Create_Signal_2")
  h.step(1)
  local v = d.view()
  v.set_page("einrichtung")
  d.tap(v, "act:start")
  d.tap(v, "sel:modus:2"); d.tap(v, "act:weiter")
  h.step(5); d.node.render()
  d.tap(v, "sel:netzwahl:1"); d.tap(v, "act:weiter")
  d.tap(v, "sel:rollen:5"); d.tap(v, "act:weiter")
  h.step(3); d.node.render()
  d.tap(v, "sel:bereich:1")
  h.step(3); d.node.render()
  d.tap(v, "act:weiter"); d.tap(v, "act:weiter")
  h.step(3); d.node.render()
  return h, z, d, v, netz
end

local function screen(d) return d.node.setup.session().screen end

local function row(wiz, name)
  for _, r in ipairs(wiz.guided_rows()) do if r.name == name then return r end end
end

return {
  { "Vorgabe: Streckensignal, Wirkrichtung und Standort = eindeutige Gleisrichtung; bei 'beide' offen", function()
    local wiz = wiz_with(TRACKS)
    for i, r in ipairs(wiz.guided_rows()) do assert(wiz.guided_assign(r.track, "Create_Signal_" .. i)) end
    local a, b, c = row(wiz, "Gleis 1").signals[1], row(wiz, "Gleis 2").signals[1], row(wiz, "Gleis 3").signals[1]
    t.eq(a.use, "strecke"); t.eq(a.effect, "Ostbahnhof"); t.eq(a.place, "Ostbahnhof")
    t.eq(b.effect, "Westbahnhof")
    t.eq(c.effect, nil, "bei 'beide' kann die Wirkrichtung nicht geraten werden")
    local problems = wiz.signal_problems()
    t.eq(#problems, 1); t.eq(problems[1].track_name, "Gleis 3"); t.eq(problems[1].device, "Create_Signal_3")
  end },
  { "Weiterschalten der Eigenschaften: Funktion, Wirkrichtung, Standort; falsche Eingaben werden abgelehnt", function()
    local wiz = wiz_with(TRACKS)
    assert(wiz.guided_assign(row(wiz, "Gleis 3").track, "Create_Signal_1"))
    local id = row(wiz, "Gleis 3").signals[1].id
    t.eq(wiz.area_ends()[1], "Westbahnhof")
    assert(wiz.signal_cycle(id, "effect"))
    t.eq(row(wiz, "Gleis 3").signals[1].effect, "Westbahnhof")
    t.eq(row(wiz, "Gleis 3").signals[1].place, "Westbahnhof", "der Standort folgt der ersten Wahl")
    assert(wiz.signal_cycle(id, "effect"))
    t.eq(row(wiz, "Gleis 3").signals[1].effect, "Ostbahnhof")
    assert(wiz.signal_cycle(id, "effect"))
    t.eq(row(wiz, "Gleis 3").signals[1].effect, "Westbahnhof", "es dreht sich im Kreis")
    assert(wiz.signal_cycle(id, "use")); t.eq(row(wiz, "Gleis 3").signals[1].use, "einfahrt")
    assert(wiz.signal_cycle(id, "use")); t.eq(row(wiz, "Gleis 3").signals[1].use, "ausfahrt")
    assert(wiz.signal_cycle(id, "use")); t.eq(row(wiz, "Gleis 3").signals[1].use, "strecke")
    assert(wiz.signal_cycle(id, "place")); t.eq(row(wiz, "Gleis 3").signals[1].place, "Ostbahnhof")
    assert(wiz.signal_cycle(id, "place")); t.eq(row(wiz, "Gleis 3").signals[1].place, "mitte")
    assert(wiz.signal_cycle(id, "place")); t.eq(row(wiz, "Gleis 3").signals[1].place, "Westbahnhof")
    local ok, why = wiz.signal_cycle(id, "unsinn")
    t.eq(ok, false); t.contains(why, "Unbekanntes Feld")
    ok, why = wiz.signal_cycle("gibt-es-nicht", "use")
    t.eq(ok, false); t.contains(why, "gibt es nicht")
    t.eq(#wiz.signal_problems(), 0)
  end },
  { "Ohne Wirkrichtung gibt es keine Aktivierung: die Pruefung der Pflichtangaben nennt das Signal", function()
    local wiz = wiz_with(TRACKS)
    for i, r in ipairs(wiz.guided_rows()) do assert(wiz.guided_assign(r.track, "Create_Signal_" .. i)) end
    local found
    for _, p in ipairs(model.validate(wiz.config, wiz.scan)) do if p.code == "signal_wirkrichtung" then found = p end end
    t.ok(found, "Pflichtangabe fehlt")
    t.contains(found.text, "Create_Signal_3"); t.contains(found.text, "Gleis 3")
    assert(wiz.signal_cycle(row(wiz, "Gleis 3").signals[1].id, "effect"))
    for _, p in ipairs(model.validate(wiz.config, wiz.scan)) do t.ok(p.code ~= "signal_wirkrichtung", p.text) end
  end },
  { "Aeltere Signale ohne Eigenschaften (Handeinrichtung) werden nicht beanstandet", function()
    local config = model.new("Netz", {}, {})
    config.node.roles = { "signal" }
    local tid = model.add_track(config, "Gleis 1")
    config.tracks[tid].direction = "hin"
    local did = model.add_device(config, "signal", "Create_Signal_1")
    model.assign(config, tid, "signals", did)
    for _, p in ipairs(model.validate(config, {})) do t.ok(p.code ~= "signal_wirkrichtung", p.text) end
  end },
  { "Gleisrichtung geaendert: eindeutige Richtung wird uebernommen, 'beide' behaelt nur Gueltiges, das Ergebnis meldet die betroffenen Signale", function()
    local wiz = wiz_with(TRACKS)
    for i, r in ipairs(wiz.guided_rows()) do assert(wiz.guided_assign(r.track, "Create_Signal_" .. i)) end
    local g1 = row(wiz, "Gleis 1")
    wiz.config.tracks[g1.track].dir.direction = "Westbahnhof"
    wiz.config.tests = { vorhanden = true }
    t.eq(wiz.guided_direction_changed(g1.track), 1)
    t.eq(next(wiz.config.tests), nil, "Richtung geaendert: fruehere Pruefergebnisse gelten nicht mehr")
    t.eq(row(wiz, "Gleis 1").signals[1].effect, "Westbahnhof"); t.eq(row(wiz, "Gleis 1").signals[1].place, "Westbahnhof")
    wiz.config.tests = { vorhanden = true }
    t.eq(wiz.guided_direction_changed(g1.track), 0, "nichts mehr zu tun")
    t.ok(wiz.config.tests.vorhanden, "ohne Aenderung bleiben die Ergebnisse")
    -- auf 'beide': die vorhandene gueltige Wirkrichtung bleibt, die Pruefung bleibt gueltig
    wiz.config.tracks[g1.track].dir.direction = "beide"
    t.eq(wiz.guided_direction_changed(g1.track), 0)
    t.eq(row(wiz, "Gleis 1").signals[1].effect, "Westbahnhof")
    -- eine Wirkrichtung, die kein Anschluss des Bereichs mehr ist, wird offen
    wiz.config.devices[g1.signals[1].id].signal.effect = "Nordbahnhof"
    t.eq(wiz.guided_direction_changed(g1.track), 1)
    t.eq(row(wiz, "Gleis 1").signals[1].effect, nil)
  end },
  { "Aeltere Entwuerfe ohne gespeicherte Anschlussnamen: die Namen kommen aus den Gleisrichtungen", function()
    local wiz = wiz_with(TRACKS)
    wiz.config.node.area_ends = nil
    local ends = wiz.area_ends()
    t.eq(#ends, 2); t.eq(ends[1], "Ostbahnhof"); t.eq(ends[2], "Westbahnhof")
  end },
  { "Oberflaeche: bei Gleisen 'beide' bleibt Weiter gesperrt, bis die Wirkrichtung im Detailbildschirm gewaehlt ist", function()
    local h, z, d, v = ui_setup("beide")
    t.eq(screen(d), "4.zuordnung", d.text(v))
    for _ = 1, 2 do d.tap(v, "act:signal_waehlen"); d.tap(v, "sel:signal:1") end
    t.contains(d.text(v), "Richtu")
    d.tap(v, "act:weiter")
    t.contains(d.text(v), "Wirkrichtung fehlt")
    t.eq(screen(d), "4.zuordnung")
    -- Detailbildschirm des ersten Gleises
    d.tap(v, "sel:zuordnung:1")
    d.tap(v, "act:signal_details")
    t.eq(screen(d), "4.z.detail", d.text(v))
    t.contains(d.text(v), "WIRKRICHTUNG FEHLT")
    d.tap(v, "act:d_richtung")
    t.contains(d.text(v), "Richtung West")
    d.tap(v, "act:d_funktion")
    t.eq(d.node.setup.session().wiz.guided_rows()[1].signals[1].use, "einfahrt")
    d.tap(v, "act:d_standort")
    t.eq(d.node.setup.session().wiz.guided_rows()[1].signals[1].place, "Ostbahnhof", "Standort folgte der gewaehlten Richtung (West) und wurde einmal weitergeschaltet")
    d.tap(v, "act:zurueck")
    t.eq(screen(d), "4.zuordnung", d.text(v))
    d.tap(v, "sel:zuordnung:2")
    d.tap(v, "act:signal_details")
    d.tap(v, "act:d_richtung"); d.tap(v, "act:d_richtung")
    d.tap(v, "act:zurueck")
    d.tap(v, "act:weiter")
    t.eq(screen(d), "5.pruefen", d.text(v))
  end },
  { "Oberflaeche: bei eindeutigen Gleisrichtungen ist nichts zusaetzlich zu tun", function()
    local h, z, d, v = ui_setup("gegenlaeufig")
    for _ = 1, 2 do d.tap(v, "act:signal_waehlen"); d.tap(v, "sel:signal:1") end
    t.ok(not d.has(v, "Richtung?"), d.text(v))
    d.tap(v, "act:weiter")
    t.eq(screen(d), "5.pruefen", d.text(v))
  end },
  { "Leitstelle zeigt Funktion und Wirkrichtung der aktiven Signal-Node", function()
    local h = H.new()
    local z = h.add_node({ id = "hauptstelle", roles = { "zentrale" }, tracks = {} })
    h.add_node({ id = "strecke", roles = { "signal" }, central = "hauptstelle", tracks = { { name = "Gleis 1", signals = { "Sig_N" }, signal_info = { use = "einfahrt", effect = "Ostbahnhof", place = "Ostbahnhof" } } } })
    h.step(40)
    local rows = z.node.roles.zentrale.signal_overview()
    t.ok(#rows >= 1, "Signalzeile")
    t.eq(rows[1].use, "einfahrt"); t.eq(rows[1].effect, "Ostbahnhof")
    local v = H.open_page(z, "signale")
    t.contains(z.text(v), "Knoteneinfahrt")
  end },
}
