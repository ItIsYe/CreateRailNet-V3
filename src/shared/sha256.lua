--[[
Purpose: SHA-256 and HMAC-SHA-256 in plain Lua, for message authentication (Gesamtkonzept Kap. 12).
Public API: digest(text) -> 32 raw bytes, hex(text) -> 64 hex characters, hmac(key, text) -> 32 raw bytes, hmac_hex(key, text) -> hex,
  to_hex(raw), equal(a, b) -> boolean (compares without stopping at the first difference), backend() -> name of the bit operations in use,
  use(name) -> true | false (tests: force "bit32" | "native" | "luajit" | "arith"), available() -> list of names.
Notes: the same code runs on CC:Tweaked (bit32), Lua 5.3+ (native operators, compiled through load so Lua 5.1 never sees them), LuaJIT (bit) and
  plain Lua 5.1 (arithmetic fallback with a byte table; slow, only for tests). Every word is kept as an unsigned number below 2^32, so all
  backends give the same bytes. Test vectors: FIPS 180-4 and RFC 4231 (tests/test_sha256.lua).
  Pure Lua cannot be constant-time or protect a key on a compromised computer (docs/V3_ZIEL.md, risk R-05): this stops forged and replayed
  messages on the wire, not an attacker who owns a computer of the net.
]]

local sha256 = {}

local MOD = 4294967296
local byte, char, format, rep = string.byte, string.char, string.format, string.rep
local floor = math.floor

