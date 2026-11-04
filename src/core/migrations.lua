--[[
Purpose: Liste der Anpassungsschritte fuer gespeicherte Daten (Integrator): jeder Schritt bringt die Dateien in /crn_data von Format N auf N+1, damit Datenstaende aelterer Programmversionen im neueren Programm weiter benutzbar sind. core/dataformat.lua fuehrt die Schritte aus, nachdem es alles gesichert hat.
API: migrations.STEPS (Liste: STEPS[n] = { text = "was der Schritt aendert", run = function(ctx) ... end }); migrations.FORMAT (= 1 + Anzahl der Schritte); migrations.validate(steps) -> nil | Fehlertext
Notes: Regel (siehe docs/DATENFORMAT.md): Wer die Form einer gespeicherten Datei nicht nur ergaenzt (Feld umbenennen, Bedeutung aendern, Pflichtfeld einfuehren, Datei verschieben), haengt hier einen Schritt an. tests/test_integrator.lua haelt die Form der Dateien fest und scheitert, wenn sich die Form aendert, ohne dass hier ein Schritt steht oder die Festlegung bewusst erneuert wurde. ctx = { load(name), save(name, wert), update(name, fn), exists(name), files(), fs, store } mit Namen relativ zu /crn_data (auch "nodesich/N0001.lua"; die Sicherungen der Leitstelle gehoeren mit angepasst). Ein Schritt arbeitet nur auf Daten und ruft keinen anderen Programmteil auf (er muss auch in Jahren noch dasselbe tun). Fehler oder Rueckgabe false, Grund: alles wird zurueckgenommen. Zusaetzliche Felder, die das Programm selbst mit einer Vorgabe ergaenzt, brauchen keinen Schritt.
]]

local M = {}

-- Noch kein Schritt noetig: alle bisherigen Aenderungen der Dateiformen haben nur Felder ergaenzt, die das Programm beim Laden mit einer Vorgabe fuellt
-- (siehe tests/fixtures/alte_staende.lua: Staende dreier aelterer Programmversionen laufen unveraendert weiter).
M.STEPS = {}

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
