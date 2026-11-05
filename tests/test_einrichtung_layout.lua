--[[
Purpose: Lesbarkeit des Einrichtungsassistenten: alle Ablauftests der Einrichtung (Bahnhof, Signal, Knoten, Anmeldung, Kombinationen, Ersatz, Von Hand, Bereich anlegen, Gleise und Signale) laufen noch einmal unter dem Fuehler tests/lib/sensor.lua. Auf keinem Einrichtungsbild darf Text abgeschnitten, uebermalt oder verdeckt sein, und keine Tasten duerfen sich ueberlappen. Dazu der Aufbau der Tasten: Navigation immer in der untersten Zeile (Zurueck, Weiter links, Abbrechen rechts), die Tasten des Bildschirms eine freie Zeile darueber, der Hinweis hat zwei Zeilen.
]]

local t = dofile("tests/lib/t.lua")
local sensor = dofile("tests/lib/sensor.lua")
local drv = dofile("tests/lib/ui_driver.lua")
local create = dofile("tests/fakes/create.lua")

-- Ablauftests, die den Assistenten Bild fuer Bild durchlaufen
local MODULES = {
  "test_einrichtung_bahnhof", "test_einrichtung_gefuehrt", "test_einrichtung_knoten", "test_einrichtung_kombi", "test_einrichtung_rolle",
  "test_signal_eigenschaften", "test_knoten_einfahrt", "test_bereich_anlegen", "test_uebernahme_alt", "test_ohne_entwurf",
  "test_setup_gates", "test_node", "test_stage8", "test_vorlaeufige_kennung", "test_ersatz_liste", "test_abgleich_knoten_uebernehmen",
  "test_detail_weiter",
}

-- ein Einrichtungsbild erkennt man an der Schrittleiste (kompakt) oder der Seitenleiste (gross)
local function is_wizard_frame(rows)
  local second = rows[2] or ""
  if second:match("%[[1-6] %a+%]") then return true end
  for _, row in ipairs(rows) do if row:find("DEINE EINRICHTUNG", 1, true) then return true end end
  return false
end

return {
  { "Einrichtungsbilder in allen Ablauftests: nichts abgeschnitten, uebermalt oder verdeckt, keine ueberlappenden Tasten", function()
    local found = sensor.collect(function()
      for _, name in ipairs(MODULES) do
        local ok, list = pcall(dofile, "tests/" .. name .. ".lua")
        if ok and type(list) == "table" then
          for _, case in ipairs(list) do pcall(case[2]) end          -- ob die Ablaufpruefung selbst besteht, entscheidet ihre eigene Datei
        end
      end
    end, is_wizard_frame)
    if #found > 0 then
      local lines = {}
      for i = 1, math.min(#found, 6) do
        lines[#lines + 1] = found[i].kind .. ": " .. found[i].detail .. "\n" .. found[i].screen
      end
      error(#found .. " Auffaelligkeiten in Einrichtungsbildern:\n" .. table.concat(lines, "\n---\n"), 0)
    end
  end },

  { "Tasten: Navigation unten (Zurueck, Weiter links, Abbrechen rechts), Tasten des Bildschirms darueber mit freier Zeile, Hinweis zweizeilig", function()
    local w = create.world()
    w.add_modem("left", true)
    w.add_station("Create_Station_1")
    w.add_station("Create_Station_2")
    local d = drv.new({ world = w })
    d.restart()
    local v = d.view()
    d.tap(v, "nav:einrichtung"); d.tap(v, "act:start")
    d.tap(v, "sel:modus:2"); d.tap(v, "act:weiter")
    d.tap(v, "sel:netzwahl:1"); d.tap(v, "act:weiter")
    d.type(v, "netz", "Testnetz"); d.tap(v, "act:weiter")
    d.type(v, "zentrale", "hauptstelle"); d.tap(v, "act:weiter")
    d.tap_row(v, "rollen", "Passagierbahnhof"); d.tap(v, "act:weiter")
    d.tap(v, "act:von_hand")
    d.type(v, "name", "Hof"); d.tap(v, "act:weiter")
    d.tap_row(v, "geraete", "Create_Station_1"); d.tap(v, "act:weiter")
    local h = 19
    -- Gleisliste: eigene Tasten (Neu, Bearbeiten, Kopieren, Entfernen) und die Navigation
    local zurueck, weiter, abbrechen = d.area(v, "act:zurueck"), d.area(v, "act:weiter"), d.area(v, "act:abbrechen")
    local neu = d.area(v, "act:neues_gleis")
    t.ok(neu, "Gleisliste hat die Taste Neu: " .. d.text(v))
    t.eq(zurueck.y, h - 1, "Navigation in den letzten beiden Zeilen"); t.eq(weiter.y, h - 1); t.eq(abbrechen.y, h - 1)
    t.eq(zurueck.h, 2)
    t.ok(zurueck.x < weiter.x and weiter.x < abbrechen.x, "Reihenfolge Zurueck, Weiter, Abbrechen")
    t.eq(abbrechen.x + abbrechen.w - 1, 50, "Abbrechen steht ganz rechts")
    t.ok(weiter.x + weiter.w < abbrechen.x - 3, "Abbrechen ist von Weiter abgesetzt")
    t.ok(neu.y + neu.h < zurueck.y, "eine freie Zeile zwischen den Tastenreihen")
    t.eq(neu.h, 1)
    for _, id in ipairs({ "act:bearbeiten", "act:kopieren", "act:entfernen" }) do t.eq(d.area(v, id).y, neu.y, id .. " in derselben Reihe") end
    -- die Navigation bleibt auf jedem Bildschirm an derselben Stelle
    d.tap(v, "act:neues_gleis")
    local weiter2 = d.area(v, "act:weiter")
    t.eq(weiter2.y, weiter.y); t.eq(weiter2.x, weiter.x)
    -- Hinweis: lange Texte brechen in die zweite Zeile um und werden nicht mitten im Satz abgeschnitten
    local long = "Das ist ein langer Hinweis, der nicht in eine einzige Zeile passt und deshalb umbrochen wird."
    v.hint = long
    d.node.render()
    local text = d.text(v)
    t.contains(text, "Das ist ein langer Hinweis, der nicht in eine ")
    t.contains(text, "einzige Zeile passt und deshalb umbrochen wird.")
    t.not_contains(text, "~", "nichts abgeschnitten")
    d.tap(v, "act:abbrechen"); d.tap(v, "act:abbrechen")
    t.eq(d.node.config, nil)
  end },

  { "Schrittleiste: alle Schritte als Nummern, der aktuelle mit Namen in Klammern, daneben keine Doppelung mit der Ueberschrift", function()
    local w = create.world()
    w.add_modem("left", true)
    local d = drv.new({ world = w })
    d.restart()
    local v = d.view()
    d.tap(v, "nav:einrichtung"); d.tap(v, "act:start")
    local rows = {}
    for line in (d.text(v) .. "\n"):gmatch("(.-)\n") do rows[#rows + 1] = line end
    t.contains(rows[2], "[1 Netz]")
    t.contains(rows[2], " 2 3 4 5 6")
    t.contains(rows[3], "Netz erstellen oder beitreten")
    t.not_contains(d.text(v), "Schritt 1 von 6")
  end },
}
