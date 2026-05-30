--[[
Purpose: Runtime manifest guard tests.
Public API: returns table of tests.
]]

pcall(dofile, "tests/harness/cc_bootstrap.lua")

local json = require("src.shared.json")

local function read(path)
  local fh = assert(io.open(path, "r"))
  local body = fh:read("*a")
  fh:close()
  return body
end

local function has(list, value)
  for _, item in ipairs(list or {}) do if item == value then return true end end
  return false
end

return {
  test_runtime_manifest_excludes_sim_tests_docs = function()
    local manifest = json.decode(read("configs/install/runtime_manifest.json"))
    assert(has(manifest.exclude, "src/sim/**"))
    assert(has(manifest.exclude, "tests/**"))
    assert(has(manifest.exclude, "docs/**"))
    assert(has(manifest.exclude, ".github/**"))
  end,

  test_runtime_manifest_includes_runtime_roots = function()
    local manifest = json.decode(read("configs/install/runtime_manifest.json"))
    assert(has(manifest.include, "src/shared/**"))
    assert(has(manifest.include, "src/domain/**"))
    assert(has(manifest.include, "src/adapter/**"))
    assert(has(manifest.include, "src/master/**"))
    assert(has(manifest.include, "src/nodes/**"))
  end
}