-- round constants: the first 32 bits of the fractional parts of the cube roots of the first 64 primes (initial hash: square roots of the first 8)
local K, H0 = {}, {}
do
  local primes, n = {}, 2
  while #primes < 64 do
    local prime = true
    for i = 1, #primes do
      if primes[i] * primes[i] > n then break end
      if n % primes[i] == 0 then prime = false; break end
    end
    if prime then primes[#primes + 1] = n end
    n = n + 1
  end
  for i = 1, 64 do
    local root = primes[i] ^ (1 / 3)
    K[i] = floor((root - floor(root)) * MOD)
  end
  for i = 1, 8 do
    local root = primes[i] ^ 0.5
    H0[i] = floor((root - floor(root)) * MOD)
  end
end

local function make(ops)
  local band, bxor, bnot, rrot, rshift = ops.band, ops.bxor, ops.bnot, ops.rrot, ops.rshift

  local function compress(H, text, offset)
    local w = {}
    for i = 0, 15 do
      local a, b, c, d = byte(text, offset + i * 4, offset + i * 4 + 3)
      w[i] = ((a * 256 + b) * 256 + c) * 256 + d
    end
    for i = 16, 63 do
      local w15, w2 = w[i - 15], w[i - 2]
      local s0 = bxor(bxor(rrot(w15, 7), rrot(w15, 18)), rshift(w15, 3))
      local s1 = bxor(bxor(rrot(w2, 17), rrot(w2, 19)), rshift(w2, 10))
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) % MOD
    end
    local a, b, c, d, e, f, g, h = H[1], H[2], H[3], H[4], H[5], H[6], H[7], H[8]
    for i = 0, 63 do
      local S1 = bxor(bxor(rrot(e, 6), rrot(e, 11)), rrot(e, 25))
      local ch = bxor(band(e, f), band(bnot(e), g))
      local t1 = (h + S1 + ch + K[i + 1] + w[i]) % MOD
      local S0 = bxor(bxor(rrot(a, 2), rrot(a, 13)), rrot(a, 22))
      local maj = bxor(bxor(band(a, b), band(a, c)), band(b, c))
      local t2 = (S0 + maj) % MOD
      h = g; g = f; f = e; e = (d + t1) % MOD; d = c; c = b; b = a; a = (t1 + t2) % MOD
    end
    H[1] = (H[1] + a) % MOD; H[2] = (H[2] + b) % MOD; H[3] = (H[3] + c) % MOD; H[4] = (H[4] + d) % MOD
    H[5] = (H[5] + e) % MOD; H[6] = (H[6] + f) % MOD; H[7] = (H[7] + g) % MOD; H[8] = (H[8] + h) % MOD
  end

  local function word_bytes(x)
    return char(floor(x / 16777216) % 256, floor(x / 65536) % 256, floor(x / 256) % 256, x % 256)
  end

  local function digest(text)
    local H = { H0[1], H0[2], H0[3], H0[4], H0[5], H0[6], H0[7], H0[8] }
    local length = #text
    local bits = length * 8
    local padding = (55 - length) % 64
    local padded = text .. "\128" .. rep("\0", padding) .. word_bytes(floor(bits / MOD)) .. word_bytes(bits % MOD)
    for offset = 1, #padded, 64 do compress(H, padded, offset) end
    local out = {}
    for i = 1, 8 do out[i] = word_bytes(H[i]) end
    return table.concat(out)
  end

  local function xor_bytes(text, pad)
    local out = {}
    for i = 1, #text do out[i] = char(bxor(byte(text, i), pad)) end
    return table.concat(out)
  end

  local function hmac(key, text)
    if #key > 64 then key = digest(key) end
    key = key .. rep("\0", 64 - #key)
    return digest(xor_bytes(key, 0x5c) .. digest(xor_bytes(key, 0x36) .. text))
  end

  return { digest = digest, hmac = hmac }
end

-- bit operations on unsigned 32-bit numbers -------------------------------------------------------------------------

local backends = {}

if type(bit32) == "table" and bit32.band then
  backends.bit32 = function()
    return { band = bit32.band, bxor = bit32.bxor, bnot = bit32.bnot, rrot = bit32.rrotate, rshift = bit32.rshift }
  end
end

-- Lua 5.3+: the operators are syntax errors in 5.1 / LuaJIT, so they are compiled from text and simply absent there
do
  local loader = loadstring or load
  local chunk = loader and loader([[
    return {
      band = function(a, b) return a & b end,
      bxor = function(a, b) return a ~ b end,
      bnot = function(a) return ~a & 0xffffffff end,
      rrot = function(a, n) return ((a >> n) | (a << (32 - n))) & 0xffffffff end,
      rshift = function(a, n) return a >> n end
    }]])
  if chunk then
    local ok, ops = pcall(chunk)
    if ok and type(ops) == "table" then backends.native = function() return ops end end
  end
end

if type(bit) == "table" and bit.band and bit.tobit then
  backends.luajit = function()
    local function u(x) if x < 0 then return x + MOD end return x end
    local band, bxor, bnot, rshift, rrot = bit.band, bit.bxor, bit.bnot, bit.rshift, bit.ror
    return {
      band = function(a, b) return u(band(a, b)) end,
      bxor = function(a, b) return u(bxor(a, b)) end,
      bnot = function(a) return u(bnot(a)) end,
      rrot = function(a, n) return u(rrot(a, n)) end,
      rshift = function(a, n) return u(rshift(a, n)) end
    }
  end
end

-- plain arithmetic: exclusive-or through a table of byte pairs; and/not/shifts follow from sums and divisions (exact below 2^53)
backends.arith = function()
  local xor8 = {}
  for a = 0, 255 do
    local row = {}
    for b = 0, 255 do
      local x, y, r, bitval = a, b, 0, 1
      for _ = 1, 8 do
        local xa, yb = x % 2, y % 2
        if xa ~= yb then r = r + bitval end
        x = (x - xa) / 2; y = (y - yb) / 2; bitval = bitval * 2
      end
      row[b] = r
    end
    xor8[a] = row
  end
  local function bxor(a, b)
    local a0, a1, a2, a3 = a % 256, floor(a / 256) % 256, floor(a / 65536) % 256, floor(a / 16777216)
    local b0, b1, b2, b3 = b % 256, floor(b / 256) % 256, floor(b / 65536) % 256, floor(b / 16777216)
    return xor8[a0][b0] + xor8[a1][b1] * 256 + xor8[a2][b2] * 65536 + xor8[a3][b3] * 16777216
  end
  local powers = {}
  for n = 0, 32 do powers[n] = 2 ^ n end
  return {
    bxor = bxor,
    band = function(a, b) return (a + b - bxor(a, b)) / 2 end,
    bnot = function(a) return 4294967295 - a end,
    rrot = function(a, n) return floor(a / powers[n]) + (a % powers[n]) * powers[32 - n] end,
    rshift = function(a, n) return floor(a / powers[n]) end
  }
end

local ORDER = { "bit32", "native", "luajit", "arith" }
local current_name, current

function sha256.available()
  local names = {}
  for _, name in ipairs(ORDER) do if backends[name] then names[#names + 1] = name end end
  return names
end

function sha256.use(name)
  if not backends[name] then return false end
  current = make(backends[name]())
  current_name = name
  return true
end

function sha256.backend() return current_name end

for _, name in ipairs(ORDER) do
  if backends[name] and sha256.use(name) then break end
end

function sha256.digest(text) return current.digest(text) end

function sha256.hmac(key, text) return current.hmac(key, text) end

function sha256.to_hex(raw)
  return (raw:gsub(".", function(c) return format("%02x", byte(c)) end))
end

function sha256.hex(text) return sha256.to_hex(current.digest(text)) end

function sha256.hmac_hex(key, text) return sha256.to_hex(current.hmac(key, text)) end

-- compares two strings completely, whatever the first difference is (a check that stops early tells a forger how many characters were right)
function sha256.equal(a, b)
  if type(a) ~= "string" or type(b) ~= "string" or #a ~= #b then return false end
  local diff = 0
  for i = 1, #a do
    if byte(a, i) ~= byte(b, i) then diff = diff + 1 end
  end
  return diff == 0
end

return sha256
