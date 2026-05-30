--[[
Purpose: Runtime packager tests.
Public API: returns table of tests.
]]

local packager = require("src.tools.runtime_packager")

local function manifest()
  local m = assert(packager.load_manifest("configs/install/runtime_manifest.json"))
  return m
end

return {
  test_runtime_files_are_included = function()
    local m = manifest()
    assert(packager.should_include(m, "startup.lua"))
    assert(packager.should_include(m, "src/shared/config.lua"))
    assert(packager.should_include(m, "src/domain/trains.lua"))
    assert(packager.should_include(m, "src/adapter/create_signals.lua"))
    assert(packager.should_include(m, "src/master/runtime.lua"))
    assert(packager.should_include(m, "src/nodes/train_node.lua"))
  end,

  test_dev_files_are_excluded = function()
    local m = manifest()
    assert(not packager.should_include(m, "src/sim/scenario_runner.lua"))
    assert(not packager.should_include(m, "tests/test_sim_basic_flow.lua"))
    assert(not packager.should_include(m, "docs/SIMULATION.md"))
    assert(not packager.should_include(m, ".github/workflows/offline-tests.yml"))
    assert(not packager.should_include(m, "src/tools/setup_wizard.lua"))
    assert(not packager.should_include(m, "scripts/run_tests.lua"))
  end,

  test_filter_files_splits_runtime_and_dev = function()
    local m = manifest()
    local included, excluded = packager.filter_files(m, {
      "startup.lua",
      "src/shared/config.lua",
      "src/sim/scenario_runner.lua",
      "tests/test_runtime_packager.lua"
    })
    assert(#included == 2)
    assert(#excluded == 2)
    assert(included[1] == "src/shared/config.lua" or included[1] == "startup.lua")
  end
}
