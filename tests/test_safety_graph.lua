--[[
Purpose: The directed safety graph of the master: blocks, edges, conflict groups, safe waiting points (Gesamtkonzept Kap. 4.1 to 4.3; tests B-01 to B-04, B-07, B-09, C-10).
Public API: returns table of tests.
]]

local safety_graph = require("src.domain.safety_graph")

-- four tracks, two per direction, a switch pair, a station block at each end
local function cfg()
  return {
    blocks = {
      { id = "W1", entry_signal = "S-W1", exit_signal = "X-W1", sensors = { "SEN-W1" }, switches = { { id = "SW-1", position = "STRAIGHT" } } },
      { id = "M1", entry_signal = "S-M1", exit_signal = "X-M1", sensors = { "SEN-M1" }, switches = {} },
      { id = "M2", entry_signal = "S-M2", exit_signal = "X-M2", sensors = { "SEN-M2" }, switches = { { id = "SW-1", position = "DIVERGING" } } },
      { id = "E1", entry_signal = "S-E1", exit_signal = "X-E1", sensors = { "SEN-E1" }, tail_sensors = { "SEN-E1" }, switches = {} },
      { id = "E2", entry_signal = "S-E2", exit_signal = "X-E2", sensors = { "SEN-E2" }, switches = {} },
      { id = "N1", entry_signal = "S-N1", exit_signal = "X-N1", sensors = {}, switches = {} }
    },
    routes = {
      { id = "R-EAST1", from = "W", to = "E", blocks = { "W1", "M1", "E1" } },
      { id = "R-EAST2", from = "W", to = "E", blocks = { "W1", "M2", "E2" } },
      { id = "R-WEST1", from = "E", to = "W", blocks = { "E1", "M1", "W1" } },
      { id = "R-OTHER", from = "X", to = "Y", blocks = { "N1" } }
    },
    safe_stops = { { block = "E1", length = 6, proven = true }, { block = "E2", length = 12, proven = true }, { block = "W1", length = 6, proven = false } }
  }
end

local function codes(g, severity)
  local out = {}
  for _, p in ipairs(g.problems) do if not severity or p.severity == severity then out[p.code] = (out[p.code] or 0) + 1 end end
  return out
end

