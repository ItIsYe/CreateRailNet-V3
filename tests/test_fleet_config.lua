--[[
Purpose: The config check knows the fleet: pairs, profiles, lines, platforms (docs/FLEET.md).
Public API: returns table of tests.
]]

local validate = require("src.shared.validate")

local function base()
  return {
    v = 1, channel = 1, master_id = "M",
    nodes = {
      { id = "M", role = "master" }, { id = "FA", role = "fleet" }, { id = "FB", role = "fleet" }, { id = "FC", role = "fleet" }, { id = "ST-N", role = "station", create_station_name = "Nord" }
    },
    fleet = {
      pairs = { { id = "P1", nodes = { "FA", "FB" }, trains = { "T1" } } },
      train_profiles = { { immutable_id = "T1", create_name_ref = "Zug 1", train_class = "PASSENGER", length = 6, permitted_directions = { "EAST" } } },
      lines = { { id = "L1", kind = "PASSENGER", time_base = "REAL", window = { from = "06:00", to = "22:00" }, departures = { "08:00" }, stops = { { station = "A" }, { station = "B" } }, routes = { EAST = "R" } } },
      stations = { A = "ST-N" },
      platforms = { B = { { id = "P1", block = "BP1" } } }
    }
  }
end

local function errors_of(cfg)
  local _, errs = validate.validate_config(cfg)
  return table.concat(errs or {}, "\n")
end

return {
  test_a_good_fleet_plan_has_no_fleet_errors = function()
    local text = errors_of(base())
    assert(not text:find("fleet", 1, true), text)
  end,

  test_pair_problems_are_errors = function()
    local c = base(); c.fleet.pairs = { { id = "P1", nodes = { "FA", "FB" } }, { id = "P2", nodes = { "FB", "FC" } } }
    assert(errors_of(c):find("FB is already in pair P1", 1, true))
    local c2 = base(); c2.fleet.pairs[1].nodes = { "FA", "M" }
    assert(errors_of(c2):find("no fleet node", 1, true))
  end,

  test_a_profile_a_line_or_a_platform_with_a_mistake_is_named = function()
    local c = base(); c.fleet.train_profiles[1].length = 0
    assert(errors_of(c):find("fleet.train_profiles[1]", 1, true))
    local c2 = base(); c2.fleet.pairs[1].trains = { "NOPE" }
    assert(errors_of(c2):find("no profile", 1, true))
    local c3 = base(); c3.fleet.lines[1].departures = { "8am" }
    assert(errors_of(c3):find("fleet.lines[1]", 1, true))
    local c4 = base(); c4.fleet.lines[2] = base().fleet.lines[1]
    assert(errors_of(c4):find("defined twice", 1, true))
    local c5 = base(); c5.fleet.stations.A = "M"
    assert(errors_of(c5):find("fleet.stations.A", 1, true))
    local c6 = base(); c6.fleet.platforms.B[2] = { id = "P1" }
    local text = errors_of(c6)
    assert(text:find("defined twice", 1, true) and text:find("needs the id of its block", 1, true), text)
  end,

  test_the_fleet_must_be_a_table = function()
    local c = base(); c.fleet = "yes"
    assert(errors_of(c):find("fleet: must be a table", 1, true))
  end
}
