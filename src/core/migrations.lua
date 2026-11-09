--[[
Purpose: Liste der Anpassungsschritte fuer gespeicherte Daten (Integrator): jeder Schritt bringt die Dateien in /crn_data von Format N auf N+1, damit Datenstaende aelterer Programmversionen im neueren Programm weiter benutzbar sind. core/dataformat.lua fuehrt die Schritte aus, nachdem es alles gesichert hat.
API: migrations.STEPS (Liste: STEPS[n] = { text = "was der Schritt aendert", run = function(ctx) ... end }); migrations.FORMAT (= 1 + Anzahl der Schritte); migrations.validate(steps) -> nil | Fehlertext
Notes: Regel (siehe docs/DATENFORMAT.md): Wer die Form einer gespeicherten Datei nicht nur ergaenzt (Feld umbenennen, Bedeutung aendern, Pflichtfeld einfuehren, Datei verschieben), haengt hier einen Schritt an. tests/test_integrator.lua haelt die Form der Dateien fest und scheitert, wenn sich die Form aendert, ohne dass hier ein Schritt steht oder die Festlegung bewusst erneuert wurde. ctx = { load(name), save(name, wert), update(name, fn), exists(name), files(), fs, store } mit Namen relativ zu /crn_data (auch "nodesich/N0001.lua"; die Sicherungen der Leitstelle gehoeren mit angepasst). Ein Schritt arbeitet nur auf Daten und ruft keinen anderen Programmteil auf (er muss auch in Jahren noch dasselbe tun). Fehler oder Rueckgabe false, Grund: alles wird zurueckgenommen. Zusaetzliche Felder, die das Programm selbst mit einer Vorgabe ergaenzt, brauchen keinen Schritt.
]]

local M = {}

