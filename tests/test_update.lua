--[[
Purpose: Selbstaktualisierung der Nodes (core/updater.lua, Startdatei mit Rueckfall in installer.lua, Seite Update): regelmaessig pruefen, neuen Stand nur in ruhigen Zeiten und gestaffelt installieren, nach dem Neustart eine Probezeit, bei Absturz oder gescheiterter Datenanpassung zur Vorversion zurueck (samt gesicherten Daten) und denselben Stand nicht noch einmal versuchen.
]]

local t = dofile("tests/lib/t.lua")
local cc = dofile("tests/fakes/cc.lua")
local w = dofile("tests/lib/world.lua")
local H = dofile("tests/lib/harness.lua")
_G.__CRN_TEST = true
local installer = dofile("installer.lua")
local storelib = require("core.store")
local updater = require("core.updater")
local BASE = w.BASE

local function put(fs, path, text)
  local fh = fs.open(path, "wb"); fh.write(text); fh.close()
end
local function get(fs, path)
  if not fs.exists(path) then return nil end
  local fh = fs.open(path, "rb"); local text = fh.readAll(); fh.close()
  return text
end

-- Server mit dem Kanal und dem Installer; die Rolle ist auf dem Computer ueber den Installer eingerichtet
local function installed(role, ref, opts)
  local fs, http, env = w.world({ ref = ref, fs = opts and opts.fs })
  http.routes[BASE .. ref .. "/installer.lua"] = w.read("installer.lua")
  t.eq(installer.run({ role, ref, "--yes" }, env), true, env.output())
  return fs, http
end

-- zweiter Stand auf dem Kanal (andere Nummer und anderer Stand)
local function publish(http, ref, number, id)
  w.bump(http, ref, number)
  local url = BASE .. ref .. "/dist/manifest.lua"
  http.routes[url] = (http.routes[url]:gsub('id = "%x+"', 'id = "' .. (id or "deadbeef") .. '"'))
end

