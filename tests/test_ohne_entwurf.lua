--[[
Purpose: Es gibt keinen Entwurf der Einrichtung mehr, und weder ein alter Rest noch der Node-Name blockieren eine neue Einrichtung nach einem Update: die Anforderungskennung dieses Computers im Netzverzeichnis bleibt bei jedem Versuch gleich (eigene Datei), ein leerer oder fehlender Name sperrt nichts (die Kennung gilt), ein Entwurf aus einer aelteren Version wird beim ersten Start verworfen, und die Testsperre-Marke steht in einer eigenen Datei.
]]

local t = dofile("tests/lib/t.lua")
local drv = dofile("tests/lib/ui_driver.lua")
local create = dofile("tests/fakes/create.lua")
local storelib = require("core.store")
local model = require("setup.model")
local migrations = require("core.migrations")

local function world()
  local w = create.world()
  w.add_station("Create_Station_1")
  w.add_signal("Create_Signal_5")
  w.add_modem("left", true)
  return w
end

local function new_driver()
  local d = drv.new({ world = world() })
  d.restart()
  return d
end

return {
  { "Anforderungskennung: bleibt bei Neustart gleich, steht in einer eigenen Datei, eine neue wird nur auf Wunsch gestellt", function()
    local d = new_driver()
    local store = storelib.new(d.fs)
    t.ok(not d.fs.exists("/crn_data/anforderung.lua"), "noch keine Anforderung")
    local first = d.node.claim()
    t.ok(first:match("^c%d+%-%d+$"), first)
    t.eq(store.load("/crn_data/anforderung.lua").claim, first)
    t.eq(d.node.claim(), first, "gleich bei jedem Aufruf")
    d.restart()
    t.eq(d.node.claim(), first, "gleich nach dem Neustart")
    local fresh = d.node.new_claim()
    t.ok(fresh ~= first)
    t.eq(store.load("/crn_data/anforderung.lua").claim, fresh)
    d.restart()
    t.eq(d.node.claim(), fresh)
    -- einmalige Kennungen fuer einzelne Vorgaenge sind davon unabhaengig
    local token = d.node.new_token()
    t.ok(token ~= fresh and token ~= d.node.new_token())
    t.eq(d.node.claim(), fresh)
  end },

  { "Eine eingerichtete Node behaelt ihre Anforderung (config.node.claim), auch wenn die Datei fehlt", function()
    local d = new_driver()
    local cfg = model.new("Hof", { "gueterbahnhof" }, { name = "Netz", central_id = "z" })
    cfg.status = "aktiv"
    cfg.node.claim, cfg.node.claimed = "c7-123456789012", true
    storelib.new(d.fs).save("/crn_data/config.lua", cfg)
    d.restart()
    t.eq(d.node.claim(), "c7-123456789012")
    t.ok(not d.fs.exists("/crn_data/anforderung.lua"), "keine zweite Quelle")
  end },

  { "Nach dem Update: ein Entwurf der alten Version blockiert nichts; die Einrichtung beginnt von vorn, die Kennung aus dem Entwurf bleibt", function()
    local d = new_driver()
    local store = storelib.new(d.fs)
    -- Stand der Vorversion: Format 1, ein Entwurf mit Kennung und leerem Namen
    local draft = model.new("", { "passagierbahnhof" }, { name = "Netz", central_id = "z" })
    draft.status = "entwurf"
    draft.node.id, draft.node.claimed, draft.node.claim = "N0007", true, "c3-555555555555"
    store.save("/crn_data/config.lua", draft)
    store.save("/crn_data/format.lua", { format = 1, program = "0.1" })
    d.restart()
    t.eq(d.node.format_status, "migriert")
    t.eq(d.node.config, nil)
    t.eq(d.node.status().text, "Einrichtung")
    t.eq(d.node.claim(), "c3-555555555555", "dieselbe Anforderung wie im Entwurf")
    t.ok(not d.fs.exists("/crn_data/config.lua"))
    t.eq(store.load("/crn_data/format.lua").format, migrations.FORMAT)
    local v = d.view()
    d.tap(v, "nav:einrichtung")
    t.ok(d.has(v, "Einrichtung starten"), d.text(v))
    d.tap(v, "act:start")
    t.eq(d.node.setup.session().screen, "1.modus")
    t.ok(not d.has(v, "Entwurf"), d.text(v))
  end },

  { "Name leer: 'Von Hand' schlaegt einen Namen vor, ein geleertes Feld sperrt nichts, die Kennung folgt dem Namen", function()
    local d = new_driver()
    local v = d.view()
    d.tap(v, "nav:einrichtung"); d.tap(v, "act:start")
    d.tap(v, "sel:modus:2"); d.tap(v, "act:weiter")
    d.tap(v, "sel:netzwahl:1"); d.tap(v, "act:weiter")
    d.type(v, "netz", "Testnetz"); d.tap(v, "act:weiter")
    d.type(v, "zentrale", "hauptstelle"); d.tap(v, "act:weiter")
    d.tap_row(v, "rollen", "Passagierbahnhof"); d.tap(v, "act:weiter")
    d.tap(v, "act:von_hand")
    t.eq(d.node.setup.session().screen, "2.name", d.text(v))
    local wiz = d.node.setup.session().wiz
    local suggestion = wiz.suggest_name()
    t.ok(d.has(v, suggestion), "Vorschlag steht im Feld: " .. d.text(v))
    d.type(v, "name", "")
    d.tap(v, "act:weiter")
    t.eq(d.node.setup.session().screen, "3.geraete", "ein leeres Feld sperrt nicht: " .. d.text(v))
    t.eq(wiz.config.node.name, suggestion)
    t.eq(wiz.config.node.id, model.slug(suggestion))
    t.ok(not d.has(v, "braucht einen Namen"))
  end },

  { "Eine Einrichtung ohne Namen (aus einer alten Version) laesst sich aendern; Titel und Uebersicht zeigen die Kennung", function()
    local d = new_driver()
    local cfg = model.new("", { "gueterbahnhof" }, { name = "Netz", central_id = "z" })
    cfg.status, cfg.node.id = "aktiv", "alter-hof"
    local tid = model.add_track(cfg, "Gleis 1")
    model.assign(cfg, tid, "station", model.add_device(cfg, "station", "Create_Station_1"))
    storelib.new(d.fs).save("/crn_data/config.lua", cfg)
    d.restart()
    local v = d.view()
    local first = d.text(v):match("^[^\n]*")
    t.contains(first, "alter-hof - gueterbahnhof")
    t.not_contains(first, "neue Node")
    d.tap(v, "nav:uebersicht")
    t.contains(d.text(v), "Node: alter-hof")
    t.not_contains(d.text(v), "noch ohne Namen")
    d.tap(v, "nav:einrichtung"); d.tap(v, "act:start")
    local wiz = d.node.setup.session().wiz
    for _, p in ipairs(wiz.warnings()) do t.ok(p.code ~= "name", "der Name ist kein Hindernis: " .. p.text) end
    t.eq(wiz.config.node.name, "", "der Name bleibt, wie er ist")
    t.eq(wiz.config.node.id, "alter-hof")
  end },

  { "Testsperre-Marke: eigene Datei, wird beim Start ausgewertet und danach entfernt; ohne Marke und ohne Sperre passiert nichts", function()
    local d = new_driver()
    local store = storelib.new(d.fs)
    store.save("/crn_data/pruefmarke.lua", { device = "signal1", name = "Create_Signal_5", t = 3 })
    d.world.devices["Create_Signal_5"].state.forced = true
    d.restart()
    t.eq(d.world.devices["Create_Signal_5"].state.forced, false)
    t.ok(not d.fs.exists("/crn_data/pruefmarke.lua"))
    local texts = {}
    for _, m in ipairs(d.node.messages) do texts[#texts + 1] = m.text end
    t.contains(table.concat(texts, "|"), "Testsperre")
    -- eine fremde Sperre ohne Marke bleibt unberuehrt
    d.world.devices["Create_Signal_5"].state.forced = true
    d.restart()
    t.eq(d.world.devices["Create_Signal_5"].state.forced, true)
    -- Marke, aber das Signal ist gar nicht gesperrt: Marke weg, Hinweis, keine Schaltung
    d.world.devices["Create_Signal_5"].state.forced = false
    store.save("/crn_data/pruefmarke.lua", { device = "signal1", name = "Create_Signal_5", t = 3 })
    d.restart()
    t.ok(not d.fs.exists("/crn_data/pruefmarke.lua"))
    t.eq(d.world.devices["Create_Signal_5"].state.forced, false)
  end },
}