-- Ein Schritt darf `scope = { Dateinamen }` nennen: die Dateien, die er aendert oder loescht; nur sie werden vor dem Schritt gesichert.
-- Bis Format 1 haben alle Aenderungen der Dateiformen nur Felder ergaenzt, die das Programm beim Laden mit einer Vorgabe fuellt
-- (siehe tests/fixtures/alte_staende.lua: Staende dreier aelterer Programmversionen laufen unveraendert weiter).
M.STEPS = {
  -- 1 -> 2: Es gibt keinen "Entwurf" der Einrichtung mehr. Ein gespeicherter Entwurf (config.lua ohne Status "aktiv") haette die neue Einrichtung nach dem Update
  -- mit altem Namen, alter Kennung und halben Gleisen blockiert: er wird verworfen (die Sicherung des Integrators behaelt ihn). Zwei Angaben daraus bleiben nutzbar:
  -- die Anforderungskennung (damit die Node im Verzeichnis dieselbe Kennung behaelt statt eine zweite anzulegen) und eine stehengebliebene Testsperre-Marke
  -- (damit ein eigenes Testsignal, das beim Absturz gesperrt blieb, trotzdem freigegeben wird).
  [1] = {
    text = "Entwurf der Einrichtung verwerfen",
    scope = { "config.lua" },          -- nur diese Datei wird geaendert oder geloescht; die Sicherung braucht nur sie (die Daten der Leitstelle koennen gross sein)
    run = function(ctx)
      local c = ctx.load("config.lua")
      if type(c) ~= "table" then return end
      local lauf = type(c.pruefung) == "table" and c.pruefung.lauf or nil
      local d = lauf and type(c.devices) == "table" and c.devices[lauf.device] or nil
      if d and d.kind == "signal" and type(d.device) == "string" and not ctx.exists("pruefmarke.lua") then
        ctx.save("pruefmarke.lua", { device = lauf.device, name = d.device, t = tonumber(lauf.t) or 0 })
      end
      if c.status == "aktiv" then
        -- eine laufende Node behaelt ihre Einrichtung; die Marke wandert in ihre eigene Datei
        if lauf then
          c.pruefung.lauf = nil
          ctx.save("config.lua", c)
        end
        return
      end
      local claim = type(c.node) == "table" and c.node.claim or nil
      if type(claim) == "string" and #claim >= 8 and #claim <= 64 and not claim:find("[^%w%-_]") and not ctx.exists("anforderung.lua") then
        ctx.save("anforderung.lua", { claim = claim })
      end
      ctx.delete("config.lua")
    end,
  },
  -- 2 -> 3: Die Abfahrt wird ueber den Fahrplan der Train Station freigegeben (docs/FREIGABE_PER_FAHRPLAN.md), nicht mehr ueber einen Redstone-Ausgang. Ein
  -- gespeicherter Freigabeausgang am Gleis (tracks.*.release) wird nicht mehr gelesen und faellt weg; im Zustand des Bahnhofs (station.lua) bleiben die
  -- Felder der Freigabe, sie bedeuten jetzt "Abschnittsfahrplan gesetzt". Eine Freigabe, die beim Update offen war, gehoert dem Zug von damals: sie gilt als verbraucht.
  [2] = {
    text = "Freigabeausgang der Gleise entfernen (Freigabe laeuft ueber den Fahrplan)",
    scope = { "config.lua", "station.lua" },
    run = function(ctx)
      local c = ctx.load("config.lua")
      if type(c) == "table" and type(c.tracks) == "table" then
        local changed = false
        for _, track in pairs(c.tracks) do
          if type(track) == "table" and track.release ~= nil then track.release, changed = nil, true end
        end
        if changed then ctx.save("config.lua", c) end
      end
      local s = ctx.load("station.lua")
      if type(s) == "table" and type(s.tracks) == "table" then
        local changed = false
        for _, tr in pairs(s.tracks) do
          if type(tr) == "table" and tr.release_set == true then
            tr.release_set, tr.release_train, tr.release_stay, tr.release_order = false, nil, nil, nil
            changed = true
          end
        end
        if changed then ctx.save("station.lua", s) end
      end
    end,
  },
  -- 3 -> 4: Create regelt die Strecke (Signale, Bloecke, Weichen, Kreuzungen) allein; CC:Tweaked orchestriert nur noch. Die Rollen "signal" und "knoten" gibt es nicht
  -- mehr. Eine Node, die nur diese Rollen trug, hat keine Aufgabe mehr: ihre Einrichtung wird verworfen (die Sicherung des Integrators behaelt sie) und der Computer
  -- kann neu eingerichtet werden. Traegt eine Node daneben eine Bahnhofs- oder Anmelde-Rolle, bleibt diese; Signale, Knotenanschluesse und das Knotenmodell der
  -- Einrichtung fallen weg, ebenso die Marke einer Testsperre (pruefmarke.lua) und die Daten der Signal- und Knotenrolle.
  [3] = {
    text = "Rollen Signal und Knoten entfernen (Create regelt die Strecke)",
    scope = { "config.lua", "signal.lua", "knoten.lua", "pruefmarke.lua" },
    run = function(ctx)
      for _, name in ipairs({ "signal.lua", "knoten.lua", "pruefmarke.lua" }) do
        if ctx.exists(name) then ctx.delete(name) end
      end
      local c = ctx.load("config.lua")
      if type(c) ~= "table" or type(c.node) ~= "table" or type(c.node.roles) ~= "table" then return end
      local kept, removed = {}, false
      for _, role in ipairs(c.node.roles) do
        if role == "signal" or role == "knoten" then removed = true else kept[#kept + 1] = role end
      end
      if not removed then return end
      if #kept == 0 then
        ctx.delete("config.lua")
        return
      end
      c.node.roles = kept
      c.junction, c.node.junction, c.node.junction_rev = nil, nil, nil
      for id, d in pairs(type(c.devices) == "table" and c.devices or {}) do
        if type(d) == "table" and d.kind == "signal" then c.devices[id] = nil end
      end
      for _, track in pairs(type(c.tracks) == "table" and c.tracks or {}) do
        if type(track) == "table" then track.signals, track.junction, track.order_ok = nil, nil, nil end
      end
      c.tests = {}
      ctx.save("config.lua", c)
    end,
  },
  -- 4 -> 5: Passagierbahnhof, Gueterbahnhof und Depot sind eine Rolle (Bahnhof); sie unterschieden sich nur im Namen. Dazu fallen Beobachter und Gleisrichtung weg
  -- (nichts wertete sie aus). Betroffen ist nur config.lua; das Verzeichnis der Leitstelle (netz.lua) stellt sich beim Laden selbst um.
  [4] = {
    text = "Bahnhofsrollen zusammenfassen, Beobachter und Gleisrichtung entfernen",
    scope = { "config.lua" },
    run = function(ctx)
      local c = ctx.load("config.lua")
      if type(c) ~= "table" or type(c.node) ~= "table" then return end
      local changed = false
      if type(c.node.roles) == "table" then
        local legacy = { passagierbahnhof = true, gueterbahnhof = true, depot = true }
        local out, seen = {}, {}
        for _, role in ipairs(c.node.roles) do
          if legacy[role] then role = "bahnhof" end
          if not seen[role] then seen[role] = true; out[#out + 1] = role end
        end
        if table.concat(out, ",") ~= table.concat(c.node.roles, ",") then c.node.roles, changed = out, true end
      end
      for id, d in pairs(type(c.devices) == "table" and c.devices or {}) do
        if type(d) == "table" and d.kind == "observer" then c.devices[id], changed = nil, true end
      end
      for _, track in pairs(type(c.tracks) == "table" and c.tracks or {}) do
        if type(track) == "table" and (track.observers ~= nil or track.direction ~= nil) then track.observers, track.direction, changed = nil, nil, true end
      end
      if changed then ctx.save("config.lua", c) end
    end,
  },
  -- 5 -> 6: Betriebsstellen (BF0001) und Standorte gibt es nicht mehr; eine Anmeldung nennt den Bahnhof mit seinem Namen. Die gespeicherte Betriebsstellen-Kennung
  -- in der Einrichtung einer Anmeldung (node.station) faellt weg (der Name der Node nennt den Bahnhof weiterhin). Das Verzeichnis der Leitstelle (netz.lua) stellt sich
  -- beim Laden selbst um.
  [5] = {
    text = "Betriebsstellen-Kennung der Anmeldung entfernen",
    scope = { "config.lua" },
    run = function(ctx)
      local c = ctx.load("config.lua")
      if type(c) ~= "table" or type(c.node) ~= "table" then return end
      if type(c.node.station) == "string" and c.node.station:match("^BF%d+$") then
        c.node.station = nil
        ctx.save("config.lua", c)
      end
    end,
  },
}

-- liefert nil, wenn die Schritte lueckenlos von 1 an numeriert sind und je Text und Funktion haben, sonst den Grund
function M.validate(steps)
  local count = 0
  for key in pairs(steps) do
    if type(key) ~= "number" then return "Schluessel " .. tostring(key) .. " ist keine Nummer" end
    count = count + 1
  end
  for i = 1, count do
    local step = steps[i]
    if step == nil then return "Schritt " .. i .. " fehlt (Luecke in der Nummerierung)" end
    local run = type(step) == "function" and step or (type(step) == "table" and step.run)
    if type(run) ~= "function" then return "Schritt " .. i .. " hat keine Funktion" end
  end
  return nil
end

M.FORMAT = 1 + #M.STEPS

return M
