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
      -- die Leitstelle (rund 500 KB) passt nicht zweimal auf den Computer: war die Installation schon fertig, geht die Wiederholung nur mit --replace
      t.eq(run(env3, "zentrale", "v0.1.0", "--replace"), true, "Neuinstallation bei n=" .. n .. ": " .. env3.output())
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
  -- Grosse Rollen (Leitstelle, rund 470 KB): alte und neue Version passen mit dem Installer (32 KB) und den Daten nicht zugleich auf 1 MB
  { "Leitstelle aktualisieren: passen alt und neu nicht zugleich, steht der Weg (--replace) im Hinweis und nichts wird veraendert", function()
    local fs, http, env = world()
    local fh = fs.open("/installer.lua", "w"); fh.write(string.rep("x", 32061)); fh.close()
    t.eq(run(env, "zentrale", "v0.1.0"), true, env.output())
    local data = fs.open("/crn_data/netz.lua", "w"); data.write(string.rep("d", 20000)); data.close()
    w.add_version(http, "v0.1.0", "v0.2.0", "0.2.0")
    local env2 = cc.env(fs, http)
    t.eq(run(env2, "zentrale", "v0.2.0"), false)
    t.contains(env2.output(), "Zu wenig Platz")
    t.contains(env2.output(), "installer zentrale --replace")
    t.contains(env2.output(), "kein Zurueck zur Vorversion")
    t.contains(fs.open("/crn/manifest.lua", "r").readAll(), '"0.1.0"')
    t.ok(not fs.exists("/crn_new") and not fs.exists("/crn_prev"), "nichts veraendert")
    t.eq(fs.open("/crn_data/netz.lua", "r").readAll(), string.rep("d", 20000))
  end },
  { "--replace ersetzt die bisherige Version, wenn nur so Platz ist: Daten und startup.lua bleiben, keine Vorversion", function()
    local fs, http, env = world()
    local fh = fs.open("/installer.lua", "w"); fh.write(string.rep("x", 32061)); fh.close()
    t.eq(run(env, "zentrale", "v0.1.0"), true, env.output())
    local data = fs.open("/crn_data/netz.lua", "w"); data.write(string.rep("d", 20000)); data.close()
    local startup = fs.open("/startup.lua", "r").readAll()
    w.add_version(http, "v0.1.0", "v0.2.0", "0.2.0")
    local env2 = cc.env(fs, http)
    t.eq(run(env2, "zentrale", "v0.2.0", "--replace"), true, env2.output())
    t.contains(env2.output(), "Die bisherige Version wurde entfernt")
    t.contains(fs.open("/crn/manifest.lua", "r").readAll(), '"0.2.0"')
    t.ok(not fs.exists("/crn_prev"), "keine Vorversion (kein Platz dafuer)")
    t.ok(not fs.exists("/crn_new") and not fs.exists("/crn_tmp"))
    t.eq(fs.open("/crn_data/netz.lua", "r").readAll(), string.rep("d", 20000), "Daten bleiben")
    t.eq(fs.open("/startup.lua", "r").readAll(), startup)
    t.eq(installer.check(cc.env(fs, http)), true)
  end },
  { "--replace ohne Platzmangel aendert nichts am Ablauf: normale Aktualisierung mit Vorversion", function()
    local fs, http, env = world()
    t.eq(run(env, "depot", "v0.1.0"), true, env.output())
    w.add_version(http, "v0.1.0", "v0.2.0", "0.2.0")
    local env2 = cc.env(fs, http)
    t.eq(run(env2, "depot", "v0.2.0", "--replace"), true, env2.output())
    t.ok(fs.exists("/crn_prev/manifest.lua"), "Vorversion bleibt, weil Platz ist")
    t.ok(not env2.output():find("wurde entfernt", 1, true))
  end },
  { "Ersetzen: Abbruch an jeder Dateiaenderung, danach ist die Installation alt, neu oder nicht vorhanden, nie halb; die Daten bleiben und ein neuer Aufruf gelingt", function()
    local n = 1
    local finished = false
    while not finished do
      local fs, http, env = world()
      local fh = fs.open("/installer.lua", "w"); fh.write(string.rep("x", 32061)); fh.close()
      t.eq(run(env, "zentrale", "v0.1.0"), true)
      local data = fs.open("/crn_data/netz.lua", "w"); data.write(string.rep("d", 20000)); data.close()
      w.add_version(http, "v0.1.0", "v0.2.0", "0.2.0")
      fs._state.crash_at = fs._state.ops + n
      local ok = pcall(run, cc.env(fs, http), "zentrale", "v0.2.0", "--replace")
      fs._state.crash_at = nil
      if ok then finished = true end
      local env2 = cc.env(fs, http)
      installer.recover(env2)
      if fs.exists("/crn") then t.eq(installer.check(env2), true, "halbe Installation bei n=" .. n) end
      t.ok(not fs.exists("/crn_new") or not fs.exists("/crn"), "Staging neben Installation bei n=" .. n)
      t.eq(fs.open("/crn_data/netz.lua", "r").readAll(), string.rep("d", 20000), "Daten bei n=" .. n)
      local env3 = cc.env(fs, http)
      t.eq(run(env3, "zentrale", "v0.2.0", "--replace"), true, "Wiederholung bei n=" .. n .. ": " .. env3.output())
      t.eq(installer.check(cc.env(fs, http)), true)
      t.contains(fs.open("/crn/manifest.lua", "r").readAll(), '"0.2.0"')
      n = n + 1
      t.ok(n < 400, "Schleife endet nicht")
    end
    t.ok(n > 10, "es wurden mehrere Abbruchstellen geprueft")
  end },
  { "--replace entfernt zuerst nur die Vorversion, wenn das schon reicht: die bisherige Version bleibt bis zum Austausch", function()
    local fs, http, env = world({ fs = { capacity = 1000000 } })
    t.eq(run(env, "depot", "v0.1.0"), true, env.output())
    w.add_version(http, "v0.1.0", "v0.2.0", "0.2.0")
    t.eq(run(cc.env(fs, http), "depot", "v0.2.0"), true)
    t.ok(fs.exists("/crn_prev/manifest.lua"))
    -- Platz so knapp, dass der Austausch ohne die Vorversion gerade passt
    local ballast = fs.open("/ballast.bin", "w"); ballast.write(string.rep("b", fs.getFreeSpace("/") - (w.need("depot") - 5000))); ballast.close()
    w.add_version(http, "v0.1.0", "v0.3.0", "0.3.0")
    local env3 = cc.env(fs, http)
    t.eq(run(env3, "depot", "v0.3.0", "--replace"), true, env3.output())
    t.contains(env3.output(), "Die Vorversion wurde entfernt")
    t.ok(not env3.output():find("bisherige Version wurde entfernt", 1, true), "die bisherige Version wurde nicht angetastet")
    t.contains(fs.open("/crn/manifest.lua", "r").readAll(), '"0.3.0"')
    t.contains(fs.open("/crn_prev/manifest.lua", "r").readAll(), '"0.2.0"', "die bisherige Version ist jetzt die Vorversion")
  end },
  { "--replace mit Vorversion: reicht das Entfernen der Vorversion nicht, wird auch die bisherige Version ersetzt (Platz = frei + Vorversion + bisherige)", function()
    local fs, http, env = world({ fs = { capacity = 1000000 } })
    t.eq(run(env, "depot", "v0.1.0"), true, env.output())
    w.add_version(http, "v0.1.0", "v0.2.0", "0.2.0")
    t.eq(run(cc.env(fs, http), "depot", "v0.2.0"), true)
    t.ok(fs.exists("/crn_prev/manifest.lua"))
    -- frei bleiben nur wenige Byte: ohne die Vorversion reicht es nicht, ohne beide Versionen schon
    local ballast = fs.open("/ballast.bin", "w"); ballast.write(string.rep("b", fs.getFreeSpace("/") - 5000)); ballast.close()
    w.add_version(http, "v0.1.0", "v0.3.0", "0.3.0")
    local env3 = cc.env(fs, http)
    t.eq(run(env3, "depot", "v0.3.0"), false)
    t.contains(env3.output(), "installer depot --replace")
    t.ok(not env3.output():find("--drop-prev", 1, true), "die Vorversion allein genuegt nicht: kein Hinweis darauf")
    local env4 = cc.env(fs, http)
    t.eq(run(env4, "depot", "v0.3.0", "--replace"), true, env4.output())
    t.contains(env4.output(), "bisherige Version wurde entfernt")
    t.contains(fs.open("/crn/manifest.lua", "r").readAll(), '"0.3.0"')
    t.ok(not fs.exists("/crn_prev"))
  end },
  { "Ersetzen: schlaegt der Download fehl, sagt der Installer, dass CRN nicht mehr installiert ist und wie es weitergeht", function()
    local fs, http, env = world({ fs = { capacity = 800000 } })          -- zwei Staende der Leitstelle passen nicht zugleich
    local fh = fs.open("/installer.lua", "w"); fh.write(string.rep("x", 32061)); fh.close()
    t.eq(run(env, "zentrale", "v0.1.0"), true, env.output())
    w.add_version(http, "v0.1.0", "v0.2.0", "0.2.0")
    local manifest = dofile("dist/manifest.lua")
    http.routes[BASE .. "v0.2.0/dist/" .. manifest.roles.zentrale[5]] = nil          -- eine Datei fehlt auf dem Server
    local env2 = cc.env(fs, http)
    t.eq(run(env2, "zentrale", "v0.2.0", "--replace"), false)
    t.contains(env2.output(), "Download fehlgeschlagen")
    t.contains(env2.output(), "CRN ist jetzt nicht installiert")
    t.contains(env2.output(), "installer zentrale")
    t.ok(not env2.output():find("Es wurde nichts veraendert", 1, true), "nicht behaupten, es sei nichts veraendert")
    t.ok(not fs.exists("/crn"), "die bisherige Version ist weg, die neue unvollstaendig wurde nicht eingesetzt")
    t.ok(fs.isDir("/crn_data"))
  end },
  { "Ersetzen hilft nicht, wenn der Platz auch ohne die bisherige Version nicht reicht: nichts wird geloescht", function()
    local fs, http, env = world({ fs = { capacity = 600000 } })
    t.eq(run(env, "depot", "v0.1.0"), true, env.output())
    local filler = fs.open("/ballast.bin", "w"); filler.write(string.rep("b", fs.getFreeSpace("/") - 5000)); filler.close()
    w.add_version(http, "v0.1.0", "v0.2.0", "0.2.0")
    local env2 = cc.env(fs, http)
    t.eq(run(env2, "depot", "v0.2.0", "--replace"), false)
    t.contains(env2.output(), "Zu wenig Platz")
    t.contains(env2.output(), "Auch ohne die bisherige Version reicht der Platz nicht")
    t.contains(fs.open("/crn/manifest.lua", "r").readAll(), '"0.1.0"', "die bisherige Version ist noch da")
  end },
  { "Dialog: passt die Aktualisierung nur durch Ersetzen, gibt es die Wahl 'Bisherige Version ersetzen'", function()
    local fs, http, env = world({ ref = "main" })
    local fh = fs.open("/installer.lua", "w"); fh.write(string.rep("x", 32061)); fh.close()
    t.eq(run(env, "zentrale"), true, env.output())
    local data = fs.open("/crn_data/netz.lua", "w"); data.write(string.rep("d", 20000)); data.close()
    w.bump(http, "main", "0.2.0")
    local env2 = cc.env(fs, http)
    env2.answers = { "1", "1", "e", "n" }       -- Menue: aktualisieren, Rolle zentrale, ersetzen, nicht starten
    t.eq(installer.wizard(env2), true, env2.output())
    t.contains(env2.output(), "Bisherige Version ersetzen")
    t.contains(fs.open("/crn/manifest.lua", "r").readAll(), '"0.2.0"')
    t.ok(not fs.exists("/crn_prev"))
    t.eq(fs.open("/crn_data/netz.lua", "r").readAll(), string.rep("d", 20000))
  end },
}
