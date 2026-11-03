--[[
Purpose: Gemeinsamer Start der Pruefungen im bisherigen Ablauf (Konzept 13.1, 13.2, 13.4, 13.5): lesende Pruefungen laufen von selbst, alle schaltenden werden zusammen bestaetigt und nacheinander ausgefuehrt, bei unklarem Zustand wird die Serie gestoppt, gueltige Ergebnisse bleiben.
]]

local t = dofile("tests/lib/t.lua")
local cc = dofile("tests/fakes/cc.lua")
local create = dofile("tests/fakes/create.lua")
local wizardlib = require("setup.wizard")
local detect = require("dev.detect")
local drv = dofile("tests/lib/ui_driver.lua")

-- Assistent mit einem Bahnhofsgleis: Station, Signal, Ausgang (zwei schaltende Pruefungen)
local function build()
  local w = create.world()
  w.add_modem("left", true)
  w.add_station("Create_Station_1", { station_name = "Hof" })
  w.add_signal("Create_Signal_1")
  local wiz = wizardlib.new({
    scan = function() return detect.scan(w.peripheral) end,
    env = { peripheral = w.peripheral, redstone = w.redstone },
    now = function() return 0 end,
  })
  wiz.set_network("Testnetz", "hauptstelle", nil)
  wiz.set_name("Hof")
  assert(wiz.toggle_role("passagierbahnhof"))
  assert(wiz.toggle_role("signal"))
  return wiz, w
end

local model = require("setup.model")

local function prepared()
  local wiz, w = build()
  local cfg = wiz.config
  local tid = model.add_track(cfg, "Gleis 1")
  local station = model.add_device(cfg, "station", "Create_Station_1")
  local signal = model.add_device(cfg, "signal", "Create_Signal_1")
  model.assign(cfg, tid, "station", station)
  model.assign(cfg, tid, "signals", signal)
  cfg.tracks[tid].release = { side = "back" }
  return wiz, w, tid
end

return {
  { "Ohne Bestaetigung laufen nur die lesenden Pruefungen, die schaltenden bleiben offen und werden gemeldet", function()
    local wiz, w = prepared()
    local r = wiz.run_open_tests(false)
    t.eq(r.ok, 2); t.eq(r.failed, 0); t.eq(r.open, 2)
    t.eq(w.devices["Create_Signal_1"].state.forced, false, "nichts geschaltet")
    t.eq(w.sides.back, false)
    for _, test in ipairs(wiz.tests()) do
      if test.kind == "schalten" then t.eq(wiz.test_state(test.id, nil, test), "offen") end
    end
  end },
  { "Mit Bestaetigung laufen alle nacheinander, der Ausgangszustand ist danach wieder hergestellt", function()
    local wiz, w = prepared()
    local r = wiz.run_open_tests(true)
    t.eq(r.ok, 4); t.eq(r.failed, 0); t.eq(r.open, 0); t.eq(r.stopped, nil)
    t.eq(w.devices["Create_Signal_1"].state.forced, false); t.eq(w.sides.back, false)
    t.ok(wiz.all_tests_ok())
  end },
  { "Gueltige Ergebnisse bleiben: ein zweiter Lauf fuehrt nur Offenes aus; Namensaenderungen und andere Gleise entwerten nichts", function()
    local wiz, w, tid = prepared()
    wiz.run_open_tests(true)
    local r = wiz.run_open_tests(true)
    t.eq(r.ok + r.failed + r.open, 0, "nichts mehr offen")
    wiz.config.tracks[tid].name = "Umbenannt"; wiz.config.node.name = "Anderer Name"
    t.ok(wiz.all_tests_ok(), "Namensaenderung: keine erneute Hardwarepruefung")
    local other = model.add_track(wiz.config, "Gleis 2")
    t.ok(wiz.all_tests_ok(), "ein weiteres Gleis ohne Geraete entwertet nichts")
    wiz.config.tracks[tid].direction = "rueck"
    t.ok(not wiz.all_tests_ok(), "geaenderte Richtung des Gleises: betroffene Pruefungen erneut")
    local again = wiz.run_open_tests(true)
    t.eq(again.ok, 4, "alle vier betreffen das geaenderte Gleis")
  end },
  { "Ein Geraet ersetzt: nur dessen Pruefungen sind wieder offen", function()
    local wiz, w, tid = prepared()
    local cfg = wiz.config
    w.add_signal("Create_Signal_2")
    local second = model.add_track(cfg, "Gleis 2")
    local sig2 = model.add_device(cfg, "signal", "Create_Signal_2")
    model.assign(cfg, second, "signals", sig2)
    wiz.run_open_tests(true)
    t.ok(wiz.all_tests_ok())
    w.add_signal("Create_Signal_3")
    cfg.devices[sig2].device = "Create_Signal_3"
    local again = wiz.run_open_tests(true)
    t.eq(again.ok, 2, "Lesen und Sperre des ersetzten Signals, sonst nichts")
    t.ok(wiz.all_tests_ok())
  end },
  { "Ein Fehler stoppt nicht die anderen Pruefungen, wird aber als Fehler gezaehlt", function()
    local wiz, w = prepared()
    w.devices["Create_Signal_1"].state.forced = true            -- schon gesperrt: die Sperrpruefung lehnt ab (kein Eingriff in eine fremde Sperre)
    local r = wiz.run_open_tests(true)
    t.eq(r.failed, 1)
    t.eq(r.ok, 3)
    t.eq(w.devices["Create_Signal_1"].state.forced, true, "die fremde Sperre bleibt")
  end },
  { "Bleibt ein Ausgang eingeschaltet (Zustand unklar), stoppt die Serie und meldet es; die nicht gelaufenen bleiben offen", function()
    local wiz, w, tid = prepared()
    local second = model.add_track(wiz.config, "Gleis 2")
    wiz.config.tracks[second].release = { side = "top" }
    -- der Ausgang von Gleis 1 laesst sich nicht mehr ausschalten
    local real = w.redstone.setOutput
    w.redstone.setOutput = function(side, value) if side == "back" and value == false then return end return real(side, value) end
    local r = wiz.run_open_tests(true)
    t.eq(r.stopped, "Ausgang: Gleis 1")
    t.eq(r.failed, 1)
    t.eq(r.open, 1, "die Pruefung von Gleis 2 lief nicht")
    for _, test in ipairs(wiz.tests()) do
      if test.title == "Ausgang: Gleis 2" then t.eq(wiz.test_state(test.id, nil, test), "offen") end
      if test.title == "Ausgang: Gleis 1" then t.eq(wiz.test_state(test.id, nil, test), "fehler") end
    end
    t.ok(not wiz.all_tests_ok())
  end },
}
