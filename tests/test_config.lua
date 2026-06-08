--[[
Purpose: Config validation tests.
Public API: returns table of tests.
]]

local validate = require("src.shared.validate")

local function base()
  return {
    v = 1,
    channel = 777,
    master_id = "MASTER-1",
    blocks = {
      { id = "B1", entry_signal = "SIG-1", exit_signal = "SIG-2", sensors = { "SEN-1" }, switches = { { id = "SW-1", position = "STRAIGHT" } } }
    },
    routes = {
      { id = "R1", from = "ST-A", to = "ST-B", blocks = { "B1" }, priority = 1, conflict_group = "MAIN-1" }
    },
    service_plans = {
      { id = "SP1", train_id = "TRAIN-1", stops = { { from = "ST-A", to = "ST-B", route_id = "R1", dwell_seconds = 5 } } }
    },
    nodes = {
      { id = "MASTER-1", role = "master" },
      { id = "TRAIN-NODE-1", role = "train", train_id = "TRAIN-1", service_plan = "SP1" },
      { id = "ST-A", role = "station", station_type = "passenger", create_station_name = "Station A", platforms = { { id = "P1", kind = "passenger", sensor_id = "SEN-1", block_id = "B1" } } },
      { id = "ST-B", role = "station", station_type = "passenger", create_station_name = "Station B", platforms = { { id = "P1", kind = "passenger" } } },
      { id = "DEPOT-1", role = "depot", tracks = { { id = "D1", kind = "storage", sensor_id = "SEN-1", block_id = "B1" } } },
      { id = "SIG-1", role = "signal" },
      { id = "SIG-2", role = "signal" },
      { id = "SEN-1", role = "sensor" },
      { id = "SW-1", role = "switch" }
    }
  }
end

local function fails_with(cfg, fragment)
  local ok, errors = validate.validate_config(cfg)
  assert(not ok, "expected config to fail")
  local joined = table.concat(errors, "\n")
  assert(string.find(joined, fragment, 1, true), joined)
end

return {
  test_valid_config = function()
    local ok, er = validate.validate_config(base())
    assert(ok, table.concat(er, ","))
  end,

  test_duplicate_node_id_fails = function()
    local c = base()
    table.insert(c.nodes, { id = "SW-1", role = "switch" })
    fails_with(c, "duplicate node id")
  end,

  test_duplicate_train_id_fails = function()
    local c = base()
    table.insert(c.nodes, { id = "TRAIN-NODE-2", role = "train", train_id = "TRAIN-1" })
    fails_with(c, "duplicate train_id")
  end,

  test_duplicate_platform_id_fails = function()
    local c = base()
    table.insert(c.nodes[3].platforms, { id = "P1", kind = "passenger" })
    fails_with(c, "duplicate platform id")
  end,

  test_unknown_route_block_fails = function()
    local c = base()
    c.routes[1].blocks = { "B9" }
    fails_with(c, "references unknown block")
  end,

  test_unknown_signal_ref_fails = function()
    local c = base()
    c.blocks[1].entry_signal = "SIG-X"
    fails_with(c, "references unknown signal node")
  end,

  test_station_missing_create_name_fails = function()
    local c = base()
    c.nodes[3].create_station_name = nil
    fails_with(c, "exact Create destination name")
  end,

  test_platform_unknown_sensor_fails = function()
    local c = base()
    c.nodes[3].platforms[1].sensor_id = "SEN-X"
    fails_with(c, "references unknown sensor node")
  end,

  test_service_plan_unknown_route_fails = function()
    local c = base()
    c.service_plans[1].stops[1].route_id = "R-X"
    fails_with(c, "references unknown route")
  end,

  test_service_plan_unknown_target_needs_override = function()
    local c = base()
    c.service_plans[1].stops[1].to = "ST-X"
    c.service_plans[1].stops[1].route_id = nil
    fails_with(c, "references unknown station/depot")
  end,

  test_service_plan_unknown_target_with_create_override_passes = function()
    local c = base()
    c.service_plans[1].stops[1].to = "ST-X"
    c.service_plans[1].stops[1].route_id = nil
    c.service_plans[1].stops[1].from = "ST-A"
    c.service_plans[1].stops[1].create_destination = "External Yard"
    local ok, er = validate.validate_config(c)
    assert(ok, table.concat(er, ","))
  end,

  test_invalid_conflict_group_fails = function()
    local c = base()
    c.routes[1].conflict_groups = { "MAIN", "" }
    fails_with(c, "conflict_groups[2]")
  end,

  test_invalid_role_fails = function()
    local c = base()
    c.nodes[1].role = "oops"
    fails_with(c, "invalid role")
  end
}
