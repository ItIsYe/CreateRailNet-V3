--[[
Purpose: Gefuehrte Einrichtung im Assistenten (src/setup/wizard.lua): Gleise aus dem Netzverzeichnis uebernehmen (nur die gewaehlten), Kennung und Label von der Leitstelle, Signale den Gleisen zuordnen und wieder loesen, Zuordnung bleibt beim erneuten Uebernehmen erhalten, die Abschlusspruefung entscheidet ueber die Aktivierung, Rollenwechsel beendet den gefuehrten Ablauf.
]]

local t = dofile("tests/lib/t.lua")
local cc = dofile("tests/fakes/cc.lua")
local create = dofile("tests/fakes/create.lua")
local wizardlib = require("setup.wizard")
local pruefung = require("setup.pruefung")
local detect = require("dev.detect")
local storelib = require("core.store")

local function build(signals)
  local w = create.world()
  w.add_modem("left", true)
  for _, name in ipairs(signals or { "Create_Signal_1", "Create_Signal_2", "Create_Signal_3", "Create_Signal_4" }) do w.add_signal(name) end
  local fs = cc.fs()
  fs.makeDir("/crn_data")
  local store = storelib.new(fs)
  local wiz = wizardlib.new({
    scan = function() return detect.scan(w.peripheral) end,
    env = { peripheral = w.peripheral, redstone = w.redstone },
    now = function() return 0 end,
  })
  wiz.set_network("Testnetz", "hauptstelle", nil)
  wiz.pruefung = pruefung.new({
    env = { peripheral = w.peripheral },
    config = function() return wiz.config end,
    now = function() return 0 end,
    scan = function() return detect.scan(w.peripheral) end,
    mark = function() return true end,
    marker = function() return nil end,
  })
  return wiz, w, store
end

local INFO = {
  area = { id = "B0001", name = "West-Ost" },
  claim = "c1-123456789012",
  node = { id = "N0017", name = "Signal West-Ost N0017", label = "N0017 | SIG | B0001" },
  tracks = {
    { id = "A0001", name = "Gleis 1", direction = "Ost" },
    { id = "A0002", name = "Gleis 2", direction = "Ost" },
    { id = "A0003", name = "Gleis 3", direction = "West" },
    { id = "A0004", name = "Gleis 4", direction = "West" },
  },
}