return {
  test_edges_follow_the_route_direction_and_both_directions_are_separate = function()
    local g = safety_graph.build(cfg())
    assert(g.has_edge("W1", "M1") and g.has_edge("M1", "E1"))
    assert(g.has_edge("E1", "M1") and g.has_edge("M1", "W1"), "the opposite direction is its own route")
    assert(not g.has_edge("E1", "W1"), "no edge that no route drives")
    local out = g.successors("W1")
    assert(#out == 2 and out[1] == "M1" and out[2] == "M2", "branches are listed, sorted")
  end,

  test_a_route_that_shares_a_block_conflicts_whatever_its_direction = function()
    local g = safety_graph.build(cfg())
    local conflict, why = g.routes_conflict("R-EAST1", "R-WEST1")
    assert(conflict and why:find("M1", 1, true), why)
    assert(g.routes_conflict("R-EAST1", "R-EAST2"), "they share W1")
    assert(not g.routes_conflict("R-EAST1", "R-OTHER") and not g.routes_conflict("R-OTHER", "R-WEST1"), "independent routes do not block each other (B-04)")
  end,

  test_two_routes_that_need_one_switch_in_different_positions_conflict_even_without_a_common_block = function()
    local c = cfg()
    c.routes = { { id = "A", blocks = { "M1" } }, { id = "B", blocks = { "M2" } } }
    c.blocks[2].switches = { { id = "SW-1", position = "STRAIGHT" } }
    local g = safety_graph.build(c)
    local conflict, why = g.routes_conflict("A", "B")
    assert(conflict and why:find("SW-1", 1, true), tostring(why))
    c.blocks[2].switches = { { id = "SW-1", position = "DIVERGING" } }
    assert(not safety_graph.build(c).routes_conflict("A", "B"), "same position is no conflict")
  end,

  test_a_declared_conflict_group_or_a_flank_switch_conflicts = function()
    local c = cfg()
    c.routes[4].conflict_group = "crossing-1"
    c.routes[3].conflict_groups = { "crossing-1" }
    local g = safety_graph.build(c)
    local conflict, why = g.routes_conflict("R-OTHER", "R-WEST1")
    assert(conflict and why:find("crossing-1", 1, true), tostring(why))
    local f = cfg()
    f.interlocking_routes = { { id = "R-OTHER", flank_protection = { { switch_id = "SW-1", position = "STRAIGHT" } } } }
    local conflict2, why2 = safety_graph.build(f).routes_conflict("R-OTHER", "R-EAST2")
    assert(conflict2 and why2:find("flank", 1, true), tostring(why2))
  end,

  test_a_route_ends_at_a_proven_safe_stop_or_it_is_not_allowed = function()
    local g = safety_graph.build(cfg())
    assert(g.route_end("R-EAST1") == true)
    local ok, why = g.route_end("R-WEST1")
    assert(not ok and why:find("W1", 1, true) and why:find("proven", 1, true), "W1 is a candidate but the stop test is missing: " .. tostring(why))
    local ok2, why2 = g.route_end("R-OTHER")
    assert(not ok2 and why2:find("safe", 1, true), "N1 is no safe stop at all: " .. tostring(why2))
  end,

  test_the_length_of_the_train_must_fit_the_safe_stop = function()
    local g = safety_graph.build(cfg())
    assert(g.route_end("R-EAST1", { length = 6 }) == true)
    local ok, why = g.route_end("R-EAST1", { length = 7 })
    assert(not ok and why:find("long", 1, true), tostring(why))
    assert(g.route_end("R-EAST2", { length = 12 }) == true)
    -- no length on the stop means the length was never measured: a train with a known length is refused
    local c = cfg(); c.safe_stops[1].length = nil
    local ok3 = safety_graph.build(c).route_end("R-EAST1", { length = 4 })
    assert(not ok3, "an unmeasured stop does not take a train of a known length")
    assert(safety_graph.build(c).route_end("R-EAST1") == true, "a train of unknown length is judged by the stop test alone")
  end,

  test_the_next_waypoint_is_found_along_the_directed_edges_only = function()
    local g = safety_graph.build(cfg())
    assert(g.next_waypoint("W1") == "E1", "the nearest proven stop, sorted when equal")
    assert(g.next_waypoint("M2") == "E2")
    assert(g.next_waypoint("E1") == nil or g.next_waypoint("E1") == "E1", "a stop is its own waypoint")
    assert(g.next_waypoint("N1") == nil)
    assert(g.reachable("W1", "E2") and not g.reachable("E2", "W1"))
  end,

  test_a_block_without_a_tail_sensor_is_not_provable_and_the_graph_says_so = function()
    local g = safety_graph.build(cfg())
    local ok, why = g.provable("N1")
    assert(not ok and why:find("sensor", 1, true), tostring(why))
    assert(g.provable("E1") == true and g.provable("M1") == true)
    assert(codes(g, "warn")["no_tail_evidence"] == 1, "one warning for N1")
    assert(g.tail_sensors("E1")[1] == "SEN-E1" and g.tail_sensors("M1")[1] == "SEN-M1", "the default tail sensors are the sensors of the block")
  end,

  test_mistakes_in_the_plan_are_problems_not_surprises = function()
    local c = cfg()
    c.routes[1].blocks = { "W1", "NOPE", "E1" }
    c.safe_stops[#c.safe_stops + 1] = { block = "GHOST", proven = true }
    c.blocks[#c.blocks + 1] = { id = "W1", sensors = { "SEN-W1" } }
    c.routes[2].alternatives = { "R-OTHER" }
    local g = safety_graph.build(c)
    local e = codes(g, "error")
    assert(e.unknown_block == 2, "a route and a safe stop name a block that does not exist")
    assert(e.duplicate_block == 1)
    assert(e.bad_alternative == 1, "an alternative must run between the same ends")
  end,

  test_the_topology_version_changes_with_the_topology_and_with_nothing_else = function()
    local a = safety_graph.build(cfg())
    local b = safety_graph.build(cfg())
    assert(a.version == b.version and #a.version == 16)
    local c = cfg(); c.routes[1].blocks = { "W1", "E1" }
    assert(safety_graph.build(c).version ~= a.version, "a route changed")
    local d = cfg(); d.safe_stops[1].proven = false
    assert(safety_graph.build(d).version ~= a.version, "a stop lost its proof")
    local e = cfg(); e.heartbeat_timeout_s = 99; e.routes[1].priority = 3
    assert(safety_graph.build(e).version == a.version, "priority and timings are not topology")
  end,

  test_the_affected_blocks_of_a_topology_change_are_named = function()
    local old = safety_graph.build(cfg())
    local c = cfg(); c.blocks[2].switches = { { id = "SW-9", position = "STRAIGHT" } }
    local changed = safety_graph.diff(old, safety_graph.build(c))
    assert(#changed == 1 and changed[1] == "M1", "only the block whose switches changed: " .. table.concat(changed, ","))
    local c2 = cfg(); c2.routes[#c2.routes + 1] = { id = "R-NEW", blocks = { "E2", "M2" } }
    local changed2 = safety_graph.diff(old, safety_graph.build(c2))
    assert(table.concat(changed2, ",") == "E2,M2", table.concat(changed2, ","))
    assert(#safety_graph.diff(old, safety_graph.build(cfg())) == 0)
  end,

  test_a_new_block_is_a_changed_area = function()
    local old = safety_graph.build(cfg())
    local c = cfg(); c.blocks[#c.blocks + 1] = { id = "X9", entry_signal = "S-X", exit_signal = "X-X", sensors = { "SEN-X9" } }
    local changed = safety_graph.diff(old, safety_graph.build(c))
    assert(table.concat(changed, ",") == "X9", table.concat(changed, ","))
    assert(table.concat(safety_graph.diff(safety_graph.build(c), old), ",") == "X9", "and a block that is gone")
  end,

  test_the_config_check_knows_the_new_keys = function()
    local validate = require("src.shared.validate")
    local function base()
      local c = cfg()
      c.v = 1; c.channel = 1; c.master_id = "M"
      c.nodes = { { id = "M", role = "master" } }
      return c
    end
    local function errors_of(c) local ok, errs = validate.validate_config(c); return table.concat(errs or {}, "\n") end
    local ok_cfg = base(); ok_cfg.occupancy_proof = "on"
    local text = errors_of(ok_cfg)
    assert(not text:find("occupancy_proof", 1, true) and not text:find("safe_stops", 1, true) and not text:find("safety_graph", 1, true), text)
    local bad = base(); bad.occupancy_proof = "maybe"
    assert(errors_of(bad):find("occupancy_proof", 1, true))
    local bad2 = base(); bad2.safe_stops = { { block = "NOPE" }, { block = "E1", length = -1, proven = "yes" } }
    local t2 = errors_of(bad2)
    assert(t2:find("safe_stops[1].block", 1, true) and t2:find("safe_stops[2].length", 1, true) and t2:find("safe_stops[2].proven", 1, true), t2)
    local bad3 = base(); bad3.occupancy_proof = "on"; bad3.routes[1].blocks = { "W1", "NOPE" }
    assert(errors_of(bad3):find("safety_graph.unknown_block", 1, true))
  end
}
