--[[
Purpose: Chaos test for the dispatcher: garbage sensor events, repeated and conflicting requests, node timeouts, stale
  events and snapshot round trips in random order. No call may raise and the safety invariants must survive.
Public API: returns table of tests.
]]

pcall(dofile, "tests/harness/cc_bootstrap.lua")

local world_mod = require("tests.harness.dispatcher_world")

local SEEDS = 60
local STEPS = 200
local FIRST_SEED = 1000

local function walk(seed, world)
  for n = 1, STEPS do
    local ok, err = pcall(world_mod.step_chaos, world)
    if not ok then error(string.format("seed %d step %d raised: %s", seed, n, tostring(err)), 0) end
    local broken = world_mod.violation(world, { chaos = true })
    if broken then error(string.format("seed %d step %d: %s -- after: %s", seed, n, broken, world_mod.recent(world, 8)), 0) end
  end
end

local function run_seed(seed)
  local world = world_mod.new(seed, { chaos = true })
  local ok, err = pcall(walk, seed, world)
  world_mod.close(world)
  if not ok then error(err, 0) end
end

return {
  test_chaos_sequences_never_raise_and_keep_safety_invariants = function()
    for seed = FIRST_SEED + 1, FIRST_SEED + SEEDS do run_seed(seed) end
  end
}
