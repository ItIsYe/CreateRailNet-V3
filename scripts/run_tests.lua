--[[
Purpose: Simple wrapper to run all CreateRailNet-V3 tests.
Usage: shell.run("scripts/run_tests.lua") or dofile("scripts/run_tests.lua") or lua scripts/run_tests.lua
]]

package.path = table.concat({
  "./?.lua",
  "./?/init.lua",
  package.path or ""
}, ";")

pcall(dofile, "tests/harness/cc_bootstrap.lua")
dofile("tests/harness/runner.lua")
