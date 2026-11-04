--[[
Purpose: Beschreibt die Form gespeicherter Dateien (welche Felder mit welchem Typ), unabhaengig von den Werten: Zeilen der Art "Datei Pfad.im.Inhalt Typ", Zahlen in Schluesseln als #, Listenelemente als []. Damit haelt tests/test_integrator.lua fest, wann sich ein Dateiformat aendert.
API: shape.lines(name, wert) -> Liste von Zeilen (sortiert, ohne Doppelte)
]]

local M = {}

local function key_text(k)
  if type(k) == "number" then return "[]" end
  return (tostring(k):gsub("%d+", "#"))
end

function M.lines(name, value)
  local seen, out = {}, {}
  local function add(line)
    if not seen[line] then seen[line] = true; out[#out + 1] = line end
  end
  local function walk(v, path)
    if type(v) ~= "table" then add(name .. " " .. path .. " " .. type(v)); return end
    if next(v) == nil then add(name .. " " .. path .. " leer"); return end
    for k, child in pairs(v) do
      walk(child, path == "" and key_text(k) or (path .. "." .. key_text(k)))
    end
  end
  walk(value, "")
  table.sort(out)
  return out
end

return M
