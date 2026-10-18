--[[
Purpose: Adler-32 checksum in plain arithmetic (Lua 5.1 has no bit operators).
Public API: adler32(text, tick) -> integer, hex(value) -> 8 character string.
Notes: tick() is called every 8 KB when given; the installer yields there so a big file cannot trip the watchdog of a loaded server.
Notes: Detects truncated or damaged transfers and file writes. It is not a signature and does not stop tampering.
]]

local checksum = {}

local MOD = 65521
local BLOCK = 4096

function checksum.adler32(text, tick)
  local a, b = 1, 0
  local length = #text
  local position = 1
  while position <= length do
    local last = position + BLOCK - 1
    if last > length then last = length end
    local bytes = { string.byte(text, position, last) }
    for i = 1, #bytes do
      a = a + bytes[i]
      b = b + a
    end
    -- 4096 bytes keep a and b far below 2^53, so reducing once per block is exact
    a = a % MOD
    b = b % MOD
    position = last + 1
    if tick and (position - 1) % (BLOCK * 2) == 0 then tick() end
  end
  return b * 65536 + a
end

function checksum.hex(value)
  return string.format("%08x", value)
end

return checksum
