--[[
Purpose: The update package as a node checks it: origin proof, role, protocol, schema, migration, space, rollback target and file contents (Pruefplan I-02, I-03, I-09).
Public API: returns table of tests.
]]

local update_package = require("src.shared.update_package")

local KEY = string.rep("ab", 32)
local FILES = { { path = "src/nodes/signal_node.lua", content = "-- signal v2\nreturn {}\n" }, { path = "src/shared/net.lua", content = "-- net v2\nreturn {}\n" } }
local META = { release = "v2", roles = { "signal", "station" }, protocol = 3, schema = 5, min_free_bytes = 1000, rollback_to = "v1" }
local CTX = { role = "signal", protocol = 3, schema = 5, free_bytes = 100000 }

local function contents()
  local out = {}
  for _, file in ipairs(FILES) do out[file.path] = file.content end
  return out
end

local function copy(value)
  if type(value) ~= "table" then return value end
  local out = {}
  for k, v in pairs(value) do out[k] = copy(v) end
  return out
end

return {
  test_a_good_package_passes_every_check = function()
    local package = update_package.build(FILES, META, KEY)
    assert(update_package.verify(package, KEY, CTX, contents()) == true)
  end,

  test_a_changed_field_or_a_wrong_key_breaks_the_origin_proof = function()
    local package = update_package.build(FILES, META, KEY)
    local ok, code = update_package.verify(package, string.rep("cd", 32), CTX)
    assert(not ok and code == "bad_signature")
    for _, change in ipairs({ function(p) p.release = "v3" end, function(p) p.roles = { "*" } end, function(p) p.files[1].sha256 = string.rep("0", 64) end, function(p) p.rollback_to = "v0" end, function(p) p.min_free_bytes = 0 end, function(p) p.protocol = 4 end }) do
      local tampered = copy(package)
      change(tampered)
      local ok2, code2 = update_package.verify(tampered, KEY, CTX)
      assert(not ok2 and code2 == "bad_signature", tostring(code2))
    end
  end,

  test_a_file_that_differs_from_the_list_is_refused = function()
    local package = update_package.build(FILES, META, KEY)
    local got = contents()
    got["src/shared/net.lua"] = "-- net v2 with a change\nreturn {}\n"
    local ok, code, detail = update_package.verify(package, KEY, CTX, got)
    assert(not ok and code == "bad_file" and detail:find("net.lua", 1, true))
    got["src/shared/net.lua"] = nil
    assert(select(2, update_package.verify(package, KEY, CTX, got)) == "bad_file")
  end,

  test_role_protocol_and_rollback_target_are_checked = function()
    local package = update_package.build(FILES, META, KEY)
    assert(select(2, update_package.verify(package, KEY, { role = "depot" })) == "wrong_role")
    assert(select(2, update_package.verify(package, KEY, { role = "signal", protocol = 2 })) == "protocol_incompatible")
    local no_back = update_package.build(FILES, { release = "v2", roles = { "*" }, protocol = 3, schema = 5 }, KEY)
    assert(select(2, update_package.verify(no_back, KEY, { role = "anything" })) == "no_rollback")
    assert(update_package.verify(update_package.build(FILES, { release = "v2", roles = { "*" }, rollback_to = "v1" }, KEY), KEY, { role = "anything" }))
  end,

  test_a_schema_change_is_never_applied_automatically = function()
    local plain = update_package.build(FILES, { release = "v2", roles = { "signal" }, protocol = 3, schema = 6, rollback_to = "v1" }, KEY)
    assert(select(2, update_package.verify(plain, KEY, CTX)) == "schema_incompatible")
    local with_plan = update_package.build(FILES, { release = "v2", roles = { "signal" }, protocol = 3, schema = 6, rollback_to = "v1", migration = { steps = "journal v5 -> v6", automatic_safe = true } }, KEY)
    local ok, code = update_package.verify(with_plan, KEY, CTX)
    assert(not ok and code == "migration_required", "even a safe migration waits for a person")
  end,

  test_the_update_does_not_start_without_room_for_staged_copy_and_backup = function()
    local package = update_package.build(FILES, META, KEY)
    local total = #FILES[1].content + #FILES[2].content
    local need = total * 2 + 1000
    assert(update_package.verify(package, KEY, { role = "signal", free_bytes = need }) == true)
    local ok, code = update_package.verify(package, KEY, { role = "signal", free_bytes = need - 1 })
    assert(not ok and code == "no_space")
  end,

  test_junk_is_refused_not_crashed_on = function()
    for _, junk in ipairs({ "x", 5, {}, { format = 2 }, { format = 1, release = "v", roles = {}, files = {}, mac = 5 } }) do
      local ok, code = update_package.verify(junk, KEY, CTX)
      assert(not ok and code == "bad_format")
    end
  end
}
