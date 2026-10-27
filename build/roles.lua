--[[
Purpose: Welche Dateien zu welchem Modul gehoeren und welche Module eine Rolle bekommt. Eine Anwendung fuer alle Rollen (Konzept 15.1); beim Installieren waehlt die Rolle die Module (Ergaenzung E6).
Notes: Pfade sind relativ zu src/. Jede Datei unter src/ muss in genau einem Modul stehen (tests/test_build.lua prueft das).
]]

return {
  modules = {
    core = { "core/version.lua", "core/adler.lua", "core/ser.lua", "core/store.lua", "core/journal.lua", "core/clock.lua", "core/ticker.lua", "core/msg.lua", "core/net.lua" },
    dev = { "dev/detect.lua", "dev/station.lua", "dev/signal.lua", "dev/observer.lua", "dev/out.lua", "dev/events.lua", "dev/bind.lua" },
    ui = { "ui/palette.lua", "ui/canvas.lua", "ui/layout.lua", "ui/touch.lua", "ui/keymap.lua", "ui/widgets.lua", "ui/view.lua" },
    setup = { "setup/model.lua", "setup/wizard.lua", "setup/page.lua" },
    app = { "app/main.lua", "app/selftest.lua", "app/node.lua" },
  },
  -- Rollen nach Konzept Kapitel 4; in Stufe 0 haben alle dieselben Module
  roles = {
    zentrale = { "core", "dev", "ui", "setup", "app" },
    passagierbahnhof = { "core", "dev", "ui", "setup", "app" },
    gueterbahnhof = { "core", "dev", "ui", "setup", "app" },
    depot = { "core", "dev", "ui", "setup", "app" },
    signal = { "core", "dev", "ui", "setup", "app" },
    knoten = { "core", "dev", "ui", "setup", "app" },
    anmeldung = { "core", "dev", "ui", "setup", "app" },
  },
}