local function make(fs, http, over)
  over = over or {}
  local ctx = { now = 0, reboots = 0, notes = {}, block = nil, healthy = true }
  ctx.u = updater.new({
    fs = fs, store = storelib.new(fs), http = http, node_id = over.node_id or "N0001",
    now = function() return ctx.now end,
    blockers = function() return ctx.block end,
    healthy = function() return ctx.healthy end,
    reboot = function() ctx.reboots = ctx.reboots + 1 end,
    notify = function(level, text) ctx.notes[#ctx.notes + 1] = level .. ": " .. text end,
  })
  return ctx.u, ctx
end

local function notes_with(ctx, part)
  local n = 0
  for _, line in ipairs(ctx.notes) do if line:find(part, 1, true) then n = n + 1 end end
  return n
end

-- laeuft die Zeit in ganzen Sekunden weiter und ruft tick auf
local function run_until(ctx, seconds)
  while ctx.now < seconds do
    ctx.now = ctx.now + 1
    ctx.u.tick()
  end
end

-- ===== Startdatei =====================================================================================================================

local function guard(opts)
  opts = opts or {}
  local fs = opts.fs
  if not fs then
    fs = cc.fs()
    for _, d in ipairs({ "/crn", "/crn/app", "/crn_data" }) do fs.makeDir(d) end
    put(fs, "/crn/app/main.lua", "neu")
    if opts.prev then
      fs.makeDir("/crn_prev"); fs.makeDir("/crn_prev/app")
      put(fs, "/crn_prev/app/main.lua", "alt")
    end
  end
  local ctx = { runs = 0, reboots = 0, fs = fs }
  local env = setmetatable({
    fs = fs,
    shell = { run = function() ctx.runs = ctx.runs + 1; if opts.script then return opts.script(ctx) end return true end },
    os = { reboot = function() ctx.reboots = ctx.reboots + 1; error("NEUSTART", 0) end, sleep = function() end },
  }, { __index = _G })
  function ctx.boot()
    local chunk
    if setfenv then
      chunk = assert(loadstring(installer.STARTUP, "=startup"))
      setfenv(chunk, env)
    else
      chunk = assert(load(installer.STARTUP, "=startup", "t", env))
    end
    local ok, err = pcall(chunk)
    if not ok and err ~= "NEUSTART" then error(err, 0) end
    return ok
  end
  return ctx
end

local function probe_of(ctx) return get(ctx.fs, "/crn_data/probe") end

-- ===== Tests ============================================================================================================================

return {
  -- Startdatei -------------------------------------------------------------------------------------------------------------------------
  { "Startdatei: ohne Probe wird CRN einmal gestartet, nichts weiter", function()
    local g = guard()
    t.eq(g.boot(), true)
    t.eq(g.runs, 1); t.eq(g.reboots, 0)
  end },

  { "Startdatei: unterbrochener Austausch wird zu Ende gefuehrt (neue Version vollstaendig oder Vorversion zurueck)", function()
    local g = guard()
    g.fs.delete("/crn")
    g.fs.makeDir("/crn_new"); g.fs.makeDir("/crn_new/app"); put(g.fs, "/crn_new/app/main.lua", "neu2"); put(g.fs, "/crn_new/.complete", "ok\n")
    g.boot()
    t.eq(get(g.fs, "/crn/app/main.lua"), "neu2"); t.ok(not g.fs.exists("/crn_new"))
    t.eq(g.runs, 1)
    -- Rueckkehr unterbrochen: Installation liegt in /crn_tmp, die Vorversion in /crn_prev
    local g2 = guard({ prev = true })
    g2.fs.move("/crn", "/crn_tmp")
    g2.boot()
    t.eq(get(g2.fs, "/crn/app/main.lua"), "alt")
    t.eq(g2.runs, 1)
  end },

  { "Startdatei: Probe laeuft, CRN beendet sich zweimal: beim dritten Start zurueck zur Vorversion, Daten aus der Sicherung, Merker fuer den Stand", function()
    local g = guard({ prev = true })
    g.fs.makeDir("/crn_data/sicherung_f1")
    put(g.fs, "/crn_data/sicherung_f1/config.lua", "alt-config"); put(g.fs, "/crn_data/sicherung_f1/fertig.lua", "ok\n")
    g.fs.makeDir("/crn_data/sicherung_f1/nodesich"); put(g.fs, "/crn_data/sicherung_f1/nodesich/a.lua", "alt-a")
    put(g.fs, "/crn_data/config.lua", "angepasst"); put(g.fs, "/crn_data/format.lua", "format-2"); put(g.fs, "/crn_data/migration.lua", "rest")
    put(g.fs, "/crn_data/probe", "0\nbad=deadbeef\nrestore=sicherung_f1\n")
    t.eq(g.boot(), false)                                   -- erster Start: CRN endet, Neustart
    t.eq(g.runs, 1); t.eq(g.reboots, 1)
    t.eq(probe_of(g):match("^(%d+)"), "1")
    t.eq(g.boot(), false)                                   -- zweiter Start: wieder
    t.eq(g.runs, 2); t.eq(g.reboots, 2)
    t.eq(probe_of(g):match("^(%d+)"), "2")
    t.eq(get(g.fs, "/crn/app/main.lua"), "neu", "noch nicht zurueck")
    g.boot()                                                -- dritter Start: zurueck, bevor CRN laeuft
    t.eq(g.runs, 2, "die schlechte Version wird nicht mehr gestartet")
    t.eq(g.reboots, 3)
    t.eq(get(g.fs, "/crn/app/main.lua"), "alt")
    t.eq(get(g.fs, "/crn_prev/app/main.lua"), "neu", "die zurueckgenommene Version bleibt als Vorversion")
    t.ok(not g.fs.exists("/crn_data/probe"))
    t.eq(get(g.fs, "/crn_data/update_bad"), "deadbeef")
    t.eq(get(g.fs, "/crn_data/config.lua"), "alt-config", "gesicherte Daten zurueck")
    t.eq(get(g.fs, "/crn_data/nodesich/a.lua"), "alt-a")
    t.ok(not g.fs.exists("/crn_data/format.lua"), "Stand der Daten wird vom alten Programm neu eingetragen")
    t.ok(not g.fs.exists("/crn_data/migration.lua"))
    -- danach startet die alte Version ganz normal
    t.eq(g.boot(), true)
    t.eq(g.runs, 3)
  end },

  { "Startdatei: Probe steht schon auf 2 (Computer war vor dem Neustart aus): sofort zurueck, ohne die Version zu starten", function()
    local g = guard({ prev = true })
    put(g.fs, "/crn_data/probe", "2\nbad=cafe\n")
    g.boot()
    t.eq(g.runs, 0); t.eq(g.reboots, 1)
    t.eq(get(g.fs, "/crn/app/main.lua"), "alt")
    t.eq(get(g.fs, "/crn_data/update_bad"), "cafe")
  end },

  { "Startdatei: ohne Vorversion gibt es nichts zurueckzunehmen: Probe endet, CRN wird weiter gestartet, keine Endlosschleife", function()
    local g = guard()
    put(g.fs, "/crn_data/probe", "2\nbad=cafe\n")
    g.boot()
    t.ok(not g.fs.exists("/crn_data/probe"))
    t.eq(g.runs, 1); t.eq(get(g.fs, "/crn/app/main.lua"), "neu")
    t.ok(not g.fs.exists("/crn_data/update_bad"), "nichts zurueckgenommen, also kein Merker")
  end },

  { "Startdatei: ohne Probe bleibt das Beenden des Programms (zum Beispiel Strg+T) folgenlos", function()
    local g = guard({ prev = true, script = function() return false end })
    t.eq(g.boot(), true)
    t.eq(g.reboots, 0); t.eq(g.runs, 1)
  end },

  { "Startdatei: ein liegengebliebenes /crn_tmp stoert den Rueckfall nicht", function()
    local g = guard({ prev = true })
    g.fs.makeDir("/crn_tmp"); put(g.fs, "/crn_tmp/rest.lua", "x")
    put(g.fs, "/crn_data/probe", "2\nbad=cafe\n")
    g.boot()
    t.eq(get(g.fs, "/crn/app/main.lua"), "alt")
    t.eq(get(g.fs, "/crn_prev/app/main.lua"), "neu")
    t.ok(not g.fs.exists("/crn_tmp"))
  end },

  { "Installer: Rueckkehr von Hand beendet eine laufende Probe", function()
    local fs, http, env = w.world({ ref = "beta" })
    http.routes[BASE .. "beta/installer.lua"] = w.read("installer.lua")
    t.eq(installer.run({ "signal", "beta", "--yes" }, env), true, env.output())
    local u = make(fs, http)
    publish(http, "beta", "0.2.0")
    u.check(); u.install({ force = true })
    t.ok(fs.exists("/crn_data/probe"))
    local env2 = cc.env(fs, http)
    t.eq(installer.run({ "--rollback" }, env2), true, env2.output())
    t.ok(not fs.exists("/crn_data/probe"))
    t.contains(get(fs, "/crn/manifest.lua"), '"0.1.0"')
  end },

  { "Installer: eigene alte Startdatei wird durch die neue ersetzt, eine fremde bleibt", function()
    local fs, http = installed("signal", "beta")
    put(fs, "/startup.lua", "-- CRN-STARTUP\nshell.run(\"/crn/app/main.lua\")\n")
    publish(http, "beta", "0.2.0")
    local env = cc.env(fs, http)
    t.eq(installer.run({ "signal", "beta", "--yes" }, env), true, env.output())
    t.eq(get(fs, "/startup.lua"), installer.STARTUP)
    t.contains(env.output(), "startup.lua")
    put(fs, "/startup.lua", "print('anderes Programm')")
    publish(http, "beta", "0.3.0", "abcd1234")
    env = cc.env(fs, http)
    installer.run({ "signal", "beta", "--yes" }, env)
    t.eq(get(fs, "/startup.lua"), "print('anderes Programm')")
  end },

  { "Installer: install.lua nennt Kanal und Quelle", function()
    local fs = installed("signal", "beta")
    local info = get(fs, "/crn/install.lua")
    t.contains(info, 'ref = "beta"')
    t.contains(info, 'base = "' .. BASE .. '"')
  end },

  -- Pruefen ------------------------------------------------------------------------------------------------------------------------------
  { "Pruefen: gleicher Stand auf dem Kanal ist aktuell", function()
    local fs, http = installed("signal", "beta")
    local u = make(fs, http)
    local status = u.check()
    t.eq(status, "aktuell")
    t.eq(u.state().available, nil)
    t.eq(u.state().ref, "beta"); t.eq(u.state().role, "signal")
  end },

  { "Pruefen: neuer Stand auf dem Kanal ist verfuegbar, mit Nummer", function()
    local fs, http = installed("signal", "beta")
    local u = make(fs, http)
    publish(http, "beta", "0.2.0")
    local status, text = u.check()
    t.eq(status, "verfuegbar"); t.contains(text, "0.2.0")
    t.eq(u.state().available.version, "0.2.0"); t.eq(u.state().available.id, "deadbeef")
  end },

  { "Pruefen: feste Version (Tag oder Commit) wird nicht verfolgt", function()
    local fs, http = installed("signal", "v0.1.0")
    local u = make(fs, http)
    local status = u.check()
    t.eq(status, "fest")
    t.eq(#http.requests, 1 + w.role_files("signal"), "kein weiterer Abruf")
  end },

  { "Pruefen: ohne HTTP und bei unerreichbarem Server kein Absturz, Hinweis bleibt", function()
    local fs, http = installed("signal", "beta")
    local u = make(fs, nil)
    t.eq((u.check()), "kein_http")
    t.contains(u.state().note, "HTTP")
    local u2 = make(fs, http)
    for url in pairs(http.routes) do http.routes[url] = nil end
    local status, text = u2.check()
    t.eq(status, "fehler"); t.ok(#text > 5)
    t.eq(u2.state().available, nil)
  end },

  { "Pruefen: ein unbrauchbares Verzeichnis (Rolle fehlt) wird nicht als Update gemeldet", function()
    local fs, http = installed("signal", "beta")
    local u = make(fs, http)
    http.routes[BASE .. "beta/dist/manifest.lua"] = 'return { version = "0.2.0", id = "deadbeef", files = {}, roles = {} }'
    local status = u.check()
    t.eq(status, "fehler")
    t.eq(u.state().available, nil)
  end },

  -- Installieren ---------------------------------------------------------------------------------------------------------------------------
  { "Installieren: neuer Stand, Vorversion bleibt, Probe wird angelegt, Neustart angefordert", function()
    local fs, http = installed("signal", "beta")
    local u, c = make(fs, http)
    publish(http, "beta", "0.2.0")
    u.check()
    local ok, text = u.install({ force = true })
    t.eq(ok, true, text)
    t.contains(get(fs, "/crn/manifest.lua"), '"0.2.0"')
    t.contains(get(fs, "/crn_prev/manifest.lua"), '"0.1.0"')
    t.contains(get(fs, "/crn/install.lua"), 'id = "deadbeef"')
    t.eq(get(fs, "/crn_data/probe"), "0\nbad=deadbeef\n")
    t.eq(c.reboots, 1)
    t.eq(installer.check(cc.env(fs, http)), true)
    t.eq(get(fs, "/startup.lua"), installer.STARTUP)
  end },

  { "Zyklus: scheitert die Installation (Kanal noch nicht vollstaendig), wird nicht jede Sekunde neu geladen, spaeter aber erneut versucht", function()
    local fs, http = installed("signal", "beta")
    local u, c = make(fs, http)
    publish(http, "beta", "0.2.0")
    local good = http.routes[BASE .. "beta/dist/core/adler.lua"]
    http.routes[BASE .. "beta/dist/core/adler.lua"] = "falscher Inhalt"
    run_until(c, 1000)
    local attempts = 0
    for _, url in ipairs(http.requests) do if url:find("beta/installer.lua", 1, true) then attempts = attempts + 1 end end
    t.ok(attempts >= 1 and attempts <= 2, "Versuche in 1000 s: " .. attempts)
    t.eq(c.reboots, 0)
    t.contains(get(fs, "/crn/manifest.lua"), '"0.1.0"')
    http.routes[BASE .. "beta/dist/core/adler.lua"] = good
    run_until(c, 1700)
    t.eq(c.reboots, 1, "nach der Wartezeit gelingt es")
    t.contains(get(fs, "/crn/manifest.lua"), '"0.2.0"')
  end },

  { "Installieren: nach der Installation kein zweiter Versuch, auch wenn bis zum Neustart ein weiterer Stand erscheint", function()
    local fs, http = installed("signal", "beta")
    local u, c = make(fs, http)
    publish(http, "beta", "0.2.0")
    u.check(); u.install({ force = true })
    publish(http, "beta", "0.3.0", "abcd1234")
    t.eq((u.install({ force = true })), false)
    run_until(c, 4000)
    t.eq(c.reboots, 1)
    t.contains(get(fs, "/crn/manifest.lua"), '"0.2.0"')
  end },

  { "Installieren: Download bricht ab -> nichts veraendert, keine Probe, kein Neustart, Grund sichtbar", function()
    local fs, http = installed("signal", "beta")
    local u, c = make(fs, http)
    publish(http, "beta", "0.2.0")
    u.check()
    http.routes[BASE .. "beta/dist/core/adler.lua"] = nil
    local ok, text = u.install({ force = true })
    t.eq(ok, false); t.contains(text, "core/adler.lua")
    t.contains(get(fs, "/crn/manifest.lua"), '"0.1.0"')
    t.ok(not fs.exists("/crn_prev") and not fs.exists("/crn_new") and not fs.exists("/crn_data/probe"))
    t.eq(c.reboots, 0)
    t.contains(u.state().note, "core/adler.lua")
  end },

  { "Installieren: Installer vom Kanal ist unbrauchbar -> nichts veraendert", function()
    local fs, http = installed("signal", "beta")
    local u, c = make(fs, http)
    publish(http, "beta", "0.2.0")
    u.check()
    http.routes[BASE .. "beta/installer.lua"] = "das ist kein Lua <<<"
    local ok, text = u.install({ force = true })
    t.eq(ok, false); t.contains(text, "Installer")
    t.contains(get(fs, "/crn/manifest.lua"), '"0.1.0"'); t.eq(c.reboots, 0)
    http.routes[BASE .. "beta/installer.lua"] = "return 5"
    ok, text = u.install({ force = true })
    t.eq(ok, false); t.eq(c.reboots, 0)
    -- ein winziger Stellvertreter mit allen Namen ist kein Installer (abgeschnittener oder untergeschobener Download)
    http.routes[BASE .. "beta/installer.lua"] = "return { get_manifest = function() end, plan = function() end, apply = function() return true end, recover = function() end, make_room = function() end }"
    ok, text = u.install({ force = true })
    t.eq(ok, false); t.contains(text, "Installer"); t.eq(c.reboots, 0)
    t.contains(get(fs, "/crn/manifest.lua"), '"0.1.0"')
  end },

  { "Installieren: Platz knapp -> die alte Vorversion wird geopfert, sonst bleibt alles wie es ist und der Hinweis nennt --replace", function()
    -- Leitstelle: alt und neu passen nicht zugleich neben den Daten (siehe test_installer)
    local fs, http = installed("zentrale", "beta")
    put(fs, "/installer.lua", string.rep("x", 32061))
    put(fs, "/crn_data/netz.lua", string.rep("d", 20000))
    local u, c = make(fs, http)
    publish(http, "beta", "0.2.0")
    u.check()
    local ok, text = u.install({ force = true })
    t.eq(ok, false)
    t.contains(text, "--replace")
    t.contains(get(fs, "/crn/manifest.lua"), '"0.1.0"')
    t.ok(not fs.exists("/crn_new") and not fs.exists("/crn_prev"))
    t.eq(c.reboots, 0)
    t.eq(get(fs, "/crn_data/netz.lua"), string.rep("d", 20000))
    -- erlaubt der Betreiber das Ersetzen, geschieht es (keine Vorversion, Probe ohne Rueckweg)
    u.set_replace(true)
    ok, text = u.install({ force = true })
    t.eq(ok, true, text)
    t.contains(get(fs, "/crn/manifest.lua"), '"0.2.0"')
    t.ok(not fs.exists("/crn_prev"))
    t.ok(not fs.exists("/crn_data/probe"), "ohne Vorversion gibt es keine Probe mit Rueckweg")
    t.eq(c.reboots, 1)
    -- vorhandene Vorversion wird bei Platzmangel zuerst geopfert
    local fs2, http2 = installed("depot", "beta", { fs = { capacity = 700000 } })
    local u2 = make(fs2, http2)
    publish(http2, "beta", "0.2.0")
    u2.check()
    t.eq((u2.install({ force = true })), true)
    u2 = make(fs2, http2)                                -- der Computer ist neu gestartet
    publish(http2, "beta", "0.3.0", "abcd1234")
    u2.check()
    local ok2, text2 = u2.install({ force = true })
    t.eq(ok2, true, text2)
    t.contains(get(fs2, "/crn_prev/manifest.lua"), '"0.2.0"')
  end },

  -- Zyklus ------------------------------------------------------------------------------------------------------------------------------
  { "Zyklus: automatisch prueft nach der Anlaufzeit, installiert aber erst nach der Ruhezeit seit dem Start", function()
    local fs, http = installed("signal", "beta")
    local u, c
    for i = 1, 40 do                                   -- ein Node, dessen erste Pruefung vor Ende der Ruhezeit liegt
      u, c = make(fs, http, { node_id = string.format("N%04d", i) })
      if u.state().next_check < 250 then break end
    end
    publish(http, "beta", "0.2.0")
    local first = u.state().next_check
    t.ok(first >= 60 and first < 250, "erste Pruefung nach 1 bis 4 Minuten: " .. tostring(first))
    run_until(c, first - 1)
    t.eq(u.state().available, nil, "noch nicht geprueft")
    run_until(c, first)
    t.eq(u.state().available.version, "0.2.0")
    t.eq(c.reboots, 0, "Ruhezeit nach dem Start (5 Minuten)")
    t.contains(get(fs, "/crn/manifest.lua"), '"0.1.0"')
    run_until(c, 299)
    t.eq(c.reboots, 0)
    run_until(c, 301)
    t.eq(c.reboots, 1)
    t.contains(get(fs, "/crn/manifest.lua"), '"0.2.0"')
  end },

  { "Zyklus: eine Rolle, die gerade etwas hat (Fahrt laeuft), haelt die Installation zurueck; der Grund steht im Zustand", function()
    local fs, http = installed("signal", "beta")
    local u, c = make(fs, http)
    publish(http, "beta", "0.2.0")
    c.block = "Eine Fahrt laeuft"
    run_until(c, 2000)
    t.eq(c.reboots, 0)
    t.contains(u.state().note, "Eine Fahrt laeuft")
    t.eq(u.state().available.version, "0.2.0")
    c.block = nil
    run_until(c, 2001)
    t.eq(c.reboots, 1)
  end },

  { "Zyklus: melden meldet einmal, aus macht nichts, Betriebsart bleibt gespeichert", function()
    local fs, http = installed("signal", "beta")
    local u, c = make(fs, http)
    u.set_mode("melden")
    publish(http, "beta", "0.2.0")
    run_until(c, 4000)
    t.eq(c.reboots, 0)
    t.eq(notes_with(c, "0.2.0"), 1, "die Meldung kommt nur einmal")
    local before = #http.requests
    u.set_mode("aus")
    run_until(c, 9000)
    t.eq(#http.requests, before, "aus: keine Abrufe")
    local u2 = make(fs, http)
    t.eq(u2.state().mode, "aus")
    t.eq(u.set_mode("quatsch"), nil)
    t.eq(u2.state().mode, "aus")
  end },

  { "Zyklus: Standardbetriebsart ist automatisch", function()
    local fs, http = installed("signal", "beta")
    local u = make(fs, http)
    t.eq(u.state().mode, "auto")
  end },

  { "Zyklus: die ersten Pruefungen der Nodes liegen verteilt, nicht alle zugleich", function()
    local fs, http = installed("signal", "beta")
    local seen, count = {}, 0
    for i = 1, 40 do
      local u = make(fs, http, { node_id = string.format("N%04d", i) })
      local at = u.state().next_check
      t.ok(at >= 60 and at <= 600)
      if not seen[at] then seen[at] = true; count = count + 1 end
    end
    t.ok(count >= 15, "mindestens 15 verschiedene Zeitpunkte bei 40 Nodes: " .. count)
    local a = make(fs, http, { node_id = "N0007" }).state().next_check
    local b = make(fs, http, { node_id = "N0007" }).state().next_check
    t.eq(a, b, "bei jedem Start derselbe Zeitpunkt")
  end },

  { "Zyklus: nach einer Pruefung ohne Ergebnis (Server nicht erreichbar) wird spaeter erneut versucht", function()
    local fs, http = installed("signal", "beta")
    local u, c = make(fs, http)
    local routes = http.routes
    http.routes = {}
    run_until(c, 700)
    t.ok(u.state().note ~= nil)
    t.eq(u.state().available, nil)
    http.routes = routes
    publish(http, "beta", "0.2.0")
    c.block = "Test"
    run_until(c, 700 + 1900)
    t.eq(u.state().available.version, "0.2.0")
  end },

  -- Probezeit und Rueckfall -----------------------------------------------------------------------------------------------------------
  { "Probe: nach dem Neustart gilt die neue Version erst nach zwei Minuten Gesundheit als bestaetigt", function()
    local fs, http = installed("signal", "beta")
    local u, c = make(fs, http)
    publish(http, "beta", "0.2.0")
    u.check(); u.install({ force = true })
    local u2, c2 = make(fs, http)                         -- neuer Start des Computers
    t.eq(u2.state().probe, 0)
    run_until(c2, 119)
    t.ok(fs.exists("/crn_data/probe"))
    run_until(c2, 121)
    t.ok(not fs.exists("/crn_data/probe"), "bestaetigt")
    t.eq(u2.state().probe, nil)
    t.eq(notes_with(c2, "bestaetigt"), 1)
    t.contains(get(fs, "/crn_prev/manifest.lua"), '"0.1.0"', "die Vorversion bleibt fuer die handgesteuerte Rueckkehr")
  end },

  { "Probe: ist der Node kurz nach dem Start nicht gesund (Datenanpassung gescheitert), wird sofort zurueckgenommen", function()
    local fs, http = installed("signal", "beta")
    local u = make(fs, http)
    publish(http, "beta", "0.2.0")
    u.check(); u.install({ force = true })
    local u2, c2 = make(fs, http)
    c2.healthy = false
    run_until(c2, 20)
    t.eq(get(fs, "/crn_data/probe"):match("^(%d+)"), "2")
    t.eq(c2.reboots, 1)
    run_until(c2, 40)
    t.eq(c2.reboots, 1, "nur einmal angefordert")
  end },

  { "Probe: nach einer Datenanpassung merkt sich die Probe die Sicherung (damit der Rueckfall die Daten zurueckspielt)", function()
    local fs, http = installed("signal", "beta")
    local u = make(fs, http)
    publish(http, "beta", "0.2.0")
    u.check(); u.install({ force = true })
    local u2 = make(fs, http)
    u2.note_migration("/crn_data/sicherung_f1")
    t.eq(get(fs, "/crn_data/probe"), "0\nbad=deadbeef\nrestore=sicherung_f1\n")
  end },

  { "Zurueckgenommener Stand wird nicht noch einmal installiert; ein neuerer schon", function()
    local fs, http = installed("signal", "beta")
    publish(http, "beta", "0.2.0")
    put(fs, "/crn_data/update_bad", "deadbeef")
    local u, c = make(fs, http)
    t.eq(u.state().skipped, "deadbeef")
    t.ok(not fs.exists("/crn_data/update_bad"))
    t.eq(notes_with(c, "zurueckgenommen"), 1)
    run_until(c, 4000)
    t.eq(c.reboots, 0, "derselbe Stand wird nicht noch einmal versucht")
    t.eq(u.state().available.id, "deadbeef")
    publish(http, "beta", "0.2.1", "cafe1234")
    run_until(c, 8000)
    t.eq(c.reboots, 1)
    t.contains(get(fs, "/crn/manifest.lua"), '"0.2.1"')
    -- der Merker uebersteht einen weiteren Start
    local fs2, http2 = installed("signal", "beta")
    publish(http2, "beta", "0.2.0")
    put(fs2, "/crn_data/update_bad", "deadbeef")
    make(fs2, http2)
    local u3, c3 = make(fs2, http2)
    t.eq(u3.state().skipped, "deadbeef")
    run_until(c3, 4000)
    t.eq(c3.reboots, 0)
  end },

  { "Probe laeuft: kein weiteres Update, bis sie bestaetigt ist", function()
    local fs, http = installed("signal", "beta")
    local u = make(fs, http)
    publish(http, "beta", "0.2.0")
    u.check(); u.install({ force = true })
    local u2, c2 = make(fs, http)
    publish(http, "beta", "0.3.0", "abcd1234")
    c2.healthy = true
    u2.check()
    local ok = u2.install({})
    t.eq(ok, false, "ohne Zwang nicht waehrend der Probe")
    t.contains(get(fs, "/crn/manifest.lua"), '"0.2.0"')
  end },

  -- Knoten -------------------------------------------------------------------------------------------------------------------------------
  { "Knoten: Seite Update zeigt Stand und Betriebsart, Knopf wechselt die Betriebsart, Pruefen und Installieren gehen von Hand", function()
    local h = H.new()
    local s = h.add_node({ id = "strecke", roles = { "signal" }, tracks = { { name = "Gleis 1", signals = { "Sig_1" } } } })
    local fs, http = installed("signal", "beta", { fs = nil })
    for path, text in pairs(fs._state.files) do if path:match("^crn/") or path:match("^startup") then s.fs._state.files[path] = text end end
    for dir in pairs(fs._state.dirs) do s.fs._state.dirs[dir] = true end
    local reboots = 0
    s.env_extra = { http = http, reboot = function() reboots = reboots + 1 end }
    local n = s.restart()
    t.ok(n.updater, "Aktualisierung eingerichtet")
    local v = H.open_page(s, "update")
    local text = s.text(v)
    t.contains(text, "automatisch")
    t.contains(text, "beta")
    t.contains(text, "0.1.0")
    s.tap(v, "act:update_modus")
    t.contains(s.text(v), "nur melden")
    s.tap(v, "act:update_modus")
    s.tap(v, "act:update_modus")
    t.contains(s.text(v), "automatisch")
    publish(http, "beta", "0.2.0")
    s.tap(v, "act:update_pruefen")
    t.contains(s.text(v), "0.2.0")
    s.tap(v, "act:update_jetzt")
    t.eq(reboots, 0, "erst nach Bestaetigung")
    s.tap(v, "act:update_jetzt")
    t.eq(reboots, 1)
    t.contains(get(s.fs, "/crn/manifest.lua"), '"0.2.0"')
  end },

  { "Knoten: im Takt geprueft, Rolle Bahnhof wartet mit der Installation, solange eine Abfahrt freigegeben ist", function()
    local h = H.new()
    local z = h.add_node({ id = "hauptstelle", roles = { "zentrale" }, tracks = {} })
    local b = h.add_node({ id = "bahnhof", roles = { "passagierbahnhof" }, central = "hauptstelle",
      tracks = { { name = "Gleis 1", station_name = "Westbahnhof" } }, registration = "Gleis 1" })
    local fs, http = installed("passagierbahnhof", "beta")
    for path, text in pairs(fs._state.files) do if path:match("^crn/") or path:match("^startup") then b.fs._state.files[path] = text end end
    for dir in pairs(fs._state.dirs) do b.fs._state.dirs[dir] = true end
    local reboots = 0
    b.env_extra = { http = http, reboot = function() reboots = reboots + 1 end }
    h.restart("bahnhof")
    publish(http, "beta", "0.2.0")
    local track = b.node.roles.station.tracks[1]
    track.p.release_set = true
    h.step(900)
    t.eq(reboots, 0, "Abfahrt freigegeben: nicht jetzt")
    t.contains(b.node.updater.state().note, "Abfahrt")
    track.p.release_set = false
    h.step(5)
    t.eq(reboots, 1)
  end },

  { "Knoten: Signal-Node wartet, solange Knoten oder Leitstelle ein Signal sperren; Sperren des Bedieners halten nicht auf", function()
    local h = H.new()
    local s = h.add_node({ id = "strecke", roles = { "signal" }, tracks = { { name = "Gleis 1", signals = { "Sig_1", "Sig_2" } } } })
    local role = s.node.roles.signal
    local id = role.signals[1].id
    t.eq(role.update_blocker(), nil)
    t.eq(role.lock(id, "bediener", "Test"), true)
    t.eq(role.update_blocker(), nil, "ein Bediener-Sperre bleibt ueber den Neustart stehen")
    t.eq(role.lock(id, "knoten", "Zug"), true)
    t.contains(role.update_blocker(), "gesperrt")
    t.eq(role.unlock(id, "knoten"), true)
    t.eq(role.update_blocker(), nil)
    t.eq(role.lock(id, "leitstelle", "Fahrweg"), true)
    t.contains(role.update_blocker(), id)
    t.eq(role.unlock(id, "leitstelle"), true)
    t.eq(role.update_blocker(), nil)
  end },

  { "Knoten: Leitstelle wartet, solange eine Fahrt unterwegs ist", function()
    local h = H.new()
    local z = h.add_node({ id = "hauptstelle", roles = { "zentrale" }, tracks = {} })
    local role = z.node.roles.zentrale
    t.eq(role.update_blocker(), nil, "ohne Fahrten nichts, was haelt")
    role.orders.add_template({ id = "fahrt", title = "Fahrt", train = "GZ-001", return_to_start = true, stops = { { station = "Weizenhof", wait = 0 }, { station = "Zentrallager", wait = 2 } } })
    local order = role.orders.request("fahrt", "r1")
    order.state = "wartend"
    t.eq(role.update_blocker(), nil, "ein wartender Auftrag haelt nicht")
    order.state = "unterwegs"
    t.contains(role.update_blocker(), "Fahrt")
    order.state = "abgeschlossen"
    t.eq(role.update_blocker(), nil)
  end },

  { "Knoten: gescheiterte Datenanpassung in der Probe fordert den Rueckfall an", function()
    local h = H.new()
    local s = h.add_node({ id = "strecke", roles = { "signal" }, tracks = { { name = "Gleis 1", signals = { "Sig_1" } } } })
    local fs, http = installed("signal", "beta")
    for path, text in pairs(fs._state.files) do if path:match("^crn/") or path:match("^startup") then s.fs._state.files[path] = text end end
    for dir in pairs(fs._state.dirs) do s.fs._state.dirs[dir] = true end
    put(s.fs, "/crn_data/probe", "0\nbad=deadbeef\n")
    storelib.new(s.fs).save("/crn_data/format.lua", { format = 1, program = "0.1" })
    local reboots = 0
    s.env_extra = { http = http, reboot = function() reboots = reboots + 1 end, data_format = 2,
      data_steps = { [1] = { text = "kaputt", run = function() error("Absicht") end } } }
    local n = s.restart()
    t.eq(n.format_status, "fehlgeschlagen")
    h.step(30)
    t.eq(get(s.fs, "/crn_data/probe"):match("^(%d+)"), "2")
    t.eq(reboots, 1)
  end },

  -- Zusammenspiel -------------------------------------------------------------------------------------------------------------------------
  { "Gesamtablauf: Update installiert, der neue Stand stuerzt ab -> Startdatei nimmt ihn zurueck, derselbe Stand wird nicht noch einmal versucht", function()
    local fs, http = installed("signal", "beta")
    local u = make(fs, http)
    publish(http, "beta", "0.2.0")
    u.check()
    t.eq((u.install({ force = true })), true)
    t.contains(get(fs, "/crn/manifest.lua"), '"0.2.0"')
    -- Neustart: der neue Stand beendet sich sofort, zweimal; beim dritten Start wird zurueckgenommen
    local g = guard({ fs = fs, script = function() return false end })
    g.boot(); g.boot(); g.boot()
    t.contains(get(fs, "/crn/manifest.lua"), '"0.1.0"', "Vorversion ist zurueck")
    t.contains(get(fs, "/crn_prev/manifest.lua"), '"0.2.0"')
    t.eq(installer.check(cc.env(fs, http)), true)
    t.eq(get(fs, "/crn_data/update_bad"), "deadbeef")
    -- die zurueckgenommene Version laeuft; der Updater kennt den Stand und laesst ihn aus
    local u2, c2 = make(fs, http)
    t.eq(u2.state().skipped, "deadbeef")
    t.ok(u2.state().id ~= "deadbeef", "die Version der Vorversion laeuft")
    run_until(c2, 4000)
    t.eq(c2.reboots, 0)
    t.contains(get(fs, "/crn/manifest.lua"), '"0.1.0"')
  end },

  { "Gesamtablauf: Update installiert, der neue Stand laeuft gesund -> Probe bestaetigt, keine Rueckkehr", function()
    local fs, http = installed("signal", "beta")
    local u = make(fs, http)
    publish(http, "beta", "0.2.0")
    u.check(); u.install({ force = true })
    local u2, c2 = make(fs, http)
    local g = guard({ fs = fs, script = function()
      run_until(c2, 130)                                 -- das Programm laeuft zwei Minuten und sagt der Probe, dass alles gesund ist
      return true
    end })
    g.boot()
    t.ok(not fs.exists("/crn_data/probe"))
    t.eq(g.reboots, 0)
    t.contains(get(fs, "/crn/manifest.lua"), '"0.2.0"')
  end },

  { "Abbruch an jeder Dateiaenderung waehrend der Selbstaktualisierung: die Startdatei stellt immer eine vollstaendige Version her", function()
    local checked = 0
    local n = 1
    local finished = false
    while not finished do
      local fs, http = installed("signal", "beta")
      local u = make(fs, http)
      publish(http, "beta", "0.2.0")
      u.check()
      fs._state.crash_at = fs._state.ops + n
      local ok = pcall(u.install, { force = true })
      fs._state.crash_at = nil
      fs._state.crashed = nil
      if ok then finished = true end
      -- Neustart des Computers: die Startdatei fuehrt zu Ende oder raeumt auf
      local g = guard({ fs = fs })
      g.boot()
      t.ok(fs.exists("/crn/app/main.lua"), "n=" .. n .. ": kein Programm vorhanden")
      t.eq(installer.check(cc.env(fs, http)), true, "n=" .. n .. ": Installation unvollstaendig")
      t.eq(g.runs >= 1, true)
      checked = checked + 1
      n = n + 1
      t.ok(n < 400, "Schleife endet nicht")
    end
    t.ok(checked > 20, "viele Abbruchstellen geprueft: " .. checked)
  end },

  -- Befehlszeile -----------------------------------------------------------------------------------------------------------------------------
  { "Befehl main update: Zustand, pruefen, Betriebsart, Ersetzen, jetzt installieren", function()
    package.path = "./src/?.lua;" .. package.path
    local main = require("app.main")
    local fs, http = installed("signal", "beta")
    local reboots = 0
    local function call(...)
      local env = cc.env(fs, http)
      env.reboot = function() reboots = reboots + 1 end
      local ok = main.run(env, { "update", ... })
      return ok, env.output()
    end
    local ok, out = call()
    t.eq(ok, true); t.contains(out, "Kanal beta"); t.contains(out, "Betriebsart: auto")
    ok, out = call("pruefen")
    t.contains(out, "Aktuell")
    publish(http, "beta", "0.2.0")
    ok, out = call("pruefen")
    t.contains(out, "0.2.0")
    ok, out = call("melden")
    t.contains(out, "melden")
    ok, out = call()
    t.contains(out, "Betriebsart: melden")
    ok, out = call("ersetzen", "ein")
    t.contains(out, "erlaubt")
    ok, out = call()
    t.contains(out, "Ersetzen erlaubt")
    call("ersetzen", "aus")
    ok, out = call("quatsch")
    t.eq(ok, false); t.contains(out, "Aufruf")
    ok, out = call("jetzt")
    t.eq(ok, true, out)
    t.eq(reboots, 1)
    t.contains(get(fs, "/crn/manifest.lua"), '"0.2.0"')
  end },
}
