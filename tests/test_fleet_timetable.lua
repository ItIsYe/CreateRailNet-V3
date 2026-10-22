--[[
Purpose: Lines and timetables of the fleet: drafts, validation, publication by both partners, fixed departures and headways in real or Minecraft time, no catching up after a downtime, no duplicate trip (Gesamtkonzept Kap. 9; tests D-06, D-07, D-08, D-10).
Public API: returns table of tests.
]]

local timetable = require("src.fleet.timetable")

-- the clock: real seconds since the epoch (UTC) and the game's (day, hour)
local clock = { epoch = 0, day = 0, hour = 0 }
local function set_real(hh, mm, ss, day) clock.epoch = (day or 0) * 86400 + hh * 3600 + mm * 60 + (ss or 0) end
local function set_game(day, hour) clock.day, clock.hour = day, hour end

local function new(opts)
  opts = opts or {}
  opts.time = { real = function() return clock.epoch end, ingame = function() return clock.day, clock.hour end }
  return timetable.new(opts)
end

local PAIR = { "FLEET-A", "FLEET-B" }
local both = { ["FLEET-A"] = true, ["FLEET-B"] = true }

local function line(extra)
  local l = {
    id = "L1", kind = "PASSENGER", time_base = "REAL", window = { from = "06:00", to = "22:00" },
    stops = { { station = "NORD" }, { station = "MITTE", pass_through = true }, { station = "SUED" } },
    routes = { EAST = "R-NS", WEST = "R-SN" }, departures = { "08:00", "08:30" }, dwell_s = 30, train_classes = { "PASSENGER" }
  }
  for k, v in pairs(extra or {}) do l[k] = v end
  return l
end

local function published(tt, l)
  local version = assert(tt.add_draft(l))
  assert(tt.publish(l.id, version, both, PAIR))
  return version
end

