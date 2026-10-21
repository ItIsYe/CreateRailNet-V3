--[[
Purpose: Differences between master states: applying the difference to the old state gives exactly the new one, for any pair of states (Gesamtkonzept Kap. 5.2).
Public API: returns table of tests.
]]

pcall(dofile, "tests/harness/cc_bootstrap.lua")

local state_delta = require("src.domain.state_delta")
local json = require("src.shared.json")
local prng = require("tests.harness.prng")

local function random_state(rng)
  local blocks, trains = {}, {}
  for i = 1, rng.int(0, 12) do blocks["B" .. i] = { id = "B" .. i, state = rng.pick({ "FREE", "RESERVED", "OCCUPIED", "FAULT" }), reserved_by = rng.chance(0.5) and ("T" .. rng.int(1, 3)) or nil, occupied_by = rng.chance(0.3) and "T1" or nil } end
  for i = 1, rng.int(0, 4) do trains["T" .. i] = { id = "T" .. i, route = "R" .. rng.int(1, 5), state = rng.pick({ "WAITING", "RESERVED", "RUNNING" }), route_index = rng.int(1, 3), conflict_groups = { "G" .. rng.int(1, 3) } } end
  local queue = {}
  for i = 1, rng.int(0, 3) do queue[i] = { train_id = "T" .. i, route_id = "R" .. rng.int(1, 5), priority = rng.int(0, 9) } end
  return { version = 2, blocks = blocks, trains = trains, queue = queue, switch_locks = rng.chance(0.5) and { { id = "SW-1", owner = "T1:R1" } } or {}, active_conflicts = rng.chance(0.5) and { ["G1"] = { owner = "T1" } } or {}, deadlocks = {} }
end

return {
  test_applying_the_difference_gives_the_new_state_for_random_pairs = function()
    for seed = 1, 300 do
      local rng = prng.new(seed)
      local old, new = random_state(rng), random_state(rng)
      local delta = state_delta.diff(old, new)
      local rebuilt = delta and state_delta.apply(old, delta) or old
      assert(state_delta.equal(rebuilt, new), "seed " .. seed)
      if delta == nil then assert(state_delta.equal(old, new)) end
    end
  end,

  test_no_change_is_no_delta = function()
    local state = random_state(prng.new(5))
    assert(state_delta.diff(state, state_delta.copy(state)) == nil)
    assert(state_delta.diff({}, {}) == nil)
  end,

  test_the_base_state_is_never_changed_and_the_result_shares_nothing_that_can_change_it = function()
    local old = { blocks = { B1 = { id = "B1", state = "FREE" } }, trains = {}, queue = {} }
    local snapshot = state_delta.copy(old)
    local new = { blocks = { B1 = { id = "B1", state = "RESERVED", reserved_by = "T1" } }, trains = { T1 = { id = "T1" } }, queue = { { train_id = "T1" } } }
    local delta = state_delta.diff(old, new)
    local rebuilt = state_delta.apply(old, delta)
    assert(state_delta.equal(old, snapshot), "apply does not change its base")
    rebuilt.blocks.B1.state = "CHANGED"
    rebuilt.queue[1].train_id = "CHANGED"
    assert(delta.map.blocks.set.B1.state == "RESERVED" and delta.whole.queue[1].train_id == "T1", "the delta is not changed through the result")
  end,

  test_a_train_that_moved_sends_one_record_not_the_whole_table = function()
    local old, new = { blocks = {}, trains = {} }, { blocks = {}, trains = {} }
    for i = 1, 200 do
      old.blocks["B" .. i] = { id = "B" .. i, state = "FREE" }
      new.blocks["B" .. i] = { id = "B" .. i, state = "FREE" }
    end
    new.blocks.B77.state = "OCCUPIED"
    local delta = state_delta.diff(old, new)
    local count = 0
    for _ in pairs(delta.map.blocks.set) do count = count + 1 end
    assert(count == 1 and delta.map.blocks.set.B77.state == "OCCUPIED")
    assert(#json.encode(delta) < 200, "a few bytes, got " .. #json.encode(delta))
  end,

  test_removed_records_and_keys_are_removed = function()
    local old = { blocks = { B1 = { id = "B1" }, B2 = { id = "B2" } }, extra = 5, trains = {} }
    local new = { blocks = { B1 = { id = "B1" } }, trains = {} }
    local rebuilt = state_delta.apply(old, state_delta.diff(old, new))
    assert(rebuilt.blocks.B2 == nil and rebuilt.extra == nil and rebuilt.blocks.B1)
  end,

  test_a_delta_survives_json = function()
    local old, new = random_state(prng.new(11)), random_state(prng.new(12))
    local delta = state_delta.diff(old, new)
    local decoded = json.decode(json.encode(delta))
    assert(state_delta.equal(state_delta.apply(old, decoded), new))
  end,

  test_equality_ignores_order_for_maps_and_respects_it_for_arrays = function()
    assert(state_delta.equal({ a = 1, b = { c = 2 } }, { b = { c = 2 }, a = 1 }))
    assert(not state_delta.equal({ 1, 2 }, { 2, 1 }))
    assert(not state_delta.equal({ a = 1 }, { a = 1, b = 2 }))
    assert(not state_delta.equal({ a = 1, b = 2 }, { a = 1 }))
  end
}
