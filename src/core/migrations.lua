--[[
Purpose: Liste der Anpassungsschritte fuer gespeicherte Daten (Integrator): jeder Schritt bringt die Dateien in /crn_data von Format N auf N+1, damit Datenstaende aelterer Programmversionen im neueren Programm weiter benutzbar sind. core/dataformat.lua fuehrt die Schritte aus, nachdem es alles gesichert hat.
API: migrations.STEPS (Liste: STEPS[n] = { text = "was der Schritt aendert", run = function(ctx) ... end }); migrations.FORMAT (= 1 + Anzahl der Schritte); migrations.validate(steps) -> nil | Fehlertext
Notes: Regel (siehe docs/DATENFORMAT.md): Wer die Form einer gespeicherten Datei nicht nur ergaenzt (Feld umbenennen, Bedeutung aendern, Pflichtfeld einfuehren, Datei verschieben), haengt hier einen Schritt an. tests/test_integrator.lua haelt die Form der Dateien fest und scheitert, wenn sich die Form aendert, ohne dass hier ein Schritt steht oder die Festlegung bewusst erneuert wurde. ctx = { load(name), save(name, wert), update(name, fn), exists(name), files(), fs, store } mit Namen relativ zu /crn_data (auch "nodesich/N0001.lua"; die Sicherungen der Leitstelle gehoeren mit angepasst). Ein Schritt arbeitet nur auf Daten und ruft keinen anderen Programmteil auf (er muss auch in Jahren noch dasselbe tun). Fehler oder Rueckgabe false, Grund: alles wird zurueckgenommen. Zusaetzliche Felder, die das Programm selbst mit einer Vorgabe ergaenzt, brauchen keinen Schritt.
]]

local M = {}

-- Bis Format 1 haben alle Aenderungen der Dateiformen nur Felder ergaenzt, die das Programm beim Laden mit einer Vorgabe fuellt
-- (siehe tests/fixtures/alte_staende.lua: Staende dreier aelterer Programmversionen laufen unveraendert weiter).
M.STEPS = {
  -- 1 -> 2: Es gibt keinen "Entwurf" der Einrichtung mehr. Ein gespeicherter Entwurf (config.lua ohne Status "aktiv") haette die neue Einrichtung nach dem Update
  -- mit altem Namen, alter Kennung und halben Gleisen blockiert: er wird verworfen (die Sicherung des Integrators behaelt ihn). Zwei Angaben daraus bleiben nutzbar:
  -- die Anforderungskennung (damit die Node im Verzeichnis dieselbe Kennung behaelt statt eine zweite anzulegen) und eine stehengebliebene Testsperre-Marke
  -- (damit ein eigenes Testsignal, das beim Absturz gesperrt blieb, trotzdem freigegeben wird).
  [1] = {
    text = "Entwurf der Einrichtung verwerfen",
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
