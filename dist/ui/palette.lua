





local M = {}

M.SLOT = {
hintergrund = 1, arbeit = 2, navigation = 3, trenner = 4, gedaempft = 5, text = 6, hell = 7, haupt = 8,
auswahl = 9, ok = 10, achtung = 11, halt = 12, zeile = 13, kopf = 14, wartend = 15, hell2 = 16,
}

M.RGB = {
[1] = { 0.06, 0.07, 0.09 },
[2] = { 0.10, 0.12, 0.15 },
[3] = { 0.13, 0.16, 0.22 },
[4] = { 0.22, 0.25, 0.30 },
[5] = { 0.55, 0.58, 0.63 },
[6] = { 0.85, 0.87, 0.90 },
[7] = { 1.00, 1.00, 1.00 },
[8] = { 0.15, 0.40, 0.85 },
[9] = { 0.35, 0.60, 1.00 },
[10] = { 0.20, 0.72, 0.35 },
[11] = { 0.95, 0.55, 0.15 },
[12] = { 0.88, 0.22, 0.22 },
[13] = { 0.18, 0.30, 0.50 },
[14] = { 0.05, 0.06, 0.08 },
[15] = { 0.95, 0.80, 0.20 },
[16] = { 0.75, 0.85, 1.00 },
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
