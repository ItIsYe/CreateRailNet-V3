--[[
Purpose: Simple wrapper to run all CreateRailNet-V3 tests.
Usage: shell.run("scripts/run_tests.lua") or dofile("scripts/run_tests.lua")
]]

pcall(dofile, "tests/harness/cc_bootstrap.lua")
dofile("tests/harness/runner.lua")
