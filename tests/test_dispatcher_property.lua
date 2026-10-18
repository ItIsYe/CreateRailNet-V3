--[[
Purpose: Seeded random-walk property tests for the dispatcher: legal request/enter/leave/queue/release sequences
  on generated topologies must keep the safety invariants after every single step.
Public API: returns table of tests.
Notes: Failures print the seed and step so a run can be replayed with the same numbers on any interpreter.
  Generator, steps and invariants live in tests/harness/dispatcher_world.lua.
]]

pcall(dofile, "tests/harness/cc_bootstrap.lua")

local world_mod = require("tests.harness.dispatcher_world")
local prng = require("tests.harness.prng")

local SEEDS = 60
local STEPS = 160

local function walk(seed, world)
  for n = 1, STEPS do
    local ok, err = pcall(world_mod.step_legal, world)
    if not ok then error(string.format("seed %d step %d: %s", seed, n, tostring(err)), 0) end
    local broken = world_mod.violation(world)
    if broken then error(string.format("seed %d step %d: %s -- after: %s", seed, n, broken, world_mod.recent(world, 8)), 0) end
  end
end

local function run_seed(seed, opts)
  local world = world_mod.new(seed, opts)
  local ok, err = pcall(walk, seed, world)
  world_mod.close(world)
  if not ok then error(err, 0) end
end

return {
  test_random_walks_keep_dispatcher_invariants = function()
    for seed = 1, SEEDS do run_seed(seed) end
  end,

  -- same walks on topologies whose routes carry flank protection and overlap blocks
  test_random_walks_with_flank_and_overlap_keep_invariants = function()
    for seed = 1, SEEDS do run_seed(seed + 500, { stellwerk = true }) end
  end,

  test_prng_is_deterministic_and_in_range = function()
    local a, b = prng.new(42), prng.new(42)
    for _ = 1, 50 do
      local x = a.int(3, 9)
      assert(x == b.int(3, 9) and x >= 3 and x <= 9)
    end
    assert(prng.new(7).int(1, 1000) == prng.new(7).int(1, 1000))
  end
}
