--[[
Purpose: Der Installationsdialog (installer ohne Argumente): Menue, Version, Rolle, Zusammenfassung, Zurueck, Abbrechen, falsche Eingaben, Platzmangel, Rueckkehr zur Vorversion. Die Antworten haengen am jeweiligen Bildschirm, nicht an der Reihenfolge.
]]

local t = dofile("tests/lib/t.lua")
local cc = dofile("tests/fakes/cc.lua")
local w = dofile("tests/lib/world.lua")

_G.__CRN_TEST = true
local installer = dofile("installer.lua")

-- rules = { { "Text auf dem Bildschirm", { "Antwort 1", "Antwort 2", ... } }, ... }: jede Regel hat ihre eigene Antwortliste
local function script(env, rules)
  env.responder = function(screen)
    for _, rule in ipairs(rules) do
      if screen:find(rule[1], 1, true) then
        if #rule[2] == 0 then error("Regel '" .. rule[1] .. "' hat keine Antwort mehr; Bildschirm:\n" .. screen, 0) end
        return table.remove(rule[2], 1)
      end
    end
    error("keine Regel fuer den Bildschirm:\n" .. screen, 0)
  end
end

local function dialog(env, rules)
  script(env, rules)
  local result = installer.run({}, env)
  for _, rule in ipairs(rules) do
    if #rule[2] > 0 then error("Antworten nicht verbraucht bei '" .. rule[1] .. "': " .. table.concat(rule[2], ", ") .. "\nAusgabe:\n" .. env.output(), 0) end
  end
  return result
end

local MENU = "Was moechten Sie tun?"

