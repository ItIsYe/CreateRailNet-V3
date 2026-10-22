--[[
Purpose: The timetable editor of the panel: small steps on a draft, a check before anything is sent, a draft that survives a restart of the panel, and a conflict when the line moved on meanwhile (Pruefplan D-10, H-09, H-10, H-12).
Public API: returns table of tests.
]]

local timetable_editor = require("src.panel.timetable_editor")
local memfs = require("tests.harness.memfs")

local function reported(extra)
  local l = { version = 4, kind = "PASSENGER", time_base = "REAL", window = { from = "06:00", to = "22:00" }, headway_min = 10, dwell_s = 30,
    stops = { { station = "NORD" }, { station = "SUED" } }, routes = { EAST = "R-NS" }, direction = "EAST", drafts = { 5 }, pair_id = "P1" }
  for k, v in pairs(extra or {}) do l[k] = v end
  return l
end

local function open(extra)
  local e = timetable_editor.new({ fs = memfs.new() })
  assert(e.open("L1", reported(extra)))
  return e
end

return {
  test_the_draft_starts_as_the_published_line_without_what_only_the_fleet_fills_in = function()
    local e = open()
    local d = e.draft()
    assert(d.id == "L1" and d.headway_min == 10 and d.window.from == "06:00" and d.version == nil and d.drafts == nil and d.pair_id == nil)
    assert(not e.dirty() and #e.changes() == 0 and e.base_version() == 4)
  end,

  test_the_buttons_change_the_draft_in_small_steps_and_the_changes_are_listed = function()
    local e = open()
    assert(e.adjust("headway_min", -1) and e.adjust("headway_min", -1) and e.adjust("dwell_s", 5) and e.adjust("window_from", 30) and e.adjust("window_to", -30))
    local d = e.draft()
    assert(d.headway_min == 8 and d.dwell_s == 35 and d.window.from == "06:30" and d.window.to == "21:30")
    assert(e.dirty())
    local text = table.concat(e.changes(), "\n")
    assert(text:find("Takt (min): 10 -> 8", 1, true) and text:find("Haltezeit (s): 30 -> 35", 1, true) and text:find("Fenster von: 06:00 -> 06:30", 1, true))
    assert(#e.validate() == 0)
  end,

  test_a_step_that_makes_no_sense_is_refused_and_changes_nothing = function()
    local e = open()
    for _ = 1, 9 do assert(e.adjust("headway_min", -1)) end
    local ok, err = e.adjust("headway_min", -1)
    assert(ok == false and err:find("at least 1", 1, true) and e.draft().headway_min == 1)
    assert(not e.adjust("dwell_s", -100) and e.draft().dwell_s == 30)
    assert(not e.adjust("nonsense", 1) and not e.adjust("headway_min", "x"))
    assert(not e.adjust("departures", 5), "no fixed departures on this line")
    local closed = timetable_editor.new()
    assert(not closed.adjust("headway_min", 1) and closed.draft() == nil)
  end,

  test_fixed_departures_are_shifted_together_and_wrap_around_midnight = function()
    local e = open({ headway_min = false, departures = { "08:00", "23:58" } })
    e.reset()
    assert(e.open("L1", { version = 1, kind = "PASSENGER", time_base = "REAL", window = { from = "06:00", to = "22:00" }, departures = { "08:00", "23:58" }, stops = { { station = "A" }, { station = "B" } }, routes = { EAST = "R" } }))
    assert(e.adjust("departures", 5))
    assert(e.draft().departures[1] == "08:05" and e.draft().departures[2] == "00:03")
    assert(not e.adjust("headway_min", 1), "a line with fixed departures has no headway")
    local cut = timetable_editor.new()
    cut.open("L2", { version = 1, kind = "PASSENGER", time_base = "REAL", window = { from = "06:00", to = "22:00" }, departures = { "08:00" }, departures_truncated = true, stops = { { station = "A" }, { station = "B" } }, routes = { EAST = "R" } })
    local ok, err = cut.adjust("departures", 5)
    assert(ok == false and err:find("cut off", 1, true))
  end,

  test_the_check_finds_what_the_fleet_would_refuse = function()
    local e = open()
    e.adjust("window_from", 60 * 24 * 0)
    local d = e.draft()
    assert(#e.validate() == 0)
    local broken = open({ stops = { { station = "NORD" } } })
    local problems = broken.validate()
    assert(#problems > 0 and problems[1]:find("two stops", 1, true))
  end,

  test_a_published_version_that_moved_on_is_a_conflict_until_a_person_decides = function()
    local e = open()
    e.adjust("dwell_s", 5)
    assert(not e.conflict(4))
    assert(e.conflict(5), "another control room published meanwhile")
    assert(e.rebase(5) and e.base_version() == 5 and not e.conflict(5) and e.dirty(), "keep the changes on the new version")
    assert(not e.rebase("x"))
    e.reset()
    assert(e.draft() == nil and not e.dirty() and not e.conflict(9))
  end,

  test_what_was_sent_is_forgotten_when_the_draft_changes_again = function()
    local e = open()
    e.adjust("dwell_s", 5)
    e.sent("REQ-1-P1")
    assert(e.sent_request() == "REQ-1-P1")
    e.adjust("dwell_s", 5)
    assert(e.sent_request() == nil)
  end,

  test_the_draft_survives_a_restart_of_the_panel_and_a_damaged_file_is_not_believed = function()
    local fs = memfs.new()
    local e = timetable_editor.new({ fs = fs })
    assert(e.load() == "empty")
    e.open("L1", reported())
    e.adjust("headway_min", -2)
    assert(e.save())
    local again = timetable_editor.new({ fs = fs })
    assert(again.load() == "ready" and again.line_id() == "L1" and again.base_version() == 4 and again.draft().headway_min == 8 and again.dirty())
    fs.set("state/panel_timetable_draft.json", "{{{")
    fs.set("state/panel_timetable_draft.json.prev", "{{{")
    local broken = timetable_editor.new({ fs = fs })
    assert(broken.load() == "corrupt" and broken.draft() == nil)
  end
}
