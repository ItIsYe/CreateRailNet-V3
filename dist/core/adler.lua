--[[
Purpose: Adler-32 Pruefsumme ueber einen String. Erkennt abgebrochene oder beschaedigte Downloads, ist aber kein Schutz gegen Manipulation (das Konzept 1.1 verlangt keine Kryptografie).
API: adler.sum(text) -> Zahl; adler.hex(text) -> 8 Zeichen Hex
Notes: Dieselbe Rechnung steht eingebettet in installer.lua (eine einzelne Datei muss ohne die Anwendung laufen); tests/test_adler.lua prueft beide gegen dieselben Werte.
]]

local M = {}

local MOD = 65521
local BLOCK = 256

function M.sum(text)
  local a, b = 1, 0
  local n = #text
  local i = 1
  while i <= n do
    local j = i + BLOCK - 1
    if j > n then j = n end
    local bytes = { string.byte(text, i, j) }
    for k = 1, #bytes do
      a = a + bytes[k]
      b = b + a
    end
    a = a % MOD
    b = b % MOD
    i = j + 1
  end
  return b * 65536 + a
end

function M.hex(text)
  return string.format("%08x", M.sum(text))
end

return M
