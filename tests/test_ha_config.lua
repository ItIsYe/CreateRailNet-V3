--[[
Purpose: The plan of a network with two masters and an arbiter: what is valid and what is refused (Gesamtkonzept Kap. 2, 8.1).
Public API: returns table of tests.
]]

pcall(dofile, "tests/harness/cc_bootstrap.lua")

local validate = require("src.shared.validate")

local function plan(mutation)
  local cfg = {
    v = 1, channel = 1, master_id = "MASTER-A", blocks = {}, routes = {},
    nodes = { { id = "MASTER-A", role = "master" }, { id = "MASTER-B", role = "master" }, { id = "ARB-1", role = "arbiter" } },
    masters = { "MASTER-A", "MASTER-B" }, arbiter = "ARB-1"
  }
  if mutation then mutation(cfg) end
  return cfg
end

local function problems(cfg)
  local ok, errors = validate.validate_config(cfg)
  return ok, table.concat(errors or {}, "\n")
end

return {
  test_two_masters_and_an_arbiter_are_valid = function()
    local ok, text = problems(plan())
    assert(ok, text)
  end,

  test_a_plan_with_one_master_and_no_arbiter_stays_valid = function()
    local ok, text = problems(plan(function(c) c.masters, c.arbiter = nil, nil; c.nodes = { { id = "MASTER-A", role = "master" } } end))
    assert(ok, text)
  end,

  test_two_masters_need_an_arbiter = function()
    local ok, text = problems(plan(function(c) c.arbiter = nil end))
    assert(not ok and text:find("need an arbiter", 1, true), text)
  end,

  test_the_arbiter_must_be_a_node_with_that_role = function()
    local ok, text = problems(plan(function(c) c.arbiter = "MASTER-B" end))
    assert(not ok and text:find("role arbiter", 1, true), text)
    ok, text = problems(plan(function(c) c.arbiter = "NOBODY" end))
    assert(not ok and text:find("role arbiter", 1, true), text)
  end,

  test_both_masters_must_be_master_nodes_and_the_preferred_one_must_be_one_of_them = function()
    local ok, text = problems(plan(function(c) c.masters = { "MASTER-A", "ARB-1" } end))
    assert(not ok and text:find("masters[2]", 1, true), text)
    ok, text = problems(plan(function(c) c.nodes[#c.nodes + 1] = { id = "MASTER-C", role = "master" }; c.masters = { "MASTER-B", "MASTER-C" } end))
    assert(not ok and text:find("must contain master_id", 1, true), text)
  end,

  test_exactly_two_masters_not_three = function()
    local ok, text = problems(plan(function(c) c.nodes[#c.nodes + 1] = { id = "MASTER-C", role = "master" }; c.masters = { "MASTER-A", "MASTER-B", "MASTER-C" } end))
    assert(not ok and text:find("exactly two", 1, true), text)
    ok, text = problems(plan(function(c) c.masters = { "MASTER-A" } end))
    assert(not ok and text:find("exactly two", 1, true), text)
  end,

  test_an_arbiter_without_two_masters_is_refused = function()
    local ok, text = problems(plan(function(c) c.masters = nil end))
    assert(not ok and text:find("only makes sense", 1, true), text)
  end,

  test_election_timing_keys_are_checked = function()
    local ok, text = problems(plan(function(c) c.election_lease_ms = 0 end))
    assert(not ok and text:find("election_lease_ms", 1, true))
    ok, text = problems(plan(function(c) c.election_beat_ms = "fast" end))
    assert(not ok and text:find("election_beat_ms", 1, true))
    ok, text = problems(plan(function(c) c.election_state_file = "" end))
    assert(not ok and text:find("election_state_file", 1, true))
    ok, text = problems(plan(function(c) c.election_lease_ms = 4000; c.election_beat_ms = 1000; c.election_state_file = "state/e.json" end))
    assert(ok, text)
  end
}
