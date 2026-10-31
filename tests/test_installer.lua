--[[
Purpose: Der Installer gegen strenge CC-Fakes und das echte dist/: frische Installation, Aktualisierung mit Vorversion, Rueckkehr, Abbruch an jeder Dateiaenderung, kaputte Downloads, zu wenig Platz, fremde startup.lua, bewegliche Version.
]]

local t = dofile("tests/lib/t.lua")
local cc = dofile("tests/fakes/cc.lua")

_G.__CRN_TEST = true
local installer = dofile("installer.lua")

local w = dofile("tests/lib/world.lua")
local BASE = w.BASE
local read = w.read
local routes_for = w.routes_for
local world = w.world

local function run(env, ...) return installer.run({ ... }, env) end

local function valid(env)
  local ok = installer.check(cc.env(env.fs, env.http))
  return ok
end

return {
  { "frische Installation", function()
    local fs, http, env = world()
    t.eq(run(env, "zentrale", "v0.1.0"), true, env.output())
    t.ok(fs.exists("/crn/app/main.lua"))
    t.ok(fs.exists("/crn/manifest.lua"))
    t.ok(fs.exists("/crn/install.lua"))
    t.ok(fs.isDir("/crn_data"), "Datenspeicher getrennt angelegt")
    t.ok(not fs.exists("/crn_new"), "Staging aufgeraeumt")
    t.ok(not fs.exists("/crn_prev"), "keine Vorversion bei Erstinstallation")
    t.ok(fs.exists("/startup.lua"))
    t.contains(env.output(), "Installiert: Version 0.1.0")
    t.eq(env.reads, 0, "feste Version fragt nicht nach")
    t.eq(valid(env), true)
  end },
  { "nur die Dateien der Rolle werden geladen", function()
    local fs, http, env = world()
    run(env, "signal", "v0.1.0")
    for _, url in ipairs(http.requests) do t.ok(url:find("/dist/", 1, true), url) end
    t.eq(#http.requests, 1 + w.role_files("signal"), "Verzeichnis plus die Dateien der Rolle")
  end },
  { "Aktualisierung behaelt die Vorversion, Rueckkehr tauscht", function()
    local fs, http, env = world()
    run(env, "depot", "v0.1.0")
    local env2 = env
    w.add_version(http, "v0.1.0", "v0.2.0", "0.2.0")
    t.eq(run(env2, "depot", "v0.2.0"), true, env2.output())
    t.ok(fs.exists("/crn_prev/manifest.lua"), "Vorversion vorhanden")
    t.contains(fs.open("/crn/manifest.lua", "r").readAll(), '"0.2.0"')
    t.contains(fs.open("/crn_prev/manifest.lua", "r").readAll(), '"0.1.0"')
    t.eq(run(env2, "--rollback"), true, env2.output())
    t.contains(fs.open("/crn/manifest.lua", "r").readAll(), '"0.1.0"')
    t.contains(fs.open("/crn_prev/manifest.lua", "r").readAll(), '"0.2.0"')
  end },
  { "Rueckkehr ohne Vorversion", function()
    local fs, http, env = world()
    run(env, "depot", "v0.1.0")
    t.eq(run(env, "--rollback"), false)
    t.contains(env.output(), "Keine Vorversion")
  end },
  { "fehlende Datei beim Download laesst alles unveraendert", function()
    local fs, http, env = world({ tweak = function(routes, ref) routes[BASE .. ref .. "/dist/core/adler.lua"] = nil end })
    t.eq(run(env, "zentrale", "v0.1.0"), false)
    t.contains(env.output(), "Download fehlgeschlagen: core/adler.lua")
    t.ok(not fs.exists("/crn"), "nichts installiert")
    t.ok(not fs.exists("/crn_new"), "Staging entfernt")
  end },
  { "beschaedigte Datei wird erkannt", function()
    local fs, http, env = world({ tweak = function(routes, ref)
      local url = BASE .. ref .. "/dist/core/version.lua"
      routes[url] = routes[url] .. " "
    end })
    t.eq(run(env, "zentrale", "v0.1.0"), false)
    t.contains(env.output(), "passt nicht zum Verzeichnis")
    t.ok(not fs.exists("/crn"))
  end },
  { "gleich lange, aber veraenderte Datei wird erkannt", function()
    local fs, http, env = world({ tweak = function(routes, ref)
      local url = BASE .. ref .. "/dist/core/version.lua"
      routes[url] = (routes[url]:gsub("CRN", "XYZ", 1))
    end })
    t.eq(run(env, "zentrale", "v0.1.0"), false)
    t.contains(env.output(), "passt nicht zum Verzeichnis")
  end },
  { "falsche Groesse im Verzeichnis wird erkannt", function()
    local fs, http, env = world({ tweak = function(routes, ref)
      local url = BASE .. ref .. "/dist/manifest.lua"
      routes[url] = (routes[url]:gsub('%["core/version.lua"%] = { size = (%d+)', function(n) return '["core/version.lua"] = { size = ' .. (tonumber(n) + 1) end))
    end })
    t.eq(run(env, "zentrale", "v0.1.0"), false)
    t.contains(env.output(), "passt nicht zum Verzeichnis: core/version.lua")
  end },
  { "Fehler beim Schreiben wird durch Zurueckles erkannt", function()
    local fs, http, env = world({ fs = { corrupt = function(path, text)
      if path:find("core/adler.lua", 1, true) then return text:sub(1, -2) end
      return text
    end } })
    t.eq(run(env, "zentrale", "v0.1.0"), false)
    t.contains(env.output(), "Pruefung nach dem Schreiben fehlgeschlagen: core/adler.lua")
    t.ok(not fs.exists("/crn") and not fs.exists("/crn_new"))
  end },
  { "ohne HTTP eine klare Meldung", function()
    local fs, http, env = world()
    env.http = nil
    t.eq(run(env, "zentrale", "v0.1.0", "--yes"), false)
    t.contains(env.output(), "HTTP ist auf diesem Computer nicht verfuegbar")
    t.ok(not fs.exists("/crn"))
  end },
  { "Verzeichnis nicht erreichbar", function()
    local fs, http, env = world()
    t.eq(run(env, "zentrale", "v9.9.9"), false)
    t.contains(env.output(), "Verzeichnis nicht erreichbar")
  end },
  { "unbekannte Rolle nennt die moeglichen", function()
    local fs, http, env = world()
    t.eq(run(env, "lokfuehrer", "v0.1.0"), false)
    t.contains(env.output(), "Moeglich: ")
    t.contains(env.output(), "passagierbahnhof")
  end },
  { "zu wenig Platz", function()
    local fs, http, env = world({ fs = { capacity = 5000 } })
    t.eq(run(env, "zentrale", "v0.1.0"), false)
    t.contains(env.output(), "Zu wenig Platz")
    t.ok(not fs.exists("/crn"))
  end },
  { "bewegliche Version fragt nach, --yes nicht", function()
    local fs, http, env = world({ ref = "develop" })
    t.eq(run(env, "zentrale", "develop"), true, env.output())
    t.eq(env.reads, 1)
    t.contains(env.output(), "beweglicher Zweig")
    local fs2, http2, env2 = world({ ref = "develop" })
    t.eq(run(env2, "zentrale", "develop", "--yes"), true)
    t.eq(env2.reads, 0)
  end },
  { "fremde startup.lua bleibt unveraendert, eigene bleibt", function()
    local fs, http, env = world()
    local fh = fs.open("/startup.lua", "w"); fh.write("print('anderes Programm')"); fh.close()
    run(env, "zentrale", "v0.1.0")
    t.eq(fs.open("/startup.lua", "r").readAll(), "print('anderes Programm')")
    t.contains(env.output(), "gehoert zu einem anderen Programm")
    local fs2, http2, env2 = world()
    run(env2, "zentrale", "v0.1.0")
    local ours = fs2.open("/startup.lua", "r").readAll()
    t.contains(ours, "CRN-STARTUP")
    run(env2, "zentrale", "v0.1.0")
    t.eq(fs2.open("/startup.lua", "r").readAll(), ours)
  end },
  { "Datenspeicher bleibt bei Aktualisierung unberuehrt", function()
    local fs, http, env = world()
    run(env, "zentrale", "v0.1.0")
    local fh = fs.open("/crn_data/zustand.txt", "w"); fh.write("wichtig"); fh.close()
    run(env, "zentrale", "v0.1.0")
    t.eq(fs.open("/crn_data/zustand.txt", "r").readAll(), "wichtig")
  end },
  { "--status und --check", function()
    local fs, http, env = world()
    t.eq(run(env, "--status"), false)
    run(env, "gueterbahnhof", "v0.1.0")
    t.eq(run(env, "--status"), true)
    t.contains(env.output(), "Rolle gueterbahnhof")
    t.eq(run(env, "--check"), true)
    local fh = fs.open("/crn/core/adler.lua", "w"); fh.write("kaputt"); fh.close()
    t.eq(run(env, "--check"), false)
    t.contains(env.output(), "beschaedigt: core/adler.lua")
  end },
  { "Abbruch an jeder Aenderung: danach ist die Installation vollstaendig oder nicht vorhanden (Erstinstallation)", function()
    local n = 1
    local finished = false
    while not finished do
      local fs, http, env = world({ fs = { crash_at = n } })
      local ok = pcall(run, env, "zentrale", "v0.1.0")
      fs._state.crash_at = nil
      if ok then finished = true end
      -- neuer Start: raeumt auf
      local env2 = cc.env(fs, http)
      installer.recover(env2)
      t.ok(not fs.exists("/crn_new") or not fs.exists("/crn"), "Staging neben Installation bei n=" .. n)
      if fs.exists("/crn") then t.eq(installer.check(env2), true, "unvollstaendige Installation bei n=" .. n) end
      -- und eine erneute Installation gelingt immer
      local env3 = cc.env(fs, http)
      t.eq(run(env3, "zentrale", "v0.1.0"), true, "Neuinstallation bei n=" .. n .. ": " .. env3.output())
      t.eq(installer.check(cc.env(fs, http)), true)
      t.ok(not fs.exists("/crn_new") and not fs.exists("/crn_tmp"), "Reste bei n=" .. n)
      n = n + 1
      t.ok(n < 200, "Schleife endet nicht")
    end
    t.ok(n > 10, "es wurden mehrere Abbruchstellen geprueft")
  end },
  { "Abbruch an jeder Aenderung bei Aktualisierung und Rueckkehr: immer eine vollstaendige Version da", function()
    local checked = 0
    for _, action in ipairs({ "update", "rollback" }) do
      local n = 1
      local finished = false
      while not finished do
        local fs, http, env = world()
        run(env, "depot", "v0.1.0")
        w.add_version(http, "v0.1.0", "v0.2.0", "0.2.0")
        -- Aktualisierung: eine Version da, die zweite kommt dazu; Rueckkehr: beide Versionen da (Platz fuer eine dritte Kopie gibt es nicht)
        if action == "rollback" then run(env, "depot", "v0.2.0") end
        fs._state.ops = 0
        fs._state.crash_at = n
        local ok = pcall(function()
          if action == "update" then run(env, "depot", "v0.2.0") else run(env, "--rollback") end
        end)
        fs._state.crash_at = nil
        if ok then finished = true end
        local env2 = cc.env(fs, http)
        installer.recover(env2)
        t.ok(fs.exists("/crn"), action .. ": Installation fehlt bei n=" .. n)
        t.eq(installer.check(env2), true, action .. ": Installation unvollstaendig bei n=" .. n)
        t.ok(not fs.exists("/crn_new") and not fs.exists("/crn_tmp"), action .. ": Reste bei n=" .. n)
        if action == "rollback" then
          t.ok(fs.exists("/crn_prev"), "Rueckkehr: Gegenstand der Rueckkehr ging verloren bei n=" .. n)
          t.ok(fs.exists("/crn_prev/manifest.lua"), "Rueckkehr: Vorversion unvollstaendig bei n=" .. n)
        end
        checked = checked + 1
        n = n + 1
        t.ok(n < 200)
      end
    end
    t.ok(checked > 10)
  end },
}