return {
  { "Neuinstallation: Menue, Version eingeben, Rolle, Zusammenfassung, starten", function()
    local fs, http, env = w.world()
    local ok = dialog(env, {
      { MENU, { "1" } },
      { "Welche Version soll", { "e" } },
      { "Version eingeben (z", { "v0.1.0" } },
      { "Welche Rolle", { "3" } },
      { "Zusammenfassung", { "j" } },
      { "Jetzt starten?", { "j" } },
    })
    t.eq(ok, true, env.output())
    local out = env.output()
    t.contains(out, "Noch nichts installiert.")
    t.not_contains(out, "Installation pruefen", "ohne Installation gibt es nichts zu pruefen")
    t.not_contains(out, "Zur Vorversion", "keine Rueckkehr ohne Vorversion")
    t.contains(out, "Rolle:    gueterbahnhof")
    t.contains(out, "Bisher:   neue Installation")
    t.contains(out, "startup:  wird angelegt")
    t.contains(out, "Installiert: Version 0.1.0")
    t.eq(env.started, 1, "Programm wurde gestartet")
    t.eq(installer.check(cc.env(fs, http)), true)
    t.contains(fs.open("/crn/install.lua", "r").readAll(), 'role = "gueterbahnhof"')
    t.ok((env.cleared or 0) > 0, "Bildschirm wird zwischen den Schritten geleert")
  end },
  { "Rollenliste zeigt Beschreibungen und alle sieben Rollen", function()
    local fs, http, env = w.world()
    dialog(env, {
      { MENU, { "1" } },
      { "Welche Version soll", { "e" } },
      { "Version eingeben (z", { "v0.1.0" } },
      { "Welche Rolle", { "q" } },
    })
    local out = env.output()
    for _, text in ipairs({ "zentrale", "passagierbahnhof", "gueterbahnhof", "depot", "signal", "knoten", "anmeldung", "Leitstelle fuer das ganze Netz", "Bahnhof fuer Fracht" }) do
      t.contains(out, text)
    end
    t.ok(not fs.exists("/crn"), "Abbruch aendert nichts")
  end },
  { "zurueck und wieder vor, Abbruch im Menue", function()
    local fs, http, env = w.world({ ref = "main" })
    local ok = dialog(env, {
      { MENU, { "1", "q" } },
      { "Welche Version soll", { "m", "z" } },
      { "Welche Rolle", { "z" } },
    })
    t.eq(ok, false)
    t.contains(env.output(), "Beendet. Es wurde nichts veraendert.")
    t.ok(not fs.exists("/crn"))
  end },
  { "falsche Eingaben werden abgewiesen und neu abgefragt", function()
    local fs, http, env = w.world()
    local ok = dialog(env, {
      { MENU, { "x" } },
      { "Bitte eine der angegebenen", { "7", "9", "1" } },
      { "Welche Version soll", { "e" } },
      { "Version eingeben (z", { "a b", "../x", "v0.1.0" } },
      { "Welche Rolle", { "1" } },
      { "Zusammenfassung", { "j" } },
      { "Jetzt starten?", { "n" } },
    })
    t.eq(ok, true, env.output())
    t.contains(env.output(), "Bitte eine der angegebenen Eingaben waehlen.")
    t.contains(env.output(), "Ungueltig. Erlaubt sind")
    t.eq(env.started, 0, "Nein startet nicht")
  end },
  { "Version nicht erreichbar: Meldung, zurueck zur Versionswahl", function()
    local fs, http, env = w.world()
    local ok = dialog(env, {
      { MENU, { "1" } },
      { "Welche Version soll", { "e", "q" } },
      { "Version eingeben (z", { "v9.9.9" } },
    })
    t.eq(ok, false)
    t.contains(env.output(), "Verzeichnis nicht erreichbar")
    local first = env.output():find("Verzeichnis nicht erreichbar", 1, true)
    local second = env.output():find("Welche Version soll", first, true)
    t.ok(second, "danach wird die Version erneut abgefragt")
  end },
  { "bewegliche Version wird im Dialog angezeigt und ist in der Zusammenfassung sichtbar", function()
    local fs, http, env = w.world({ ref = "main" })
    dialog(env, {
      { MENU, { "1" } },
      { "Welche Version soll", { "m" } },
      { "Welche Rolle", { "2" } },
      { "Zusammenfassung", { "q" } },
    })
    t.contains(env.output(), "beweglicher Zweig")
    t.contains(env.output(), "von main")
    t.ok(not fs.exists("/crn"))
  end },
  { "Zusammenfassung: zurueck installiert nichts", function()
    local fs, http, env = w.world()
    dialog(env, {
      { MENU, { "1" } },
      { "Welche Version soll", { "e" } },
      { "Version eingeben (z", { "v0.1.0" } },
      { "Welche Rolle", { "1", "q" } },
      { "Zusammenfassung", { "z" } },
    })
    t.ok(not fs.exists("/crn") and not fs.exists("/crn_new"), "z darf nichts installieren")
    t.eq(#http.requests, 1, "nur das Verzeichnis wurde geladen")
  end },
  { "Zusammenfassung: zurueck zur Rolle, dann installieren", function()
    local fs, http, env = w.world()
    local ok = dialog(env, {
      { MENU, { "1" } },
      { "Welche Version soll", { "e" } },
      { "Version eingeben (z", { "v0.1.0" } },
      { "Welche Rolle", { "1", "5" } },
      { "Zusammenfassung", { "z", "j" } },
      { "Jetzt starten?", { "n" } },
    })
    t.eq(ok, true, env.output())
    t.contains(fs.open("/crn/install.lua", "r").readAll(), 'role = "signal"')
  end },
  { "fremde startup.lua und Rollenwechsel stehen vor dem Installieren in der Zusammenfassung", function()
    local fs, http, env = w.world()
    t.eq(installer.run({ "depot", "v0.1.0", "--yes" }, env), true)
    fs.delete("/startup.lua")
    local fh = fs.open("/startup.lua", "w"); fh.write("print('fremd')"); fh.close()
    local env2 = cc.env(fs, http)
    dialog(env2, {
      { MENU, { "1" } },
      { "Welche Version soll", { "1" } },
      { "Welche Rolle", { "5" } },
      { "Zusammenfassung", { "q" } },
    })
    local out = env2.output()
    t.contains(out, "bleibt unveraendert (gehoert zu einem anderen Programm)")
    t.contains(out, "die Rolle wechselt von depot zu signal")
    t.contains(out, "wird zur Vorversion")
    t.contains(out, "(bisher)")
    t.eq(fs.open("/startup.lua", "r").readAll(), "print('fremd')")
  end },
  { "Platzmangel: Vorversion loeschen anbieten, danach installieren", function()
    local fs, http, env = w.world({ fs = { capacity = 2 * w.need("depot") + 11000 } })
    t.eq(installer.run({ "depot", "v0.1.0", "--yes" }, env), true, env.output())
    t.eq(installer.run({ "depot", "v0.1.0", "--yes" }, env), true, env.output())
    t.ok(fs.exists("/crn_prev"))
    local env2 = cc.env(fs, http)
    local ok = dialog(env2, {
      { MENU, { "1" } },
      { "Welche Version soll", { "1" } },
      { "Welche Rolle", { "4" } },
      { "Zu wenig Platz", { "d" } },
      { "Zusammenfassung", { "j" } },
      { "Jetzt starten?", { "n" } },
    })
    t.eq(ok, true, env2.output())
    t.contains(env2.output(), "Vorversion loeschen und Platz schaffen")
    t.eq(installer.check(cc.env(fs, http)), true)
  end },
  { "Platzmangel ohne Vorversion: nur zurueck oder abbrechen", function()
    local fs, http, env = w.world({ fs = { capacity = 5000 } })
    dialog(env, {
      { MENU, { "1" } },
      { "Welche Version soll", { "e" } },
      { "Version eingeben (z", { "v0.1.0" } },
      { "Welche Rolle", { "1" } },
      { "Zu wenig Platz", { "q" } },
    })
    t.contains(env.output(), "Zu wenig Platz")
    t.not_contains(env.output(), "Jetzt installieren")
    t.not_contains(env.output(), "Vorversion loeschen")
    t.ok(not fs.exists("/crn"))
  end },
  { "Menue: pruefen und zur Vorversion zurueckkehren", function()
    local fs, http, env = w.world()
    t.eq(installer.run({ "depot", "v0.1.0", "--yes" }, env), true)
    w.add_version(http, "v0.1.0", "v0.2.0", "0.2.0")
    t.eq(installer.run({ "depot", "v0.2.0", "--yes" }, env), true, env.output())
    local env2 = cc.env(fs, http)
    dialog(env2, {
      { MENU, { "2", "3", "q" } },
      { "Weiter mit der Eingabetaste", { "", "" } },
      { "Wirklich zur Vorversion", { "j" } },
    })
    local out = env2.output()
    t.contains(out, "Installiert: Version 0.2.0, Rolle depot")
    t.contains(out, "Alle Dateien stimmen mit dem Verzeichnis ueberein.")
    t.contains(out, "Zurueck bei Version 0.1.0.")
    t.contains(fs.open("/crn/manifest.lua", "r").readAll(), '"0.1.0"')
  end },
  { "Rueckkehr im Dialog kann verneint werden", function()
    local fs, http, env = w.world()
    installer.run({ "depot", "v0.1.0", "--yes" }, env)
    w.add_version(http, "v0.1.0", "v0.2.0", "0.2.0")
    installer.run({ "depot", "v0.2.0", "--yes" }, env)
    local env2 = cc.env(fs, http)
    dialog(env2, {
      { MENU, { "3", "q" } },
      { "Wirklich zur Vorversion", { "n" } },
      { "Weiter mit der Eingabetaste", { "" } },
    })
    t.contains(fs.open("/crn/manifest.lua", "r").readAll(), '"0.2.0"')
  end },
  { "Eingabeende bricht sauber ab", function()
    local fs, http, env = w.world()
    env.responder = function() return nil end
    t.eq(installer.run({}, env), false)
    t.contains(env.output(), "Beendet. Es wurde nichts veraendert.")
    local fs2, http2, env2 = w.world()
    local answers = { "1", "e" }
    env2.responder = function() return table.remove(answers, 1) end
    t.eq(installer.run({}, env2), false)
    t.ok(not fs2.exists("/crn"))
  end },
  { "Fehler beim Laden im Dialog: Meldung, nichts veraendert", function()
    local fs, http, env = w.world({ tweak = function(routes, ref) routes[w.BASE .. ref .. "/dist/core/adler.lua"] = nil end })
    local ok = dialog(env, {
      { MENU, { "1" } },
      { "Welche Version soll", { "e" } },
      { "Version eingeben (z", { "v0.1.0" } },
      { "Welche Rolle", { "1" } },
      { "Zusammenfassung", { "j" } },
      { "Weiter mit der Eingabetaste", { "" } },
    })
    t.eq(ok, false)
    t.contains(env.output(), "Download fehlgeschlagen: core/adler.lua")
    t.contains(env.output(), "Es wurde nichts veraendert.")
    t.ok(not fs.exists("/crn") and not fs.exists("/crn_new"))
  end },
  { "ohne HTTP meldet der Dialog es bei der Versionswahl", function()
    local fs, http, env = w.world()
    env.http = nil
    dialog(env, {
      { MENU, { "1" } },
      { "Welche Version soll", { "m", "q" } },
    })
    t.contains(env.output(), "HTTP ist auf diesem Computer nicht verfuegbar")
  end },
  { "--help und ungueltige Version auf der Kommandozeile", function()
    local fs, http, env = w.world()
    t.eq(installer.run({ "--help" }, env), true)
    t.contains(env.output(), "Dialog: alles nach und nach auswaehlen")
    local env2 = cc.env(fs, http)
    t.eq(installer.run({ "depot", "../geheim" }, env2), false)
    t.contains(env2.output(), "Ungueltige Version")
    t.eq(#http.requests, 0, "es wurde nichts abgerufen")
  end },
}
