--[[
Purpose: The canonical text form that message authentication codes are made over must be the same for the same value everywhere and differ for different values.
Public API: returns table of tests.
]]

pcall(dofile, "tests/harness/cc_bootstrap.lua")

local canon = require("src.shared.canon")

return {
  test_same_content_gives_the_same_text_whatever_the_construction_order = function()
    local a = { x = 1, y = { 3, 2, 1 }, z = "text", flag = true }
    local b = {}
    b.flag = true; b.z = "text"; b.y = { 3, 2, 1 }; b.x = 1
    assert(canon.encode(a) == canon.encode(b))
    local many_a, many_b = {}, {}
    for i = 1, 60 do many_a["k" .. i] = i end
    for i = 60, 1, -1 do many_b["k" .. i] = i end
    assert(canon.encode(many_a) == canon.encode(many_b))
  end,

  test_different_content_gives_different_text = function()
    local seen = {}
    local values = {
      {}, { 1 }, { 1, 2 }, { "1" }, { 1.5 }, { true }, { false }, { x = 1 }, { x = "1" }, { y = 1 }, { { 1 } }, { { {} } }, "a", "ab", 1, 2, true, false,
      { "a", "b" }, { "ab" }, { "a" , "b", "c" }, { a = { b = 1 } }, { a = { c = 1 } }, { [1] = "a", [3] = "b" }, "", { "" }, { "", "" }
    }
    for i, value in ipairs(values) do
      local text = assert(canon.encode(value))
      assert(not seen[text], "values " .. tostring(seen[text]) .. " and " .. i .. " give the same text")
      seen[text] = i
    end
  end,

  test_strings_cannot_pretend_to_be_structure = function()
    -- the length prefix keeps "a" .. "b" from being read as another split of the same characters
    assert(canon.encode({ "ab", "c" }) ~= canon.encode({ "a", "bc" }))
    assert(canon.encode({ x = "1;d2;" }) ~= canon.encode({ x = 1, y = 2 }))
    assert(canon.encode("s1:a") ~= canon.encode("a"))
  end,

  test_integer_and_float_forms_of_one_number_are_the_same_text = function()
    assert(canon.encode(5) == canon.encode(5.0))
    assert(canon.encode({ n = 1000000000000 }) == canon.encode({ n = 1e12 }))
    assert(canon.encode(0.1) ~= canon.encode(0.2))
  end,

  test_numbers_that_cannot_be_written_down_are_errors = function()
    assert(canon.encode(0 / 0) == nil)
    assert(canon.encode(math.huge) == nil)
    assert(canon.encode(-math.huge) == nil)
  end,

  test_cycles_functions_and_wrong_keys_are_errors = function()
    local loop = {}
    loop.self = loop
    local text, err = canon.encode(loop)
    assert(text == nil and err == "cycle")
    assert(canon.encode({ f = function() end }) == nil)
    assert(canon.encode({ [true] = 1 }) == nil)
    assert(canon.encode({ [{}] = 1 }) == nil)
  end,

  test_a_value_that_is_shared_but_not_cyclic_is_fine = function()
    local shared = { 1, 2 }
    assert(canon.encode({ a = shared, b = shared }))
  end,

  test_nesting_and_size_are_limited = function()
    local deep = {}
    local cursor = deep
    for _ = 1, 40 do cursor.next = {}; cursor = cursor.next end
    local text, err = canon.encode(deep)
    assert(text == nil and err == "nested too deep")
    local wide = {}
    for i = 1, 25000 do wide[i] = i end
    text, err = canon.encode(wide)
    assert(text == nil and err == "too many values")
  end
}