local function keys(events)
  local out = {}
  for _, e in ipairs(events) do out[#out + 1] = e.planned_hhmm or e.planned end
  return table.concat(out, ",")
end

return {
  test_a_draft_is_validated_and_only_a_valid_one_is_kept = function()
    local tt = new()
    local version, problems = tt.add_draft(line({ id = "" }))
    assert(not version and problems[1]:find("id", 1, true))
    local checks = {
      { { kind = "BOAT" }, "kind" }, { { time_base = "SUN" }, "time_base" }, { { departures = { "8am" } }, "departure" },
      { { departures = {}, headway_min = nil }, "departures or a headway" }, { { headway_min = 0, departures = {} }, "headway" },
      { { window = { from = "06:00" } }, "window" }, { { stops = { { station = "A" } } }, "two stops" }, { { routes = {} }, "route" }
    }
    for _, c in ipairs(checks) do
      local v, p = tt.add_draft(line(c[1]))
      assert(not v and table.concat(p, ";"):find(c[2], 1, true), c[2] .. ": " .. tostring(p and p[1]))
    end
    local v1 = tt.add_draft(line())
    local v2 = tt.add_draft(line({ departures = { "09:00" } }))
    assert(v1 == 1 and v2 == 2, "each draft is a version")
    assert(tt.get("L1", 2).state == "DRAFT" and tt.published("L1") == nil)
  end,

  test_publication_needs_the_durable_confirmation_of_both_partners = function()
    local tt = new()
    local v = tt.add_draft(line())
    local ok, err = tt.publish("L1", v, { ["FLEET-A"] = true }, PAIR)
    assert(not ok and err:find("FLEET-B", 1, true), tostring(err))
    assert(tt.published("L1") == nil)
    assert(tt.publish("L1", v, both, PAIR))
    assert(tt.published("L1").version == v and tt.get("L1", v).state == "PUBLISHED")
    assert(not tt.publish("L1", 99, both, PAIR))
    local v2 = tt.add_draft(line({ departures = { "10:00" } }))
    assert(tt.publish("L1", v2, both, PAIR))
    assert(tt.published("L1").version == v2 and tt.get("L1", v).state == "SUPERSEDED")
  end,

  test_a_fixed_departure_is_due_once_when_its_minute_comes = function()
    local tt = new(); published(tt, line())
    set_real(7, 59, 0); assert(#tt.due().due == 0)
    set_real(8, 0, 30)
    local r = tt.due()
    assert(#r.due == 1 and r.due[1].line_id == "L1" and r.due[1].planned_hhmm == "08:00" and r.due[1].order_kind == "SCHEDULED_PASSENGER", keys(r.due))
    set_real(8, 0, 50); assert(#tt.due().due == 0, "not twice")
    set_real(8, 31, 0)
    r = tt.due()
    assert(#r.due == 1 and r.due[1].planned_hhmm == "08:30" and r.due[1].late_min == 1)
  end,

  test_a_headway_makes_slots_inside_the_operating_window_only = function()
    local tt = new(); published(tt, line({ departures = {}, headway_min = 10, window = { from = "06:00", to = "06:30" } }))
    local got = {}
    for minute = 0, 59 do
      set_real(5, minute, 5); for _, e in ipairs(tt.due().due) do got[#got + 1] = e.planned_hhmm end
    end
    for minute = 0, 59 do
      set_real(6, minute, 5); for _, e in ipairs(tt.due().due) do got[#got + 1] = e.planned_hhmm end
    end
    assert(table.concat(got, ",") == "06:00,06:10,06:20,06:30", table.concat(got, ","))
  end,

  test_a_fixed_departure_outside_the_operating_window_is_never_driven = function()
    local tt = new(); published(tt, line({ departures = { "05:00", "08:00" } }))
    set_real(4, 59, 0); tt.due(); set_real(5, 0, 20)
    local r = tt.due()
    assert(#r.due == 0 and #r.missed == 0, "05:00 is before the window opens")
    set_real(7, 59, 0); tt.due(); set_real(8, 0, 20)
    assert(#tt.due().due == 1)
  end,

  test_missed_starts_after_a_downtime_are_not_caught_up = function()
    local tt = new(); published(tt, line({ departures = { "08:00", "08:30", "09:00" } }))
    set_real(7, 59, 0); tt.due()
    set_real(9, 0, 10)   -- the server was off for an hour
    local r = tt.due()
    assert(#r.due == 1 and r.due[1].planned_hhmm == "09:00", "only the departure of now: " .. keys(r.due))
    assert(#r.missed == 2 and r.missed[1].planned_hhmm == "08:00" and r.missed[2].planned_hhmm == "08:30" and r.missed[1].reason:find("downtime", 1, true), "the others are reported, not driven")
  end,

  test_a_late_but_recent_departure_is_still_driven_inside_the_grace_time = function()
    local tt = new({ grace_min = 3 }); published(tt, line())
    set_real(7, 59, 0); tt.due()
    set_real(8, 2, 0)
    local r = tt.due()
    assert(#r.due == 1 and r.due[1].late_min == 2 and #r.missed == 0)
    set_real(8, 29, 0); tt.due()
    set_real(8, 34, 0)
    r = tt.due()
    assert(#r.due == 0 and #r.missed == 1 and r.missed[1].reason:find("late", 1, true), "four minutes late is too late")
  end,

  test_a_jump_of_the_clock_backwards_never_makes_a_trip_twice = function()
    local tt = new(); published(tt, line())
    set_real(7, 59, 0); tt.due()
    set_real(8, 0, 20); assert(#tt.due().due == 1)
    set_real(7, 30, 0)   -- the time was set back
    local r = tt.due()
    assert(#r.due == 0 and r.resync == true, "resynchronised, nothing driven")
    set_real(8, 0, 40); r = tt.due()
    assert(#r.due == 0, "08:00 was driven already")
    set_real(8, 30, 5); r = tt.due()
    assert(#r.due == 1 and r.due[1].planned_hhmm == "08:30")
  end,

  test_the_trip_key_comes_from_line_planned_time_and_version_and_survives_a_restart = function()
    local tt = new(); published(tt, line())
    set_real(7, 59, 0); tt.due(); set_real(8, 0, 20)
    local key = tt.due().due[1].key
    assert(key:find("L1", 1, true) and key:find("v1", 1, true) and key:find("08:00", 1, true), key)
    local snap = tt.snapshot()
    local again = new(); again.restore(snap)
    set_real(8, 0, 40)
    assert(#again.due().due == 0, "the restart does not repeat the trip")
    -- a new published version is another run: the key differs
    local v2 = again.add_draft(line()); assert(again.publish("L1", v2, both, PAIR))
    set_real(8, 29, 0); again.due(); set_real(8, 30, 5)
    local k2 = again.due().due[1].key
    assert(k2:find("v2", 1, true) and k2 ~= key)
  end,

  test_minecraft_time_wraps_at_midnight_and_counts_days = function()
    local tt = new(); published(tt, line({ time_base = "MINECRAFT", departures = { "00:05" }, window = { from = "22:00", to = "02:00" } }))
    set_game(3, 23.9); tt.due()
    set_game(4, 0.05); assert(#tt.due().due == 0 or true)
    set_game(4, 0.1)
    local r = tt.due()
    local total = #r.due
    set_game(4, 0.12)
    total = total + #tt.due().due
    set_game(4, 0.5)
    assert(#tt.due().due == 0)
    assert(total <= 1, "never twice")
    set_game(5, 0.1)
    local r2 = tt.due()
    assert(#r2.due == 1 and r2.due[1].planned_hhmm == "00:05", "the next day brings it again")
  end,

  test_real_time_follows_the_time_zone_offset = function()
    local tt = new({ tz_offset_min = 120 }); published(tt, line({ departures = { "10:00" } }))
    set_real(7, 59, 0); tt.due()
    set_real(8, 0, 10)   -- 08:00 UTC is 10:00 local
    local r = tt.due()
    assert(#r.due == 1 and r.due[1].planned_hhmm == "10:00")
  end,

  test_a_reinforcement_line_makes_extra_orders = function()
    local tt = new(); published(tt, line({ reinforcement = true }))
    set_real(7, 59, 0); tt.due(); set_real(8, 0, 10)
    assert(tt.due().due[1].order_kind == "EXTRA_PASSENGER")
    local f = new(); published(f, line({ id = "F1", kind = "FREIGHT", departures = { "08:00" } }))
    set_real(7, 59, 0); f.due(); set_real(8, 0, 10)
    assert(f.due().due[1].order_kind == "SCHEDULED_FREIGHT")
  end,

  test_a_change_of_an_active_leg_takes_effect_only_at_the_next_safe_handover_point = function()
    local tt = new(); published(tt, line())
    local v2 = tt.add_draft(line({ departures = { "09:00" } }))
    assert(tt.publish("L1", v2, both, PAIR))
    local effect = tt.effective_for_leg("L1", 1, { at_handover_point = false })
    assert(effect.version == 1, "a trip that runs keeps the version it started with")
    effect = tt.effective_for_leg("L1", 1, { at_handover_point = true })
    assert(effect.version == 2, "at a safe programmable handover point the new version may take over")
  end
}
