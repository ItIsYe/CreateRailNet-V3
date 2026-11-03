--[[
Purpose: Einfahrtsignal im Knoten: bei mehreren Signalen auf einem Einfahrtsgleis sperrt und gibt die Knoten-Node nur das als Einfahrt markierte (letzte vor dem Knoten) Signal; die uebrigen regelt Create allein. Pflichtangaben im Modell, Markieren im Assistenten, vorsichtiger Rueckfall bei aelteren Einrichtungen.
]]

local t = dofile("tests/lib/t.lua")
local H = dofile("tests/lib/harness.lua")
local model = require("setup.model")

local function dev(k, name) return k.world.devices[name].state end
local function forced(k, name) return dev(k, name).forced end
local function front(k, obs, train)
  dev(k, obs).passing = train
  k.world.queue[#k.world.queue + 1] = { "train_passing", obs, train }
end
local function tail(k, obs, train)
  dev(k, obs).passing = nil
  k.world.queue[#k.world.queue + 1] = { "train_passed", obs, train }
end

-- Zwei Anschluesse: West (Einfahrt mit mehreren Signalen) und Ost (Ausfahrt)
local function build(west_signals, infos)
  local h = H.new()
  local z = h.add_node({ id = "hauptstelle", roles = { "zentrale" }, tracks = {} })
  local k = h.add_node({
    id = "tee", roles = { "knoten" }, central = "hauptstelle",
    junction = { connections = { West = true, Ost = true }, moves = { { from = "West", to = "Ost" } }, conflicts = {} },
    tracks = {
      { name = "West ein", signals = west_signals, signal_infos = infos or {}, observers = { "Obs_West" }, junction = { connection = "West", role = "ein" } },
      { name = "Ost aus", observers = { "Obs_Ost" }, junction = { connection = "Ost", role = "aus" } },
    },
  })
  h.step(15)
  return h, z, k
end

local function codes(config)
  local out = {}
  for _, p in ipairs(model.validate(config, {})) do out[p.code] = (out[p.code] or 0) + 1 end
  return out
end

-- Modell mit einem Einfahrtsgleis und n Signalen, davon markiert nach marks (Liste der Nummern)
local function model_with(n, marks, role)
  local c = model.new("k", { "knoten" }, { name = "Netz", central_id = "z" })
  c.junction = { connections = { West = true, Ost = true }, moves = { { from = "West", to = "Ost" } }, conflicts = {} }
  local tid = model.add_track(c, "West ein")
  c.tracks[tid].junction = { connection = "West", role = role or "ein" }
  c.tracks[tid].dir = { id = "A0001", junction = "K0001" }
  c.tracks[tid].order_ok = true
  local obs = model.add_device(c, "observer", "Obs"); model.assign(c, tid, "observers", obs)
  local ids = {}
  for i = 1, n do
    ids[i] = model.add_device(c, "signal", "Sig_" .. i)
    model.assign(c, tid, "signals", ids[i])
    c.tracks[tid].order_ok = true
  end
  for _, i in ipairs(marks) do c.devices[ids[i]].signal = { use = "einfahrt" } end
  return c, tid, ids
end

return {
  { "Modell: bei mehreren Signalen am Einfahrtsgleis muss genau eines als Einfahrt markiert und das letzte vor dem Knoten sein", function()
    local c = model_with(3, {})
    t.eq(codes(c).knoten_einfahrtsignal, 1, "keines markiert")
    c = model_with(3, { 1, 3 })
    t.eq(codes(c).knoten_einfahrtsignal, 1, "zwei markiert")
    c = model_with(3, { 1 })
    t.eq(codes(c).knoten_einfahrtsignal, nil); t.eq(codes(c).knoten_einfahrtlage, 1, "das erste statt des letzten")
    c = model_with(3, { 2 })
    t.eq(codes(c).knoten_einfahrtlage, 1, "das mittlere")
    c = model_with(3, { 3 })
    t.eq(codes(c).knoten_einfahrtsignal, nil); t.eq(codes(c).knoten_einfahrtlage, nil)
    t.eq(codes(c).signal_wirkrichtung, nil, "an Knotengleisen entfaellt die Wirkrichtung")
    -- die Texte nennen das Gleis
    local found
    for _, p in ipairs(model.validate(model_with(2, {}), {})) do if p.code == "knoten_einfahrtsignal" then found = p.text end end
    t.contains(found, "West ein"); t.contains(found, "2 Signale")
    -- ein einziges Signal braucht keine Markierung
    c = model_with(1, {})
    t.eq(codes(c).knoten_einfahrtsignal, nil); t.eq(codes(c).knoten_einfahrtlage, nil)
    -- an einer Ausfahrt gibt es die Regel nicht
    c = model_with(3, {}, "aus")
    t.eq(codes(c).knoten_einfahrtsignal, nil)
    -- die Reihenfolge bleibt Pflicht
    c = model_with(2, { 2 })
    c.tracks[next(c.tracks)].order_ok = nil
    t.eq(codes(c).signal_reihenfolge, 1)
  end },
  { "Steuerung: nur das markierte Einfahrtsignal wird gesperrt und freigegeben, die uebrigen bleiben unberuehrt", function()
    local h, z, k = build({ "Sig_W1", "Sig_W2", "Sig_W3" }, { Sig_W3 = { use = "einfahrt" } })
    t.eq(forced(k, "Sig_W3"), true, "Einfahrtsignal ist gesperrt")
    t.eq(forced(k, "Sig_W1"), false, "Streckensignal bleibt frei")
    t.eq(forced(k, "Sig_W2"), false, "Streckensignal bleibt frei")
    -- ein Zug kuendigt sich an: das Einfahrtsignal wird freigegeben, die anderen werden nicht angefasst
    front(k, "Obs_West", "Zug A")
    h.step(4)
    t.eq(forced(k, "Sig_W3"), false, "Einfahrt freigegeben")
    t.eq(forced(k, "Sig_W1"), false); t.eq(forced(k, "Sig_W2"), false)
    -- Zug faehrt ein: Einfahrt wieder gesperrt
    tail(k, "Obs_West", "Zug A")
    h.step(4)
    t.eq(forced(k, "Sig_W3"), true, "nach der Einfahrt wieder gesperrt")
    t.eq(forced(k, "Sig_W1"), false); t.eq(forced(k, "Sig_W2"), false)
    -- keine fremden Sperren an den Streckensignalen: die Signal-Node hat dort keine Besitzer
    for _, view in ipairs(k.node.roles.signal.states()) do
      if view.id ~= nil and (view.forced == true) then
        local sg = k.node.roles.signal.signals[view.id]
        t.eq(sg.device, "Sig_W3", "nur das Einfahrtsignal ist gesperrt")
      end
    end
  end },
  { "Rueckfall: ohne Markierung (aeltere Einrichtung) oder mit mehreren Markierungen bleiben alle Signale des Gleises gesperrt", function()
    local h, z, k = build({ "Sig_W1", "Sig_W2" }, {})
    t.eq(forced(k, "Sig_W1"), true); t.eq(forced(k, "Sig_W2"), true)
    front(k, "Obs_West", "Zug A")
    h.step(4)
    t.eq(forced(k, "Sig_W1"), false); t.eq(forced(k, "Sig_W2"), false, "beide gemeinsam freigegeben")
    local h2, z2, k2 = build({ "Sig_W1", "Sig_W2" }, { Sig_W1 = { use = "einfahrt" }, Sig_W2 = { use = "einfahrt" } })
    t.eq(forced(k2, "Sig_W1"), true); t.eq(forced(k2, "Sig_W2"), true, "zwei Markierungen: vorsichtig alle")
  end },
  { "Ein einziges Signal am Einfahrtsgleis sperrt die Einfahrt wie bisher, markiert oder nicht", function()
    local h, z, k = build({ "Sig_W1" }, {})
    t.eq(forced(k, "Sig_W1"), true)
    local h2, z2, k2 = build({ "Sig_W1" }, { Sig_W1 = { use = "strecke" } })
    t.eq(forced(k2, "Sig_W1"), true, "auch ein als Strecke markiertes einziges Signal ist die Einfahrt")
  end },
  { "Assistent: Einfahrt markieren setzt genau ein Signal als Einfahrt und die anderen als Strecke; kein Einfahrtsgleis wird abgelehnt", function()
    local wizardlib = require("setup.wizard")
    local create = dofile("tests/fakes/create.lua")
    local detect = require("dev.detect")
    local c, tid, ids = model_with(3, { 1, 2 })
    local world = create.world()
    local wiz = wizardlib.new({
      scan = function() return detect.scan(world.peripheral) end,
      env = { peripheral = world.peripheral, redstone = world.redstone },
      now = function() return 0 end,
    })
    wiz.config = c
    local ok, why = wiz.guided_einfahrt_mark(ids[3])
    t.eq(ok, true, tostring(why))
    t.eq(c.devices[ids[1]].signal.use, "strecke"); t.eq(c.devices[ids[2]].signal.use, "strecke"); t.eq(c.devices[ids[3]].signal.use, "einfahrt")
    t.eq(codes(c).knoten_einfahrtsignal, nil); t.eq(codes(c).knoten_einfahrtlage, nil)
    -- erneut an anderer Stelle: wandert
    assert(wiz.guided_einfahrt_mark(ids[1]))
    t.eq(c.devices[ids[1]].signal.use, "einfahrt"); t.eq(c.devices[ids[3]].signal.use, "strecke")
    t.eq(codes(c).knoten_einfahrtlage, 1)
    -- Ausfahrtsgleis
    local c2, tid2, ids2 = model_with(2, {}, "aus")
    wiz.config = c2
    local ok2, why2 = wiz.guided_einfahrt_mark(ids2[1])
    t.eq(ok2, false); t.contains(why2, "kein Einfahrtsgleis")
    local ok3, why3 = wiz.guided_einfahrt_mark("gibtsnicht")
    t.eq(ok3, false); t.contains(why3, "keinem Gleis")
  end },
  { "Oberflaeche: drei Signale am Einfahrtsgleis fuehren zum Detailbildschirm; Einfahrt und Reihenfolge sind Pflicht, danach sperrt nur das Einfahrtsignal", function()
    local h = H.new()
    local z = h.add_node({ id = "hauptstelle", roles = { "zentrale" }, tracks = {} })
    local netz = z.node.roles.zentrale.netz
    netz.add_area({ name = "Kreuzung", ends = { "Nord", "Sued" }, count = 4 })
    local kid = assert(netz.add_junction({ name = "Hauptknoten" }))
    assert(netz.add_connection(kid, "West", { "A0001", "A0002" })); assert(netz.add_connection(kid, "Ost", { "A0003", "A0004" }))
    assert(netz.add_route(kid, "A0001", "A0003", true)); assert(netz.add_route(kid, "A0004", "A0002", true))
    assert(netz.add_conflict(kid, "F0001", "F0002", true))
    local d = h.add_blank({ id = "neu" })
    for i = 1, 4 do d.world.add_signal("Create_Signal_" .. i) end
    for i = 1, 4 do d.world.add_observer("Create_TrainObserver_" .. i) end
    h.step(1)
    local v = d.view()
    v.set_page("einrichtung")
    local function screen() return d.node.setup.session().screen end
    d.tap(v, "act:start")
    d.tap(v, "sel:modus:2"); d.tap(v, "act:weiter")
    h.step(5); d.node.render()
    d.tap(v, "sel:netzwahl:1"); d.tap(v, "act:weiter")
    d.tap_row(v, "rollen", "Knotenpunkt"); d.tap(v, "act:weiter")
    h.step(3); d.node.render()
    d.tap(v, "sel:knoten_wahl:1")
    h.step(5); d.node.render()
    d.tap(v, "act:weiter"); d.tap(v, "act:weiter")
    h.step(3); d.node.render()
    t.eq(screen(), "3.geraete", d.text(v))
    -- die Geraeteliste hat zwei Seiten: erst die sechs der ersten Seite, dann die der zweiten
    for _, name in ipairs({ "Create_Signal_1", "Create_Signal_2", "Create_Signal_3", "Create_Signal_4", "Create_TrainObserver_1", "Create_TrainObserver_2" }) do
      d.tap_row(v, "geraete", name)
    end
    d.tap(v, "page:geraete:next")
    d.node.render()
    d.tap_row(v, "geraete", "Create_TrainObserver_3"); d.tap_row(v, "geraete", "Create_TrainObserver_4")
    d.tap(v, "act:weiter")
    t.eq(screen(), "4.gleise", d.text(v))
    local wiz = d.node.setup.session().wiz
    local order = wiz.tracks()
    local observer_no, signal4_done = 0, false
    local function by_dir(id)
      for tid, tr in pairs(wiz.config.tracks) do if tr.dir and tr.dir.id == id then return tid, tr end end
    end
    local west_tid, west = by_dir("A0001")
    for i, tid in ipairs(order) do
      d.tap(v, "sel:gleise:" .. i); d.tap(v, "act:bearbeiten")
      local track = wiz.config.tracks[tid]
      if track.junction.role == "ein" then
        t.eq(screen(), "4.g.signale", d.text(v))
        if tid == west_tid then
          d.tap_row(v, "signale", "Create_Signal_1"); d.tap_row(v, "signale", "Create_Signal_2"); d.tap_row(v, "signale", "Create_Signal_3")
          d.tap(v, "act:weiter")
          -- mehrere Signale: der Detailbildschirm fuehrt durch Reihenfolge und Einfahrt
          t.eq(screen(), "4.z.detail", d.text(v))
          t.contains(d.text(v), "Reihenfolge zum Knoten (zuletzt: Einfahrt) offen")
          t.contains(d.text(v), "1. Create_Signal_1")
          t.contains(d.text(v), "Streckensignal")
          t.ok(d.has(v, "Einfahrt"), d.text(v))
          t.ok(not d.has(v, "Funktion"), "keine Funktion/Richtung/Standort an Knotengleisen: " .. d.text(v))
          -- richtig markiert, aber die Reihenfolge ist noch nicht bestaetigt: der Assistent bleibt beim Detailbildschirm
          d.tap(v, "sel:detail:3"); d.tap(v, "act:d_einfahrt")
          d.tap(v, "act:zurueck")
          t.eq(screen(), "4.g.signale")
          d.tap(v, "act:weiter")
          t.eq(screen(), "4.z.detail", "ohne bestaetigte Reihenfolge geht es nicht weiter: " .. d.text(v))
          -- das erste Signal als Einfahrt markieren ist falsch (nicht das letzte vor dem Knoten)
          d.tap(v, "sel:detail:1"); d.tap(v, "act:d_einfahrt")
          t.contains(d.text(v), "EINFAHRTSIGNAL")
          d.tap(v, "act:d_reihenfolge")
          d.tap(v, "act:zurueck")
          t.eq(screen(), "4.g.signale")
          d.tap(v, "act:weiter")
          t.eq(screen(), "4.z.detail", "die Lage ist falsch: der Assistent fuehrt zurueck zum Detailbildschirm")
          -- richtig: das dritte Signal ist die Einfahrt
          d.tap(v, "sel:detail:3"); d.tap(v, "act:d_einfahrt")
          t.contains(v.hint, "Create_Signal_3 ist jetzt das Einfahrtsignal")
          t.eq(west.signals and #west.signals, 3)
          d.tap(v, "act:zurueck")
          t.eq(screen(), "4.g.signale")
          d.tap(v, "act:weiter")
        else
          d.tap_row(v, "signale", "Create_Signal_4"); d.tap(v, "act:weiter")
        end
      end
      t.eq(screen(), "4.g.beobachter", d.text(v))
      observer_no = observer_no + 1
      d.tap_row(v, "beobachter", "Create_TrainObserver_" .. observer_no); d.tap(v, "act:weiter")
      t.eq(screen(), "4.gleise", d.text(v))
    end
    d.tap(v, "act:weiter")
    t.eq(screen(), "5.test", d.text(v))
    d.tap(v, "act:alle_pruefen")
    d.tap(v, "act:alle_starten")
    d.tap(v, "act:weiter")
    t.eq(screen(), "6.fertig", d.text(v))
    d.tap(v, "act:speichern")
    t.eq(d.node.config.status, "aktiv", d.text(v))
    h.step(30)
    local function use_of(name)
      for _, dd in pairs(d.node.config.devices) do if dd.device == name then return dd.signal and dd.signal.use end end
    end
    t.eq(use_of("Create_Signal_3"), "einfahrt"); t.eq(use_of("Create_Signal_1"), "strecke"); t.eq(use_of("Create_Signal_2"), "strecke")
    t.eq(d.world.devices["Create_Signal_3"].state.forced, true, "nur das Einfahrtsignal ist gesperrt")
    t.eq(d.world.devices["Create_Signal_1"].state.forced, false)
    t.eq(d.world.devices["Create_Signal_2"].state.forced, false)
    t.eq(d.world.devices["Create_Signal_4"].state.forced, true, "die Einfahrt Ost mit einem Signal sperrt wie bisher")
  end },
  { "Signale am Gleis waehlen und abwaehlen nimmt die bestaetigte Reihenfolge zurueck", function()
    local wizardlib = require("setup.wizard")
    local create = dofile("tests/fakes/create.lua")
    local detect = require("dev.detect")
    local c, tid, ids = model_with(3, { 3 })
    local world = create.world()
    local wiz = wizardlib.new({
      scan = function() return detect.scan(world.peripheral) end,
      env = { peripheral = world.peripheral, redstone = world.redstone },
      now = function() return 0 end,
    })
    wiz.config = c
    c.tracks[tid].order_ok = true
    t.eq(wiz.toggle_track_device(tid, "signals", ids[1]), true)          -- abwaehlen
    t.eq(c.tracks[tid].order_ok, nil)
    c.tracks[tid].order_ok = true
    t.eq(wiz.toggle_track_device(tid, "signals", ids[1]), true)          -- wieder waehlen
    t.eq(c.tracks[tid].order_ok, nil)
    c.tracks[tid].order_ok = true
    t.eq(wiz.toggle_track_device(tid, "observers", c.tracks[tid].observers[1]), true)
    t.eq(c.tracks[tid].order_ok, true, "ein Beobachter beruehrt die Reihenfolge nicht")
  end },
}
