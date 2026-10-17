--[[
Purpose: Replays a trace recorded by the master (traces/*.json) against a dispatcher built from the same config.
Usage: lua scripts/replay_trace.lua <trace.json> <config.json> [--strict]
Notes: prints every step whose result differs from the recording and every safety invariant that breaks; exit status 1 if there is any.
  Needs the test harness (tests/harness), so run it from a checkout of the repository, not on the game computer.
]]

package.path = table.concat({ "./?.lua", "./?/init.lua", package.path or "" }, ";")
pcall(dofile, "tests/harness/cc_bootstrap.lua")

local config = require("src.shared.config")
local trace_recorder = require("src.domain.trace_recorder")
local trace_replay = require("tests.harness.trace_replay")

local trace_path, config_path = arg and arg[1], arg and arg[2]
if not trace_path or not config_path then
  print("usage: lua scripts/replay_trace.lua <trace.json> <config.json> [--strict]")
  os.exit(2)
end

local trace, err = trace_recorder.load(trace_path)
if not trace then print("cannot read trace: " .. tostring(err)); os.exit(2) end
local cfg = config.load(config_path)

local result = trace_replay.run(cfg, trace, { strict = arg[3] == "--strict" })
print(string.format("%d steps replayed", result.steps))
for _, m in ipairs(result.mismatches) do print(string.format("step %d %s: recorded %s, replayed %s", m.step, m.op, m.recorded, m.replayed)) end
for _, v in ipairs(result.violations) do print(string.format("step %d: UNSAFE %s", v.step, v.text)) end
if result.error then print("replay stopped: " .. result.error) end
if #result.mismatches > 0 or #result.violations > 0 or result.error then os.exit(1) end
print("no differences, no violations")
