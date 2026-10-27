--[[
Purpose: Die 16 Palettenplaetze der Oberflaeche (Konzept 29.5) mit festen Namen und Farbwerten. Platz k entspricht der CC-Farbe 2^(k-1) und dem Hex-Zeichen k-1 fuer blit; die Farbwerte werden pro Ausgabegeraet mit setPaletteColour gesetzt. Farbe allein traegt keine Bedeutung: jeder Zustand steht auch als Text.
API: palette.SLOT (Name -> Platz), palette.RGB (Platz -> {r,g,b} 0..1), palette.apply(target) -> true wenn gesetzt, palette.hex(slot), palette.colour(slot)
Notes: Auf Geraeten ohne Farbe (Computer, Monitor ohne isColour) wird nichts gesetzt; dort zeichnet die Oberflaeche in Schwarz/Weiss und behaelt Texte und Auswahlmarkierungen.
]]

local M = {}

M.SLOT = {
  hintergrund = 1, arbeit = 2, navigation = 3, trenner = 4, gedaempft = 5, text = 6, hell = 7, haupt = 8,
  auswahl = 9, ok = 10, achtung = 11, halt = 12, zeile = 13, kopf = 14, wartend = 15, hell2 = 16,
}

M.RGB = {
  [1] = { 0.06, 0.07, 0.09 },   -- Hintergrund
  [2] = { 0.10, 0.12, 0.15 },   -- Arbeitsflaeche
  [3] = { 0.13, 0.16, 0.22 },   -- Navigation
  [4] = { 0.22, 0.25, 0.30 },   -- Trennflaechen
  [5] = { 0.55, 0.58, 0.63 },   -- gedaempfter Text
  [6] = { 0.85, 0.87, 0.90 },   -- normaler Text
  [7] = { 1.00, 1.00, 1.00 },   -- heller Text
  [8] = { 0.15, 0.40, 0.85 },   -- Hauptaktion (blau)
  [9] = { 0.35, 0.60, 1.00 },   -- Auswahlakzent
  [10] = { 0.20, 0.72, 0.35 },  -- bestaetigt positiv (gruen)
  [11] = { 0.95, 0.55, 0.15 },  -- Aufmerksamkeit (orange)
  [12] = { 0.88, 0.22, 0.22 },  -- Halt / Stoerung (rot)
  [13] = { 0.18, 0.30, 0.50 },  -- ausgewaehlte Zeile
  [14] = { 0.05, 0.06, 0.08 },  -- dunkle Kopfzeile
  [15] = { 0.95, 0.80, 0.20 },  -- wartend (gelb)
  [16] = { 0.75, 0.85, 1.00 },  -- ergaenzender heller Text
}

local HEX = "0123456789abcdef"

function M.hex(slot) return HEX:sub(slot, slot) end
function M.colour(slot) return 2 ^ (slot - 1) end

function M.apply(target)
  local colour = target.isColour or target.isColor
  if not colour or not colour() then return false end
  if not target.setPaletteColour then return false end
  for slot = 1, 16 do
    local rgb = M.RGB[slot]
    pcall(target.setPaletteColour, M.colour(slot), rgb[1], rgb[2], rgb[3])
  end
  return true
end

return M
