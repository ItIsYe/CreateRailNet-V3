--[[
Purpose: Abschlusspruefung nach Konzept 13 (src/setup/pruefung.lua): Pflichtangaben, gemeinsamer Start nur nach Bestaetigung, Lesen und Testsperre je Signal mit Zuruecklesen, eine schon gesetzte Sperre bleibt unangetastet, Ergebnisse je Geraet (nur das betroffene wird ungueltig), Zeitbegrenzung und Abbruch, Marke vor dem Schalten und Wiederanlauf nach einer Unterbrechung, Aktivierung nur bei vollstaendigem Erfolg.
]]

local t = dofile("tests/lib/t.lua")
local create = dofile("tests/fakes/create.lua")
local model = require("setup.model")
local detect = require("dev.detect")
local pruefung = require("setup.pruefung")

-- Node mit n Gleisen, je ein Signal; claimed = Kennung von der Leitstelle schon da
local function setup(count, opts)
  opts = opts or {}
  local world = create.world()
  world.add_modem("left", true)
  local config = model.new("Signal West-Ost N0001", { "signal" }, { name = "Testnetz", central_id = "hauptstelle" })
  config.node.id = "N0001"
  if opts.claimed ~= false then config.node.claimed, config.node.label = true, "N0001 | SIG | B0001" end
  config.status = "entwurf"
  local devs = {}
  for i = 1, count do
    local name = "Create_Signal_" .. i
    world.add_signal(name)
    local tid = model.add_track(config, "Gleis " .. i)
    local did = model.add_device(config, "signal", name)
    model.assign(config, tid, "signals", did)
    devs[i] = { name = name, id = did, track = tid }
  end
  local persisted = {}
  local clock_v = 0
  local p = pruefung.new({
    env = { peripheral = world.peripheral },
    config = function() return config end,
    now = function() return 100 end,
    clock = opts.clock or function() return clock_v end,
    scan = function() return detect.scan(world.peripheral) end,
    persist = opts.persist or function()
      persisted[#persisted + 1] = config.pruefung and config.pruefung.lauf and config.pruefung.lauf.device or false
      return true
    end,
  })
  return p, config, world, devs, persisted
end

local function forced(world, name) return world.devices[name].state.forced end

return {
  { "Start nur nach Bestaetigung; die Wirkung nennt Anzahl und Folge", function()
    local p = setup(3)
    local text, count = p.effect()
    t.eq(count, 3)
    t.contains(text, "3 Signal(en)"); t.contains(text, "Rotsperre"); t.contains(text, "unberuehrt"); t.contains(text, "vorbereitet")
    local ok, why = p.start(false)
    t.eq(ok, nil); t.contains(why, "bestaetigt")
    ok, why = p.start(nil)
    t.eq(ok, nil)
    t.eq(p.state().phase, "idle")
    t.eq(p.start(true), true)
  end },
  { "Pflichtangaben: Kennung, Gleis ohne Signal, kein Gleis, fehlendes oder abgezogenes Geraet, kein Modem", function()
    local p, config, world, devs = setup(2, { claimed = false })
    local problems = p.required()
    t.contains(problems[1], "Kennung der Leitstelle")
    local ok, why = p.start(true)
    t.eq(ok, nil); t.contains(why, "Kennung")
    config.node.claimed, config.node.label = true, "N0001 | SIG | B0001"
    t.eq(#p.required(), 0)
    -- Gleis ohne Signal
    model.add_track(config, "Gleis 9")
    problems = p.required()
    t.eq(#problems, 1); t.contains(problems[1], "Gleis 9: Das Signal fehlt")
    config.tracks[next(config.tracks) and "gleis3" or "x"] = nil
    -- abgezogenes Geraet
    world.detach(devs[1].name)
    problems = p.required()
    t.contains(problems[1], "nicht angeschlossen")
    -- kein Gleis
    config.tracks = {}
    config.devices = {}
    problems = p.required()
    t.contains(table.concat(problems, "|"), "kein Gleis")
    -- kein Modem
    local p2, c2, w2 = setup(1)
    w2.detach("left")
    t.contains(p2.required()[1], "modem")
  end },
  { "Voller Lauf: alle Signale lesen, Testsperre setzen, zuruecklesen, aufheben; am Ende alles frei und aktivierbar", function()
    local p, config, world, devs, persisted = setup(4)
    t.eq(p.all_ok(), false)
    t.eq(p.start(true), true)
    t.eq(p.step(1e9), "fertig")
    t.eq(p.all_ok(), true)
    for _, d in ipairs(devs) do
      local r = p.device(d.id)
      t.eq(r.lesen.state, "ok"); t.eq(r.sperre.state, "ok")
      t.eq(forced(world, d.name), false, "keine Testsperre bleibt zurueck")
    end
    t.eq(config.pruefung.lauf, nil, "keine Marke zurueck")
    local st = p.state()
    t.eq(st.phase, "fertig"); t.eq(st.done, 4); t.eq(st.total, 4); t.eq(st.ok, true); t.eq(#st.devices, 4)
    t.eq(st.devices[1].track, "Gleis 1")
  end },
  { "Marke wird vor dem Schalten gespeichert und danach geloescht", function()
    local p, config, world, devs, persisted = setup(2)
    p.start(true); p.step(1e9)
    -- je Signal: einmal mit Marke (vor dem Schalten), einmal ohne (danach); am Ende ein Speichern
    t.eq(persisted[1], devs[1].id); t.eq(persisted[2], false)
    t.eq(persisted[3], devs[2].id); t.eq(persisted[4], false)
  end },
  { "Kann die Marke nicht gespeichert werden, wird nicht geschaltet", function()
    local p, config, world, devs = setup(1, { persist = function() return nil, "Platte voll" end })
    local calls = 0
    local real = world.devices[devs[1].name].methods.setForcedRed
    world.devices[devs[1].name].methods.setForcedRed = function(v) calls = calls + 1 return real(v) end
    p.start(true); p.step(1e9)
    t.eq(calls, 0, "setForcedRed wurde nie aufgerufen")
    t.eq(p.device(devs[1].id).sperre.state, "fehler")
    t.contains(p.device(devs[1].id).sperre.text, "Platte voll")
    t.eq(p.device(devs[1].id).lesen.state, "ok", "das Lesen ist trotzdem gueltig")
    t.eq(p.all_ok(), false)
  end },
  { "Eine schon gesetzte Sperre bleibt unangetastet; die Pruefung bleibt offen (gesperrt) und laeuft nach dem Aufheben durch", function()
    local p, config, world, devs = setup(3)
    world.devices[devs[2].name].methods.setForcedRed(true)          -- betriebliche oder fremde Sperre
    p.start(true); p.step(1e9)
    t.eq(forced(world, devs[2].name), true, "Sperre bleibt")
    t.eq(p.device(devs[2].id).sperre.state, "gesperrt")
    t.contains(p.device(devs[2].id).sperre.text, "unberuehrt")
    t.eq(p.device(devs[1].id).sperre.state, "ok", "die anderen sind fertig")
    t.eq(p.all_ok(), false)
    world.devices[devs[2].name].methods.setForcedRed(false)
    p.start(true)
    t.eq(p.state().total, 1, "nur das noch offene Signal wird erneut geprueft")
    p.step(1e9)
    t.eq(p.all_ok(), true)
  end },
  { "Ein Signal haelt die Sperre nicht: nur dieses faellt durch, die anderen Ergebnisse bleiben", function()
    local p, config, world, devs = setup(3)
    world.devices[devs[2].name].state.ignore_hold = true
    p.start(true); p.step(1e9)
    t.eq(p.device(devs[1].id).sperre.state, "ok")
    t.eq(p.device(devs[2].id).sperre.state, "fehler")
    t.contains(p.device(devs[2].id).sperre.text, "nicht bestaetigt")
    t.eq(p.device(devs[3].id).sperre.state, "ok")
    t.eq(p.all_ok(), false)
  end },
  { "Testsperre laesst sich nicht aufheben: deutliche Warnung, Ergebnis fehlgeschlagen", function()
    local p, config, world, devs = setup(1)
    local real = world.devices[devs[1].name].methods.setForcedRed
    world.devices[devs[1].name].methods.setForcedRed = function(v) if v then return real(true) end end      -- Aufheben wirkt nicht
    p.start(true); p.step(1e9)
    local r = p.device(devs[1].id).sperre
    t.eq(r.state, "fehler"); t.contains(r.text, "ACHTUNG")
    t.eq(forced(world, devs[1].name), true)
  end },
  { "Nicht erreichbar beim Lesen: Fehler, keine Schaltpruefung", function()
    local p, config, world, devs = setup(2)
    local methods = world.devices[devs[1].name].methods
    methods.getState = function() error("Peripheral weg") end
    p.start(true); p.step(1e9)
    t.eq(p.device(devs[1].id).lesen.state, "fehler"); t.contains(p.device(devs[1].id).lesen.text, "nicht erreichbar")
    t.eq(p.device(devs[1].id).sperre.state, "offen", "ohne Lesen keine Schaltpruefung")
    t.eq(p.device(devs[2].id).sperre.state, "ok")
  end },
  { "Erneute Pruefung: faellt das Lesen jetzt aus, gilt die alte Schaltpruefung nicht mehr", function()
    local p, config, world, devs = setup(2)
    p.start(true); p.step(1e9)
    t.eq(p.all_ok(), true)
    world.devices[devs[1].name].methods.getState = function() error("Peripheral weg") end
    p.start(true, true)                              -- alles erneut
    p.step(1e9)
    t.eq(p.device(devs[1].id).lesen.state, "fehler")
    t.eq(p.device(devs[1].id).sperre.state, "offen", "kein altes 'ok' stehen lassen")
    t.eq(p.all_ok(), false)
    t.eq(p.device(devs[2].id).sperre.state, "ok")
    -- Zustand lesbar, aber die Sperre nicht abfragbar: ebenfalls kein altes 'ok'
    world.devices[devs[2].name].methods.isForcedRed = function() error("keine Antwort") end
    p.start(true, true)
    p.step(1e9)
    t.eq(p.device(devs[2].id).lesen.state, "fehler")
    t.eq(p.device(devs[2].id).sperre.state, "offen")
  end },
  { "Zeitbegrenzung: ein Schritt macht nur so viel, wie die Zeit erlaubt; die Phase bleibt 'laeuft'", function()
    local now = 0
    local p, config, world, devs = setup(5, { clock = function() now = now + 1 return now end })
    p.start(true)
    local phase = p.step(2)
    t.eq(phase, "laeuft")
    local st = p.state()
    t.ok(st.done >= 1 and st.done < 5, "Teil erledigt: " .. st.done)
    t.ok(st.current == nil or st.current:find("Gleis"), "aktuelles Signal wird genannt")
    local guard = 0
    while p.step(2) == "laeuft" and guard < 10 do guard = guard + 1 end
    t.eq(p.state().phase, "fertig"); t.eq(p.all_ok(), true)
  end },
  { "Abbruch: keine weiteren Tests, nichts bleibt gesperrt, spaeter wieder aufnehmbar", function()
    local now = 0
    local p, config, world, devs = setup(4, { clock = function() now = now + 1 return now end })
    p.start(true)
    p.step(1)
    local done = p.state().done
    p.abort()
    t.eq(p.state().phase, "abgebrochen")
    t.eq(p.step(5), "abgebrochen", "danach laeuft nichts weiter")
    t.eq(p.state().done, done)
    for _, d in ipairs(devs) do t.eq(forced(world, d.name), false) end
    t.eq(p.device(devs[4].id).lesen.state, "offen", "das letzte Signal wurde nie angefasst")
    t.eq(p.all_ok(), false)
    -- neuer Start: nur noch die offenen
    p.start(true)
    t.eq(p.state().total, 4 - done)
    p.step(100)
    t.eq(p.all_ok(), true)
  end },
  { "Ergebnisse je Geraet: Umbenennen kostet nichts, ein anderes Geraet macht nur dieses Ergebnis ungueltig", function()
    local p, config, world, devs = setup(3)
    p.start(true); p.step(1e9)
    t.eq(p.all_ok(), true)
    config.tracks[devs[1].track].name = "Hauptgleis"
    config.node.name = "Anderer Name"
    t.eq(p.all_ok(), true, "Namensaenderung braucht keine Pruefung")
    world.add_signal("Create_Signal_neu")
    config.devices[devs[2].id].device = "Create_Signal_neu"
    t.eq(p.device(devs[2].id).sperre.state, "offen", "ersetztes Geraet: offen")
    t.eq(p.device(devs[1].id).sperre.state, "ok"); t.eq(p.device(devs[3].id).sperre.state, "ok")
    t.eq(p.all_ok(), false)
    p.start(true)
    t.eq(p.state().total, 1)
    p.step(1e9)
    t.eq(p.all_ok(), true)
  end },
  { "Alles schon geprueft: ein neuer Start meldet gleich 'fertig' ohne zu schalten", function()
    local p, config, world, devs = setup(2)
    p.start(true); p.step(1e9)
    local calls = 0
    for _, d in ipairs(devs) do
      local real = world.devices[d.name].methods.setForcedRed
      world.devices[d.name].methods.setForcedRed = function(v) calls = calls + 1 return real(v) end
    end
    t.eq(p.start(true), true)
    t.eq(p.step(1e9), "fertig")
    t.eq(calls, 0)
  end },
  { "Wiederanlauf: stehengebliebene Marke und Testsperre werden erkannt und aufgehoben", function()
    local p, config, world, devs = setup(2)
    config.pruefung = { devices = {}, lauf = { device = devs[1].id, t = 5 } }
    world.devices[devs[1].name].state.forced = true                 -- Absturz mitten in der Testsperre
    local note, ok = p.recover()
    t.contains(note, "aufgehoben"); t.eq(ok, true)
    t.eq(forced(world, devs[1].name), false)
    t.eq(config.pruefung.lauf, nil)
    t.eq(p.recover(), nil, "nichts mehr zu tun")
  end },
  { "Wiederanlauf: Marke ohne gesetzte Sperre, und eine Sperre, die sich nicht loesen laesst", function()
    local p, config, world, devs = setup(2)
    config.pruefung = { devices = {}, lauf = { device = devs[1].id, t = 5 } }
    local note, ok = p.recover()
    t.contains(note, "unterbrochene Pruefung"); t.eq(ok, true)
    -- Aufheben wirkt nicht
    config.pruefung = { devices = {}, lauf = { device = devs[2].id, t = 5 } }
    world.devices[devs[2].name].state.forced = true
    world.devices[devs[2].name].state.ignore_hold = true
    note, ok = p.recover()
    t.contains(note, "ACHTUNG"); t.eq(ok, false)
    -- unbekanntes Geraet in der Marke
    config.pruefung = { devices = {}, lauf = { device = "geraet99", t = 5 } }
    note, ok = p.recover()
    t.ok(note and ok)
    t.eq(config.pruefung.lauf, nil)
  end },
  { "Wiederanlauf entwertet das unterbrochene Ergebnis: das Signal wird neu geprueft", function()
    local p, config, world, devs = setup(1)
    p.start(true); p.step(1e9)
    t.eq(p.all_ok(), true)
    config.pruefung.lauf = { device = devs[1].id, t = 5 }
    p.recover()
    t.eq(p.device(devs[1].id).sperre.state, "offen")
    t.eq(p.all_ok(), false)
  end },
}
