--[[
Purpose: Adler-32 in src/core/adler.lua und die eingebettete Kopie in installer.lua liefern bekannte Werte und stimmen ueberein.
]]

local t = dofile("tests/lib/t.lua")
local adler = require("core.adler")
local installer = dofile("installer.lua")

local vectors = {
  { "", "00000001" },
  { "a", "00620062" },
  { "abc", "024d0127" },
  { "Wikipedia", "11e60398" },
}

return {
  { "bekannte Werte", function()
    for _, v in ipairs(vectors) do t.eq(adler.hex(v[1]), v[2], "adler " .. v[1]) end
  end },
  { "Installer-Kopie stimmt ueberein", function()
    for _, v in ipairs(vectors) do t.eq(installer.adler_hex(v[1]), v[2], "installer " .. v[1]) end
    local long = string.rep("CRN-Pruefsumme ", 5000) .. string.char(0, 255, 128)
    t.eq(installer.adler_hex(long), adler.hex(long))
  end },
  { "lange Eingabe ueber Blockgrenzen", function()
    local text = string.rep(string.char(255), 100000)
    t.eq(adler.hex(text), installer.adler_hex(text))
    t.eq(adler.sum(text) % 65536, (1 + 255 * 100000) % 65521)
  end },
}
