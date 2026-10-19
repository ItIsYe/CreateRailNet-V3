--[[
Purpose: Which nodes an OTA rollout reaches (scripts/ota_push.lua --role / --limit / --node / --legacy): by role, a few first, never the master,
  and a wrong role or an empty result is an error before anything is sent.
Public API: returns table of tests.
]]

pcall(dofile, "tests/harness/cc_bootstrap.lua")

local ota_targets = require("src.master.ota_targets")

local CFG = {
  master_id = "MASTER-1",
  nodes = {
    { id = "MASTER-1", role = "master" },
    { id = "SIG-B", role = "signal" }, { id = "SIG-A", role = "signal" }, { id = "SIG-C", role = "signal" },
    { id = "SEN-1", role = "sensor" }, { id = "SW-1", role = "switch" },
    { id = "ST-A", role = "station" }, { id = "PANEL-1", role = "panel" },
  },
}

local function join(list) return table.concat(list, ",") end

return {
  test_a_role_selects_its_nodes_sorted = function()
    local list = assert(ota_targets.select(CFG, { role = "signal" }))
    assert(join(list) == "SIG-A,SIG-B,SIG-C", join(list))
  end,

  test_a_limit_takes_the_first_ones_so_a_rollout_can_start_small = function()
    assert(join(assert(ota_targets.select(CFG, { role = "signal", limit = 1 }))) == "SIG-A")
    assert(join(assert(ota_targets.select(CFG, { role = "signal", limit = "2" }))) == "SIG-A,SIG-B")
    assert(join(assert(ota_targets.select(CFG, { role = "signal", limit = 10 }))) == "SIG-A,SIG-B,SIG-C")
    -- without a role: every node but the master
    assert(join(assert(ota_targets.select(CFG, { limit = 3 }))) == "PANEL-1,SEN-1,SIG-A")
  end,

  test_the_master_is_never_a_target = function()
    assert(select(2, ota_targets.select(CFG, { role = "master" })):find("Master", 1, true))
    local all = assert(ota_targets.select(CFG, {}))
    for _, id in ipairs(all) do assert(id ~= "MASTER-1") end
    assert(#all == 7)
  end,

  test_one_node_by_name = function()
    assert(join(assert(ota_targets.select(CFG, { node = "SW-1" }))) == "SW-1")
    -- a node that is not in the plan may still be named (a computer that has not been accepted yet)
    assert(join(assert(ota_targets.select(CFG, { node = "NEW-9" }))) == "NEW-9")
    -- and it is combined with nothing else
    local list, err = ota_targets.select(CFG, { node = "SW-1", role = "signal" })
    assert(list == nil and err:find("--node", 1, true))
  end,

  test_a_wrong_role_or_an_empty_result_or_a_bad_limit_is_an_error_before_anything_is_sent = function()
    local list, err = ota_targets.select(CFG, { role = "signl" })
    assert(list == nil and err:find("signl", 1, true) and err:find("signal", 1, true), tostring(err))
    list, err = ota_targets.select(CFG, { role = "depot" })
    assert(list == nil and err:find("depot", 1, true) and err:find("keinen", 1, true), tostring(err))
    for _, bad in ipairs({ 0, -1, "x", 1.5, "" }) do
      list, err = ota_targets.select(CFG, { role = "signal", limit = bad })
      assert(list == nil and err:find("--limit", 1, true), "limit " .. tostring(bad))
    end
    list, err = ota_targets.select({}, { role = "signal" })
    assert(list == nil, "a config without nodes")
  end,

  test_nodes_without_an_id_or_with_nonsense_are_skipped = function()
    local cfg = { master_id = "M", nodes = { { id = "M", role = "master" }, { role = "signal" }, { id = 5, role = "signal" }, "x", { id = "S-1", role = "signal" } } }
    assert(join(assert(ota_targets.select(cfg, { role = "signal" }))) == "S-1")
  end,

  test_the_summary_says_what_will_happen = function()
    local text = ota_targets.describe({ "SIG-A", "SIG-B" }, { role = "signal", limit = 2 })
    assert(text:find("2", 1, true) and text:find("signal", 1, true) and text:find("SIG-A", 1, true), text)
    assert(ota_targets.describe({}, {}):find("jedem Computer", 1, true), "no list: everyone who answers")
  end,
  -- the tool itself: a dry run says whom it would reach, and a mistake stops it before a modem is opened
  test_the_tool_in_dry_run_mode_reaches_nobody_and_says_whom_it_would = function()
    local function run_tool(...)
      local lines = {}
      local chunk = assert(loadfile("scripts/ota_push.lua"))
      local env = setmetatable({ print = function(text) lines[#lines + 1] = tostring(text) end, peripheral = false }, { __index = _G })
      if setfenv then setfenv(chunk, env) else
        chunk = assert(load(io.open("scripts/ota_push.lua", "rb"):read("*a"), "=ota_push", "t", env))
      end
      local ok, err = pcall(chunk, ...)
      return ok, err, table.concat(lines, "\n")
    end
    local ok, err, out = run_tool("--config", "configs/templates/network.full.example.json", "--role", "signal", "--limit", "1", "--dry-run")
    assert(ok, tostring(err))
    assert(out:find("Angeboten wird 1 Computer mit der Rolle signal", 1, true) and out:find("Nichts wurde gesendet", 1, true), out)
    ok, err = run_tool("--config", "configs/templates/network.full.example.json", "--role", "signl", "--dry-run")
    assert(ok == false and tostring(err):find("Unbekannte Rolle", 1, true), tostring(err))
    ok, err = run_tool("--config", "configs/templates/network.full.example.json", "--role", "signal", "--limit", "0", "--dry-run")
    assert(ok == false and tostring(err):find("--limit", 1, true), tostring(err))
    ok, err, out = run_tool("--config", "configs/templates/network.full.example.json", "--legacy", "--dry-run")
    assert(ok and out:find("LEGACY: ", 1, true), tostring(err) .. out)
  end,
}
