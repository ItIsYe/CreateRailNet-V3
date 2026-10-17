--[[
Purpose: status_model tests: lamp rules, faults before grey, problem ordering, cheap on large networks.
Public API: returns table of tests.
]]

pcall(dofile, "tests/harness/cc_bootstrap.lua")

local status_model = require("src.domain.status_model")

local function nodes(spec)
  local out = {}
  for id, v in pairs(spec) do out[id] = { role = v[1], status = v[2] or "up" } end
  return out
end

return {
  test_healthy_network_is_green = function()
    local m = status_model.build({ nodes = nodes({ SIG1 = { "signal" }, T1 = { "train" } }), blocks = { B1 = { state = "FREE" }, B2 = { state = "OCCUPIED" } } })
    assert(m.lamp == "GREEN" and #m.reasons == 0 and #m.problems == 0)
    assert(m.nodes.total == 2 and m.nodes.up == 2 and m.blocks.total == 2)
  end,

  test_a_lost_critical_node_is_red = function()
    local m = status_model.build({ nodes = nodes({ SIG1 = { "signal", "down" }, T1 = { "train" } }), blocks = {} })
    assert(m.lamp == "RED" and m.reasons[1]:find("kritische"))
    assert(m.problems[1].kind == "node" and m.problems[1].id == "SIG1" and m.problems[1].severity == "RED")
  end,

  test_a_lost_train_node_is_only_yellow = function()
    local m = status_model.build({ nodes = nodes({ SIG1 = { "signal" }, T1 = { "train", "down" } }), blocks = {} })
    assert(m.lamp == "YELLOW" and m.problems[1].severity == "YELLOW")
  end,

  test_fault_blocks_and_failed_updates_and_recovery_are_red = function()
    assert(status_model.build({ nodes = {}, blocks = { B1 = { state = "FAULT" } } }).lamp == "RED")
    assert(status_model.build({ nodes = {}, blocks = {}, ota = { { node_id = "N1", state = "FAILED", error = "kein Platz" } } }).lamp == "RED")
    assert(status_model.build({ nodes = {}, blocks = {}, recovery_required = true }).lamp == "RED")
  end,

  test_maintenance_deadlocks_and_running_updates_are_yellow = function()
    assert(status_model.build({ nodes = {}, blocks = {}, maintenance = true }).lamp == "YELLOW")
    assert(status_model.build({ nodes = {}, blocks = {}, deadlocks = { T1 = {} } }).lamp == "YELLOW")
    assert(status_model.build({ nodes = {}, blocks = {}, ota = { { node_id = "N1", state = "SENDING" } } }).lamp == "YELLOW")
    assert(status_model.build({ nodes = {}, blocks = {}, ota = { { node_id = "N1", state = "CONFIRMED" } } }).lamp == "GREEN")
  end,

  test_faults_rank_before_grey_in_the_problem_list = function()
    local m = status_model.build({
      nodes = nodes({ T1 = { "train", "down" }, SEN1 = { "sensor", "down" } }),
      blocks = { B9 = { state = "FAULT" } }
    })
    assert(m.problems[1].severity == "RED" and m.problems[#m.problems].severity == "YELLOW")
    assert(m.problems[#m.problems].id == "T1")
  end,

  test_role_rows_are_sorted_and_colored_by_their_worst_node = function()
    local m = status_model.build({ nodes = nodes({ A = { "train" }, B = { "train", "down" }, S = { "signal" } }), blocks = {} })
    assert(m.roles[1].role == "signal" and m.roles[1].color == "GREEN")
    assert(m.roles[2].role == "train" and m.roles[2].total == 2 and m.roles[2].down == 1 and m.roles[2].color == "YELLOW")
  end,

  test_a_large_network_is_summarised_in_one_pass = function()
    local many = {}
    for i = 1, 2000 do many["N" .. i] = { role = (i % 3 == 0) and "signal" or "train", status = (i % 97 == 0) and "down" or "up" } end
    local started = os.clock()
    local m = status_model.build({ nodes = many, blocks = {} })
    assert(m.nodes.total == 2000 and m.nodes.down == 20)
    assert(m.lamp ~= "GREEN" and m.nodes.up + m.nodes.down == 2000)
    assert(os.clock() - started < 2, "2000 nodes must be summarised quickly")
  end
}
