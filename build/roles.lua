--[[
Purpose: Welche Dateien zu welchem Modul gehoeren und welche Module eine Rolle bekommt. Eine Anwendung fuer alle Rollen (Konzept 15.1); beim Installieren waehlt die Rolle die Module (Ergaenzung E6).
Notes: Pfade sind relativ zu src/. Jede Datei unter src/ muss in genau einem Modul stehen (tests/test_build.lua prueft das).
]]

return {
  modules = {
    core = { "core/version.lua", "core/adler.lua", "core/ser.lua", "core/store.lua", "core/journal.lua", "core/clock.lua", "core/ticker.lua", "core/msg.lua", "core/net.lua", "core/chunks.lua", "core/envcheck.lua", "core/label.lua", "core/migrations.lua", "core/dataformat.lua", "core/updater.lua" },
    dev = { "dev/detect.lua", "dev/station.lua", "dev/observer.lua", "dev/events.lua", "dev/bind.lua" },
    ui = { "ui/palette.lua", "ui/canvas.lua", "ui/layout.lua", "ui/touch.lua", "ui/keymap.lua", "ui/widgets.lua", "ui/forms.lua", "ui/view.lua" },
    setup = { "setup/model.lua", "setup/wizard.lua", "setup/page.lua" },
    domain = { "domain/schedule.lua", "domain/register.lua" },
    domain_leitstelle = { "domain/orders.lua", "domain/stations.lua", "domain/lines.lua", "domain/netz.lua" },
    rolle_bahnhof = { "roles/station.lua", "roles/anmeldung.lua" },
    rolle_leitstelle = { "roles/zentrale.lua", "roles/leitstelle/zuege.lua", "roles/leitstelle/auftraege.lua", "roles/leitstelle/netz.lua", "roles/leitstelle/vorlagen.lua", "roles/leitstelle/bahnhoefe.lua", "roles/leitstelle/linien.lua", "roles/leitstelle/depot.lua", "roles/leitstelle/stoerungen.lua" },
    app = { "app/main.lua", "app/selftest.lua", "app/node.lua" },
  },
  -- Rollen nach Konzept Kapitel 4: jede Rolle bekommt nur die Module, die sie braucht (Ergaenzung E6). Die Leitstelle kann zusaetzlich Bahnhof und Anmeldung tragen.
  roles = {
    zentrale = { "core", "dev", "ui", "setup", "domain", "domain_leitstelle", "rolle_leitstelle", "rolle_bahnhof", "app" },
    bahnhof = { "core", "dev", "ui", "setup", "domain", "rolle_bahnhof", "app" },
    -- Aliase: bis zur Zusammenlegung hiessen die Pakete so; vorhandene Computer tragen den Namen und aktualisieren sich weiter (das Auswahlmenue des Installers zeigt sie nicht)
    passagierbahnhof = { "core", "dev", "ui", "setup", "domain", "rolle_bahnhof", "app" },
    gueterbahnhof = { "core", "dev", "ui", "setup", "domain", "rolle_bahnhof", "app" },
    depot = { "core", "dev", "ui", "setup", "domain", "rolle_bahnhof", "app" },
    anmeldung = { "core", "dev", "ui", "setup", "domain", "rolle_bahnhof", "app" },
  },
}
