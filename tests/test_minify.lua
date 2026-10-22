--[[
Purpose: The minifier that makes the installed files fit a CC:Tweaked computer (fixed 1 000 000 bytes) changes nothing but comments and white space.
Public API: returns table of tests.
Notes: the proof is the token list: the minified text of every installed Lua file has exactly the tokens of its source, and the same number of lines
  (a message "file.lua:123" of the game still points at line 123 of the repository).
]]

pcall(dofile, "tests/harness/cc_bootstrap.lua")

local minify = require("src.tools.minify")
local manifest_builder = require("src.tools.manifest_builder")
local json = require("src.shared.json")

local function read(path)
  local fh = io.open(path, "rb")
  if not fh then return nil end
  local body = fh:read("*a")
  fh:close()
  return body
end

local function lines_of(text) local _, n = text:gsub("\n", "") return n end

local function same_tokens(a, b)
  local ta, tb = assert(minify.tokens(a)), assert(minify.tokens(b))
  if #ta ~= #tb then return false, "token count " .. #ta .. " vs " .. #tb end
  for i = 1, #ta do
    if ta[i] ~= tb[i] then return false, "token " .. i .. ": " .. ta[i] .. " vs " .. tb[i] end
  end
  return true
end

local function compiles(text)
  local fn, err = (loadstring or load)(text, "=minified")
  return fn ~= nil, err
end

return {
  test_comments_and_blanks_go_but_lines_stay = function()
    local src = table.concat({
      "-- header",
      "local a = 1   -- trailing",
      "--[[ long",
      "comment ]]",
      "",
      "    local b = a + 2",
      "return b",
      "",
    }, "\n")
    local out = assert(minify.minify(src))
    assert(lines_of(out) == lines_of(src), out)
    assert(out == "\nlocal a=1\n\n\n\nlocal b=a+2\nreturn b\n", ("%q"):format(out))
    assert(same_tokens(src, out))
  end,

  test_strings_are_copied_as_they_are = function()
    local src = 'local s = "a  --  b"\nlocal t = \'x   y\'\nlocal u = [[ two   spaces\n  and -- no comment ]]\nlocal v = [==[ ]] ]==]\nreturn s, t, u, v\n'
    local out = assert(minify.minify(src))
    assert(out:find('"a  --  b"', 1, true) and out:find("'x   y'", 1, true) and out:find(" two   spaces\n  and -- no comment ", 1, true) and out:find("[==[ ]] ]==]", 1, true), out)
    assert(lines_of(out) == lines_of(src))
    assert(same_tokens(src, out))
    assert(compiles(out))
  end,

  test_neighbours_that_would_grow_together_keep_their_space = function()
    local src = "local a = 1\nlocal b = - -a\nlocal c = a - -b\nlocal d = 1 .. 2\nlocal e = a .. b\nlocal f = not a\nlocal g = a and b or c\nlocal h = {a, b}\nreturn a-b, a - b, 3 - 1, d, e, f, g, h\n"
    local out = assert(minify.minify(src))
    assert(same_tokens(src, out), out)
    assert(compiles(out), out)
    assert(not out:find("%-%-"), "two minus signs would start a comment: " .. out)
    assert(not out:find("1%.%.2"), out)
  end,

  test_names_and_dots_without_white_space_stay_tight = function()
    local out = assert(minify.minify("local t = a.b.c:d(e)\nreturn t.x[1]\n"))
    assert(out == "local t=a.b.c:d(e)\nreturn t.x[1]\n", out)
  end,

  test_a_broken_source_is_refused = function()
    assert(minify.minify('local s = "open') == nil)
    assert(minify.minify("--[[ never closed") == nil)
    assert(minify.minify("local s = [[ never closed") == nil)
  end,

  test_every_installed_lua_file_keeps_its_tokens_and_its_lines = function()
    local runtime_manifest = json.decode(read("configs/install/runtime_manifest.json"))
    local manifest = assert(manifest_builder.build(read, runtime_manifest))
    local checked = 0
    for path in pairs(manifest.files) do
      if path:match("%.lua$") then
        local src = read(path)
        local out = manifest_builder.shipped(path, src)
        local same, why = same_tokens(src, out)
        assert(same, path .. ": " .. tostring(why))
        assert(lines_of(out) == lines_of(src), path .. ": line count changed")
        local loads, err = compiles(out)
        assert(loads, path .. ": " .. tostring(err))
        checked = checked + 1
      end
    end
    assert(checked > 100, "only " .. checked .. " files checked")
  end,

  test_start_scripts_stay_readable_because_operators_edit_them = function()
    local src = "-- edit me\nlocal x = 1\n"
    assert(manifest_builder.shipped("scripts/start_master.lua", src) == src)
    assert(manifest_builder.shipped("src/shared/x.lua", src) ~= src)
    assert(manifest_builder.shipped("configs/templates/a.json", "{ }") == "{ }")
  end,
}
