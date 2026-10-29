--[[
Purpose: Welche Dateien zu welchem Modul gehoeren und welche Module eine Rolle bekommt. Eine Anwendung fuer alle Rollen (Konzept 15.1); beim Installieren waehlt die Rolle die Module (Ergaenzung E6).
Notes: Pfade sind relativ zu src/. Jede Datei unter src/ muss in genau einem Modul stehen (tests/test_build.lua prueft das).
]]

return {
  modules = {
    core = { "core/version.lua", "core/adler.lua", "core/ser.lua", "core/store.lua", "core/journal.lua", "core/clock.lua", "core/ticker.lua", "core/msg.lua", "core/net.lua", "core/envcheck.lua", "core/dataformat.lua" },
    dev = { "dev/detect.lua", "dev/station.lua", "dev/signal.lua", "dev/observer.lua", "dev/out.lua", "dev/events.lua", "dev/bind.lua" },
    ui = { "ui/palette.lua", "ui/canvas.lua", "ui/layout.lua", "ui/touch.lua", "ui/keymap.lua", "ui/widgets.lua", "ui/forms.lua", "ui/view.lua" },
    setup = { "setup/model.lua", "setup/wizard.lua", "setup/page.lua" },
    domain = { "domain/schedule.lua", "domain/register.lua" },
    domain_leitstelle = { "domain/orders.lua", "domain/stations.lua", "domain/lines.lua" },
    domain_knoten = { "domain/areas.lua" },
    rolle_bahnhof = { "roles/station.lua", "roles/anmeldung.lua" },
    rolle_leitstelle = { "roles/zentrale.lua" },
    rolle_signal = { "roles/signal.lua" },
    rolle_knoten = { "roles/knoten.lua" },
    app = { "app/main.lua", "app/selftest.lua", "app/node.lua" },
  },
  -- Rollen nach Konzept Kapitel 4: jede Rolle bekommt nur die Module, die sie braucht (Ergaenzung E6). Die Leitstelle kann zusaetzlich Bahnhof und Anmeldung tragen.
  roles = {
    zentrale = { "core", "dev", "ui", "setup", "domain", "domain_leitstelle", "rolle_leitstelle", "rolle_bahnhof", "app" },
    passagierbahnhof = { "core", "dev", "ui", "setup", "domain", "rolle_bahnhof", "app" },
    gueterbahnhof = { "core", "dev", "ui", "setup", "domain", "rolle_bahnhof", "app" },
    depot = { "core", "dev", "ui", "setup", "domain", "rolle_bahnhof", "app" },
    signal = { "core", "dev", "ui", "setup", "domain", "rolle_signal", "app" },
    knoten = { "core", "dev", "ui", "setup", "domain", "domain_knoten", "rolle_signal", "rolle_knoten", "app" },
    anmeldung = { "core", "dev", "ui", "setup", "domain", "rolle_bahnhof", "app" },
  },
}
