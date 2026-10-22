--[[
Purpose: The choice of the destination track in a station and of a track in a depot (Gesamtkonzept Kap. 7.1, 7.2; tests C-06, C-10, C-11).
Public API: returns table of tests.
]]

local track_choice = require("src.domain.track_choice")

local function platforms()
  return {
    { id = "P1", block = "BP1", direction = "EAST", length = 8, train_types = { "passenger" }, preferred = 1, confirmed = true },
    { id = "P2", block = "BP2", direction = "EAST", length = 12, train_types = { "passenger", "freight" }, preferred = 2, confirmed = true },
    { id = "P3", block = "BP3", direction = "WEST", length = 12, confirmed = true },
    { id = "P4", block = "BP4", direction = "EAST", length = 20, confirmed = false }
  }
end

local function state(free)
  local set = {}
  for _, b in ipairs(free) do set[b] = true end
  return { is_free = function(block) return set[block] == true end }
end

local function ids(list) local out = {} for _, c in ipairs(list) do out[#out + 1] = c.id end return table.concat(out, ",") end

return {
  test_the_preferred_suitable_free_track_is_taken_first = function()
    local best, candidates = track_choice.choose_platform(platforms(), { length = 6, train_type = "passenger", direction = "EAST" }, state({ "BP1", "BP2", "BP3", "BP4" }))
    assert(best == "P1" and ids(candidates) == "P1,P2", ids(candidates))
  end,

  test_a_track_that_is_taken_or_unproven_gives_way_to_the_next_suitable_one = function()
    local best = track_choice.choose_platform(platforms(), { length = 6, train_type = "passenger", direction = "EAST" }, state({ "BP2" }))
    assert(best == "P2")
  end,

  test_length_direction_and_type_exclude_tracks_with_a_reason = function()
    local best, candidates, excluded = track_choice.choose_platform(platforms(), { length = 10, train_type = "freight", direction = "EAST" }, state({ "BP1", "BP2", "BP3", "BP4" }))
    assert(best == "P2" and ids(candidates) == "P2")
    assert(excluded.P1:find("long", 1, true) or excluded.P1:find("type", 1, true), excluded.P1)
    assert(excluded.P3:find("direction", 1, true), excluded.P3)
    assert(excluded.P4:find("confirmed", 1, true), excluded.P4)
  end,

  test_the_train_type_alone_can_exclude_a_track = function()
    local best, _, excluded = track_choice.choose_platform(platforms(), { length = 6, train_type = "freight", direction = "EAST" }, state({ "BP1", "BP2" }))
    assert(best == "P2" and excluded.P1:find("type", 1, true), tostring(excluded.P1))
  end,

  test_a_track_whose_length_was_never_measured_takes_no_train_of_a_known_length = function()
    local list = { { id = "A", block = "BA", confirmed = true }, { id = "B", block = "BB", length = 10, confirmed = true } }
    local best, _, excluded = track_choice.choose_platform(list, { length = 5 }, state({ "BA", "BB" }))
    assert(best == "B" and excluded.A:find("never measured", 1, true), tostring(excluded.A))
    local _, candidates = track_choice.choose_platform(list, {}, state({ "BA", "BB" }))
    assert(ids(candidates) == "B,A", "a train of unknown length is judged by the rest; the measured track comes first")
  end,

  test_the_preference_beats_the_best_fit = function()
    local list = {
      { id = "BIG", block = "B1", length = 20, preferred = 1, confirmed = true },
      { id = "SNUG", block = "B2", length = 8, preferred = 2, confirmed = true }
    }
    local best = track_choice.choose_platform(list, { length = 7 }, state({ "B1", "B2" }))
    assert(best == "BIG")
  end,

  test_a_train_longer_than_every_track_gets_no_track_and_a_reason = function()
    local best, candidates, excluded, wait = track_choice.choose_platform(platforms(), { length = 30, direction = "EAST" }, state({ "BP1", "BP2" }))
    assert(best == nil and #candidates == 0 and wait == false, "no wait: waiting would never help")
    assert(excluded.P2:find("long", 1, true))
  end,

  test_when_every_suitable_track_is_taken_the_train_waits_before_the_station = function()
    local best, candidates, _, wait = track_choice.choose_platform(platforms(), { length = 6, train_type = "passenger", direction = "EAST" }, state({}))
    assert(best == nil and #candidates == 0 and wait == true)
  end,

  test_the_best_fit_wins_among_equally_preferred_tracks = function()
    local list = {
      { id = "A", block = "BA", length = 20, confirmed = true },
      { id = "B", block = "BB", length = 8, confirmed = true },
      { id = "C", block = "BC", length = 10, confirmed = true }
    }
    local best, candidates = track_choice.choose_platform(list, { length = 7 }, state({ "BA", "BB", "BC" }))
    assert(best == "B" and ids(candidates) == "B,C,A", ids(candidates))
  end,

  test_the_conflict_group_of_a_track_in_use_excludes_its_neighbours = function()
    local list = {
      { id = "A", block = "BA", conflict_group = "cross", confirmed = true, preferred = 1 },
      { id = "B", block = "BB", conflict_group = "cross", confirmed = true, preferred = 2 },
      { id = "C", block = "BC", confirmed = true, preferred = 3 }
    }
    local st = state({ "BA", "BB", "BC" })
    st.group_busy = function(group) return group == "cross" end
    local best, _, excluded = track_choice.choose_platform(list, {}, st)
    assert(best == "C" and excluded.A:find("conflict", 1, true))
  end,

  test_depot_a_free_compatible_track_is_given_first = function()
    local depots = {
      { id = "D1", tracks = { { id = "D1-1", block = "BD11", length = 6, confirmed = true }, { id = "D1-2", block = "BD12", length = 12, confirmed = true } } },
      { id = "D2", tracks = { { id = "D2-1", block = "BD21", length = 12, confirmed = true } } }
    }
    local r = track_choice.choose_depot(depots, { length = 8 }, state({ "BD11", "BD12", "BD21" }))
    assert(r.kind == "TRACK" and r.depot == "D1" and r.track == "D1-2", tostring(r.track))
  end,

  test_the_shortest_free_track_the_train_fits_is_taken_in_a_depot = function()
    local depots = { { id = "D1", tracks = { { id = "LONG", block = "L", length = 20, confirmed = true }, { id = "SHORT", block = "S", length = 9, confirmed = true } } } }
    local r = track_choice.choose_depot(depots, { length = 8 }, state({ "L", "S" }))
    assert(r.track == "SHORT")
  end,

  test_a_full_depot_leads_to_an_alternative_depot_before_anything_else = function()
    local depots = {
      { id = "D1", tracks = { { id = "D1-1", block = "BD11", length = 12, confirmed = true } } },
      { id = "D2", tracks = { { id = "D2-1", block = "BD21", length = 12, confirmed = true } } }
    }
    local r = track_choice.choose_depot(depots, { length = 8, prefer = "D1" }, state({ "BD21" }))
    assert(r.kind == "TRACK" and r.depot == "D2" and r.alternative == true and r.track == "D2-1")
  end,

  test_when_all_depots_are_full_a_confirmed_circuit_is_used_else_the_job_is_held_and_reported = function()
    local depots = { { id = "D1", tracks = { { id = "D1-1", block = "BD11", length = 12, confirmed = true } } } }
    local full = state({})
    local r = track_choice.choose_depot(depots, { length = 8, circuit = "CIRCUIT-1" }, full)
    assert(r.kind == "SAFE_ROUTE" and r.route == "CIRCUIT-1", "an approved circuit, never a block in front of the depot")
    local r2 = track_choice.choose_depot(depots, { length = 8 }, full)
    assert(r2.kind == "HOLD_AND_ALERT" and r2.reason:find("full", 1, true), tostring(r2.reason))
  end,

  test_a_depot_that_cannot_take_the_train_at_all_is_reported_as_such = function()
    local depots = { { id = "D1", tracks = { { id = "D1-1", block = "BD11", length = 4, confirmed = true } } } }
    local r = track_choice.choose_depot(depots, { length = 8 }, state({ "BD11" }))
    assert(r.kind == "HOLD_AND_ALERT" and r.reason:find("no track", 1, true), tostring(r.reason))
  end
}
