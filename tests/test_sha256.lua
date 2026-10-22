--[[
Purpose: SHA-256 and HMAC-SHA-256 must give the published test results on every bit-operation backend (Gesamtkonzept Kap. 12, risk R-05).
Public API: returns table of tests.
Notes: vectors are FIPS 180-4 (SHA-256) and RFC 4231 (HMAC-SHA-256). All backends available on the interpreter are checked against each other.
]]

pcall(dofile, "tests/harness/cc_bootstrap.lua")

local sha256 = require("src.shared.sha256")

local function hexbytes(hex) return (hex:gsub("%x%x", function(h) return string.char(tonumber(h, 16)) end)) end

local function on_every_backend(fn)
  local original = sha256.backend()
  for _, name in ipairs(sha256.available()) do
    assert(sha256.use(name))
    local ok, err = pcall(fn, name)
    assert(ok, "backend " .. name .. ": " .. tostring(err))
  end
  sha256.use(original)
end

local SHA_VECTORS = {
  { "", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" },
  { "abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" },
  { "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq", "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1" },
  { "abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu",
    "cf5b16a778af8380036ce59e7b0492370b249b11e8f07a51afac45037afee9d1" }
}

return {
  test_sha256_published_vectors = function()
    on_every_backend(function()
      for _, vector in ipairs(SHA_VECTORS) do
        assert(sha256.hex(vector[1]) == vector[2], "wrong digest for '" .. vector[1]:sub(1, 12) .. "'")
      end
    end)
  end,

  test_sha256_block_boundaries_agree_across_backends = function()
    -- lengths around the 55/56/63/64 byte padding edges, compared between all backends
    local names = sha256.available()
    local original = sha256.backend()
    local reference = {}
    assert(sha256.use(names[#names]))
    for length = 0, 130 do reference[length] = sha256.hex(string.rep("x", length)) end
    for _, name in ipairs(names) do
      assert(sha256.use(name))
      for length = 0, 130 do
        assert(sha256.hex(string.rep("x", length)) == reference[length], name .. " differs at length " .. length)
      end
    end
    sha256.use(original)
  end,

  test_sha256_a_million_a_on_the_fast_backend = function()
    local original = sha256.backend()
    local fast = sha256.available()[1]
    if fast == "arith" then return end -- too slow for the plain-arithmetic fallback; the vectors above cover it
    assert(sha256.use(fast))
    assert(sha256.hex(string.rep("a", 1000000)) == "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
    sha256.use(original)
  end,

  test_hmac_rfc4231_vectors = function()
    on_every_backend(function()
      -- test case 1
      assert(sha256.hmac_hex(string.rep("\11", 20), "Hi There") == "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7")
      -- test case 2
      assert(sha256.hmac_hex("Jefe", "what do ya want for nothing?") == "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843")
      -- test case 3
      assert(sha256.hmac_hex(string.rep("\170", 20), string.rep("\221", 50)) == "773ea91e36800e46854db8ebd09181a72959098b3ef8c122d9635514ced565fe")
      -- test case 4
      assert(sha256.hmac_hex(hexbytes("0102030405060708090a0b0c0d0e0f10111213141516171819"), string.rep("\205", 50))
        == "82558a389a443c0ea4cc819899f2083a85f0faa3e578f8077a2e3ff46729665b")
      -- test case 6: key longer than the block size
      assert(sha256.hmac_hex(string.rep("\170", 131), "Test Using Larger Than Block-Size Key - Hash Key First")
        == "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54")
      -- test case 7: long key and long data
      assert(sha256.hmac_hex(string.rep("\170", 131),
        "This is a test using a larger than block-size key and a larger than block-size data. The key needs to be hashed before being used by the HMAC algorithm.")
        == "9b09ffa71b942fcb27635fbcd5b0e944bfdc63644f0713938a7f51535c3a35e2")
    end)
  end,

  test_hmac_differs_with_key_and_text = function()
    local base = sha256.hmac_hex("key", "text")
    assert(base ~= sha256.hmac_hex("kex", "text"))
    assert(base ~= sha256.hmac_hex("key", "texu"))
    assert(base ~= sha256.hmac_hex("key", "text "))
    assert(#base == 64)
  end,

  test_equal_compares_everything = function()
    assert(sha256.equal("abcd", "abcd"))
    assert(not sha256.equal("abcd", "abce"))
    assert(not sha256.equal("abcd", "abc"))
    assert(not sha256.equal("abcd", nil))
    assert(not sha256.equal(1, 1))
    assert(sha256.equal("", ""))
  end,

  -- CC:Tweaked has bit32 and no native operators: the bit32 backend is checked here through a fake bit32 made from the operators of this interpreter
  test_bit32_backend_matches = function()
    local loader = loadstring or load
    local maker = loader([[
      return {
        band = function(a, b) return a & b end, bxor = function(a, b) return a ~ b end, bnot = function(a) return ~a & 0xffffffff end,
        rrotate = function(a, n) return ((a >> n) | (a << (32 - n))) & 0xffffffff end, rshift = function(a, n) return a >> n end
      }]])
    if not maker then return end -- Lua 5.1 / LuaJIT: no operators to build it from, and CC's own bit32 is what the game uses
    local saved_bit32, saved_module = rawget(_G, "bit32"), package.loaded["src.shared.sha256"]
    rawset(_G, "bit32", maker())
    package.loaded["src.shared.sha256"] = nil
    local fresh = require("src.shared.sha256")
    rawset(_G, "bit32", saved_bit32)
    package.loaded["src.shared.sha256"] = saved_module
    assert(fresh.backend() == "bit32", "bit32 is the first choice when it exists, got " .. tostring(fresh.backend()))
    assert(fresh.hex("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    assert(fresh.hmac_hex("Jefe", "what do ya want for nothing?") == "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843")
  end
}