local function names(rows)
  local out = {}
  for _, r in ipairs(rows) do out[#out + 1] = r.name end
  return table.concat(out, ",")
end

local function copy(info, tracks)
  local c = {}
  for k, v in pairs(info) do c[k] = v end
  c.tracks = tracks or info.tracks
  return c
end

return {
  { "Uebernehmen: Rolle Signal, Kennung, Name, Label und Bereich von der Leitstelle; Gleise in Verzeichnisreihenfolge", function()
    local wiz = build()
    t.eq(wiz.guided_begin(INFO), true)
    t.eq(wiz.config.node.id, "N0017"); t.eq(wiz.config.node.name, "Signal West-Ost N0017")
    t.eq(wiz.config.node.label, "N0017 | SIG | B0001"); t.eq(wiz.config.node.area, "B0001"); t.eq(wiz.config.node.claimed, true)
    t.eq(wiz.config.node.roles[1], "signal"); t.eq(#wiz.config.node.roles, 1)
    t.eq(names(wiz.guided_rows()), "Gleis 1,Gleis 2,Gleis 3,Gleis 4")
    t.eq(wiz.guided_rows()[1].direction, "Ost"); t.eq(wiz.guided_rows()[3].direction, "West")
    t.eq(wiz.config.network.central_id, "hauptstelle")
  end },
  { "Nur die uebernommenen Gleise: weniger Gleise als der Bereich hat", function()
    local wiz = build()
    wiz.guided_begin(copy(INFO, { INFO.tracks[1], INFO.tracks[3] }))
    t.eq(names(wiz.guided_rows()), "Gleis 1,Gleis 3")
  end },
  { "Signale zuordnen: nur angeschlossene, nur einmal, mehrere je Gleis, wieder loesen", function()
    local wiz, w = build()
    wiz.guided_begin(INFO)
    wiz.rescan()
    local rows = wiz.guided_rows()
    t.eq(#wiz.guided_free_signals(), 4)
    t.eq(wiz.guided_assign(rows[1].track, "Create_Signal_3"), true)
    t.eq(#wiz.guided_free_signals(), 3)
    local ok, why = wiz.guided_assign(rows[2].track, "Create_Signal_3")
    t.eq(ok, false); t.contains(why, "gehoert schon zu Gleis 1")
    ok, why = wiz.guided_assign(rows[2].track, "Create_Signal_99")
    t.eq(ok, false); t.contains(why, "nicht angeschlossen")
    ok, why = wiz.guided_assign("gleis99", "Create_Signal_1")
    t.eq(ok, false)
    t.eq(wiz.guided_assign(rows[1].track, "Create_Signal_1"), true, "ein zweites Signal am selben Gleis")
    t.eq(#wiz.guided_rows()[1].signals, 2)
    t.eq(wiz.guided_rows()[1].signals[2].device, "Create_Signal_1")
    t.eq(wiz.guided_unassign(rows[1].track), true)
    t.eq(#wiz.guided_rows()[1].signals, 1)
    t.eq(wiz.guided_rows()[1].signals[1].device, "Create_Signal_3", "das zuletzt zugeordnete ist weg")
    t.eq(#wiz.guided_free_signals(), 3)
    ok, why = wiz.guided_unassign(rows[2].track)
    t.eq(ok, false); t.contains(why, "kein Signal")
    -- ein Geraet ohne die noetigen Methoden wird nicht zugeordnet
    w.devices["Create_Signal_2"].methods.isForcedRed = nil
    wiz.rescan()
    ok, why = wiz.guided_assign(rows[2].track, "Create_Signal_2")
    t.eq(ok, false); t.contains(why, "Methoden")
  end },
  { "Erneutes Uebernehmen behaelt Zuordnungen weiter uebernommener Gleise; abgewaehlte Gleise nehmen ihre Signale mit", function()
    local wiz = build()
    wiz.guided_begin(INFO)
    wiz.rescan()
    local rows = wiz.guided_rows()
    wiz.guided_assign(rows[1].track, "Create_Signal_1")
    wiz.guided_assign(rows[2].track, "Create_Signal_2")
    wiz.guided_assign(rows[3].track, "Create_Signal_3")
    wiz.guided_begin(copy(INFO, { INFO.tracks[1], INFO.tracks[3] }))
    t.eq(names(wiz.guided_rows()), "Gleis 1,Gleis 3")
    t.eq(wiz.guided_rows()[1].signals[1].device, "Create_Signal_1")
    t.eq(wiz.guided_rows()[2].signals[1].device, "Create_Signal_3")
    t.eq(#wiz.guided_free_signals(), 2, "das Signal des abgewaehlten Gleises ist wieder frei")
    local count = 0
    for _ in pairs(wiz.config.devices) do count = count + 1 end
    t.eq(count, 2, "keine verwaisten Geraete in der Konfiguration")
    -- umbenanntes Gleis im Verzeichnis: der Name wird nachgezogen, die Zuordnung bleibt
    local renamed = copy(INFO, { { id = "A0001", name = "Hauptgleis", direction = "Ost" }, INFO.tracks[3] })
    wiz.guided_begin(renamed)
    t.eq(wiz.guided_rows()[1].name, "Hauptgleis"); t.eq(wiz.guided_rows()[1].signals[1].device, "Create_Signal_1")
  end },
  { "Aktivierung haengt an der Abschlusspruefung, nicht an Einzelpruefungen", function()
    local wiz, w, store = build()
    wiz.guided_begin(copy(INFO, { INFO.tracks[1], INFO.tracks[2] }))
    wiz.rescan()
    local rows = wiz.guided_rows()
    wiz.guided_assign(rows[1].track, "Create_Signal_1")
    wiz.guided_assign(rows[2].track, "Create_Signal_2")
    t.eq(#wiz.tests(), 0, "keine Einzelpruefungen im gefuehrten Ablauf")
    t.eq(wiz.all_tests_ok(), false)
    local ok, why = wiz.step_ok(5, true)
    t.eq(ok, false); t.contains(why, "Pruefungen")
    t.eq(wiz.pruefung.start(true), true)
    t.eq(wiz.pruefung.step(1e9), "fertig")
    t.eq(wiz.all_tests_ok(), true)
    t.eq(wiz.step_ok(5, true), true)
    local status, problems = wiz.finish(store, "/crn_data/config.lua")
    t.eq(status, "aktiv", problems[1] and problems[1].text)
    local saved = store.load("/crn_data/config.lua")
    t.eq(saved.status, "aktiv"); t.eq(saved.node.id, "N0017"); t.eq(saved.node.label, "N0017 | SIG | B0001")
    t.eq(w.devices["Create_Signal_1"].state.forced, false)
  end },
  { "Ohne Pruefung wird nicht aktiviert und nichts gespeichert (Aktivieren verlangt die bestandene Abschlusspruefung)", function()
    local wiz, w, store = build()
    wiz.guided_begin(copy(INFO, { INFO.tracks[1] }))
    wiz.rescan()
    wiz.guided_assign(wiz.guided_rows()[1].track, "Create_Signal_1")
    local status = wiz.finish(store, "/crn_data/config.lua")
    t.eq(status, nil)
    t.eq(store.load("/crn_data/config.lua"), nil, "kein Entwurf auf dem Computer")
  end },
  { "Eine schon aktive Node wird nicht in den gefuehrten Ablauf gezogen (sie wuerde sonst ihre laufende Einrichtung verlieren)", function()
    local wiz, w, store = build()
    wiz.guided_begin(copy(INFO, { INFO.tracks[1] }))
    wiz.rescan()
    wiz.guided_assign(wiz.guided_rows()[1].track, "Create_Signal_1")
    wiz.pruefung.start(true); wiz.pruefung.step(1e9)
    t.eq(wiz.finish(store, "/crn_data/config.lua"), "aktiv")
    local saved = store.load("/crn_data/config.lua")
    local again = wizardlib.new({
      scan = function() return detect.scan(w.peripheral) end,
      env = { peripheral = w.peripheral, redstone = w.redstone }, now = function() return 0 end, existing = saved,
    })
    t.eq(again.guided, nil)
    t.eq(again.was_active, true)
  end },
  { "Rolle aendern beendet den gefuehrten Ablauf: wieder Einzelpruefungen", function()
    local wiz = build()
    wiz.guided_begin(INFO)
    t.eq(wiz.guided, true)
    wiz.toggle_role("signal")
    wiz.toggle_role("zentrale")
    t.eq(wiz.guided, nil)
    wiz.toggle_role("zentrale")
    wiz.toggle_role("signal")
    t.eq(wiz.guided, nil, "kommt nicht von selbst zurueck")
  end },
  { "Der Assistent ohne Verzeichnis arbeitet unveraendert: Kennung aus dem Namen, Einzelpruefungen", function()
    local wiz = build()
    t.eq(wiz.guided, nil); t.eq(wiz.claimed_id, nil)
    wiz.toggle_role("signal")
    wiz.set_name("Strecke Nord")
    t.eq(wiz.config.node.id, "strecke-nord")
    wiz.toggle_device("Create_Signal_1")
    t.ok(#wiz.tests() > 0)
  end },
}
