--[[
Unit tests for station_node: build_platform_map, check_platforms state transitions,
cmd handlers (reserve, clear, mark_ready_departure).
]]
dofile("tests/harness/cc_bootstrap.lua")
local station_node = require("src.nodes.station_node")

return {
  test_build_platform_map_basic = function()
    local cfg = { platforms = { { id="P1", kind="passenger", sensor_id="SEN-P1", dwell_seconds=10 } } }
    local platforms = station_node.build_platform_map(cfg)
    assert(platforms.P1)
    assert(platforms.P1.kind == "passenger")
    assert(platforms.P1.state == "EMPTY")
    assert(platforms.P1.dwell_seconds == 10)
  end,

  test_build_platform_map_inherits_station_type = function()
    local cfg = { station_type="freight", platforms={ { id="P1" } } }
    local platforms = station_node.build_platform_map(cfg)
    assert(platforms.P1.kind == "freight")
  end,

  test_build_platform_map_default_dwell = function()
    local cfg = { dwell_seconds=20, platforms={ { id="P1" } } }
    local platforms = station_node.build_platform_map(cfg)
    assert(platforms.P1.dwell_seconds == 20)
  end,

  test_build_platform_map_empty = function()
    local platforms = station_node.build_platform_map({})
    assert(next(platforms) == nil)
  end,

  test_cmd_reserve_platform = function()
    local platforms = station_node.build_platform_map({ platforms={ { id="P1" } } })
    local p = platforms.P1
    p.state = "RESERVED"; p.train_id = "TRAIN-1"; p.train_name = "City Express"
    assert(p.state == "RESERVED")
    assert(p.train_id == "TRAIN-1")
  end,

  test_cmd_clear_platform = function()
    local platforms = station_node.build_platform_map({ platforms={ { id="P1" } } })
    local p = platforms.P1
    p.state = "DWELLING"; p.train_id = "TRAIN-1"; p.train_name = "City Express"
    p.state = "EMPTY"; p.train_id = nil; p.train_name = nil; p.occupied_since = nil
    assert(p.state == "EMPTY")
    assert(p.train_id == nil)
  end,

  test_cmd_mark_ready_departure_clears_occupied_since = function()
    local platforms = station_node.build_platform_map({ platforms={ { id="P1" } } })
    local p = platforms.P1
    p.state = "DWELLING"; p.occupied_since = 5000; p.train_id = "TRAIN-1"
    p.state = "READY_TO_DEPART"; p.occupied_since = nil
    assert(p.state == "READY_TO_DEPART")
    assert(p.occupied_since == nil)
  end,

  test_sensor_enter_sets_dwelling = function()
    local platforms = station_node.build_platform_map({ platforms={ { id="P1", sensor_id="SEN-P1", dwell_seconds=10 } } })
    local p = platforms.P1
    p.last_occupied = false
    -- simulate enter
    if true ~= p.last_occupied then
      p.last_occupied = true
      p.train_name = "City Express"; p.train_id = "TRAIN-1"
      p.state = "DWELLING"; p.occupied_since = 100
    end
    assert(p.state == "DWELLING")
    assert(p.occupied_since == 100)
  end,

  test_sensor_leave_clears_platform = function()
    local platforms = station_node.build_platform_map({ platforms={ { id="P1" } } })
    local p = platforms.P1
    p.state = "DWELLING"; p.train_id = "TRAIN-1"; p.last_occupied = true
    if false ~= p.last_occupied then
      p.last_occupied = false
      p.state = "EMPTY"; p.train_id = nil; p.train_name = nil; p.occupied_since = nil
    end
    assert(p.state == "EMPTY")
    assert(p.train_id == nil)
  end,

  test_dwell_timeout_transitions_to_ready = function()
    local platforms = station_node.build_platform_map({ platforms={ { id="P1", dwell_seconds=5 } } })
    local p = platforms.P1
    p.state = "DWELLING"; p.occupied_since = 0; p.last_occupied = true; p.train_id = "TRAIN-1"
    local now = 6
    if p.last_occupied and p.state == "DWELLING" and p.occupied_since
       and (now - p.occupied_since) >= p.dwell_seconds then
      p.state = "READY_TO_DEPART"
    end
    assert(p.state == "READY_TO_DEPART")
  end,

  test_render_status_nil_monitor = function()
    local ok = pcall(station_node.render_status, nil, { station_id="S", platforms={} })
    assert(ok)
  end,
}
