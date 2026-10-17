--[[
Purpose: The startup.lua written by the setup wizard parses, runs the OTA recovery first and survives odd ids.
Public API: returns table of tests.
]]

pcall(dofile, "tests/harness/cc_bootstrap.lua")

local template = require("src.shared.startup_template")

local function compile(text)
  local loader = loadstring or load
  return loader(text, "=startup")
end

local function read_all(path)
  local fh = io.open(path, "r")
  local body = fh:read("*a")
  fh:close()
  return body
end

return {
  test_every_role_renders_a_file_that_parses = function()
    for _, role in ipairs(template.ROLES) do
      local text = assert(template.render({ role = role, id = role:upper() .. "-1", config = "configs/network.json" }))
      local chunk, err = compile(text)
      assert(chunk, role .. ": " .. tostring(err))
    end
  end,

  test_the_ota_recovery_runs_before_the_role_is_loaded = function()
    local text = template.render({ role = "signal", id = "SIG-1", config = "configs/network.json" })
    local recovery_at = text:find("src.shared.ota_recovery", 1, true)
    local entry_at = text:find("require(entrypoint)", 1, true)
    assert(recovery_at and entry_at and recovery_at < entry_at, "recovery has to come first")
  end,

  test_generated_and_repository_startup_share_the_recovery_block = function()
    local generated = template.render({ role = "master", id = "MASTER-1", config = "x.json" })
    local repo = read_all("startup.lua")
    for _, needle in ipairs({ 'pcall(require, "src.shared.ota_recovery")', "pcall(recovery.recover)", 'print("OTA recovery: "' }) do
      assert(generated:find(needle, 1, true), "generated file lacks: " .. needle)
      assert(repo:find(needle, 1, true), "startup.lua lacks: " .. needle)
    end
  end,

  test_ids_are_restricted_and_quoted = function()
    local bad, err = template.render({ role = "signal", id = 'SIG"1', config = "x.json" })
    assert(bad == nil and err:find("node id"))
    assert(template.render({ role = "signal", id = "SIG 1", config = "x.json" }) == nil)
    local text = assert(template.render({ role = "signal", id = "SIG-1", config = 'configs/we"ird.json' }))
    assert(compile(text), "a quote in the config path must not break the file")
  end,

  test_unknown_role_and_missing_config_are_refused = function()
    assert(template.render({ role = "toaster", id = "T-1", config = "x.json" }) == nil)
    assert(template.render({ role = "signal", id = "S-1" }) == nil)
  end
}
