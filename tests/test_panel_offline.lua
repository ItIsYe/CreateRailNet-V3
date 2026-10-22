--[[
Purpose: The panel without its master: drafts go on, nothing is published or commanded, old wishes are not carried out afterwards, the way back checks identity, versions, permissions and asks again (Gesamtkonzept Kap. 11.5).
Public API: returns table of tests.
]]

local offline = require("src.panel.offline")

local clock = { t = 0 }
local function new(opts)
  clock.t = 0
  opts = opts or {}
  opts.now = function() return clock.t end
  return offline.new(opts)
end

local function master(extra)
  local m = { id = "MASTER-1", epoch = 4, topology_version = "abc", authenticated = true, versions = { layout = 3, timetable = 7 } }
  for k, v in pairs(extra or {}) do m[k] = v end
  return m
end

return {
  test_a_panel_is_offline_until_it_has_heard_its_master_and_again_when_the_master_is_silent = function()
    local o = new({ timeout_s = 10 })
    assert(o.state() == "OFFLINE", "nothing heard yet")
    o.heard(master())
    assert(o.state() == "ONLINE")
    clock.t = 9; o.tick(); assert(o.state() == "ONLINE")
    clock.t = 11; o.tick(); assert(o.state() == "OFFLINE")
  end,

  test_what_is_heard_from_a_computer_that_is_not_authentic_does_not_bring_the_panel_online = function()
    local o = new()
    o.heard(master({ authenticated = false }))
    assert(o.state() == "OFFLINE")
    o.heard(master({ id = "SOMEONE" }), { expected_master = "MASTER-1" })
    assert(o.state() == "OFFLINE")
  end,

  test_offline_drafts_are_edited_but_publishing_and_commands_are_not_allowed = function()
    local o = new()
    local ok, why = o.may("publish")
    assert(not ok and why:find("offline", 1, true), tostring(why))
    assert(not o.may("control") and not o.may("maintenance"))
    assert(o.may("edit_draft") == true and o.may("read") == true)
    o.heard(master())
    assert(o.may("publish") and o.may("control"))
    assert(not o.may("fly"), "an unknown kind is refused")
  end,

  test_wishes_made_offline_are_kept_for_the_eye_and_never_carried_out = function()
    local o = new()
    local sent = {}
    assert(o.wish({ action = "request_route", train_id = "T1", route_id = "R1" }, function(a) sent[#sent + 1] = a end) == false, "offline: not sent")
    assert(#sent == 0 and #o.wishes() == 1 and o.wishes()[1].action == "request_route")
    o.heard(master())
    assert(o.state() == "RECONCILING", "the way back goes through a reconciliation")
    local result = o.begin_reconcile(master(), { layout = 3, timetable = 7 })
    assert(#result.discarded_wishes == 1 and #o.wishes() == 0, "old wishes are dropped and shown, not executed")
    assert(#sent == 0)
  end,

  test_online_a_wish_is_sent_at_once = function()
    local o = new()
    o.heard(master()); o.begin_reconcile(master(), { layout = 3, timetable = 7 }); assert(o.finish({ confirmed = true }, function() return true end))
    local sent = {}
    assert(o.wish({ action = "request_route" }, function(a) sent[#sent + 1] = a; return true end) == true and #sent == 1)
  end,

  test_a_draft_made_on_an_old_version_is_a_conflict_that_a_person_has_to_resolve = function()
    local o = new()
    o.set_base("layout", 2); o.set_base("timetable", 7)
    o.heard(master())
    local result = o.begin_reconcile(master(), { layout = 2, timetable = 7 })
    assert(#result.conflicts == 1 and result.conflicts[1].what == "layout" and result.conflicts[1].local_version == 2 and result.conflicts[1].master_version == 3)
    local ok, err = o.finish({ confirmed = true }, function() return true end)
    assert(not ok and err:find("conflict", 1, true), tostring(err))
    assert(o.state() == "RECONCILING")
    assert(not o.resolve("timetable", "keep_local"), "no such conflict")
    assert(o.resolve("layout", "keep_master") == true)
    assert(o.finish({ confirmed = true }, function() return true end) == true and o.state() == "ONLINE")
  end,

  test_the_way_back_checks_the_identity_the_permissions_and_asks_again = function()
    local o = new()
    o.heard(master())
    o.begin_reconcile(master({ epoch = 5 }), { layout = 3, timetable = 7 })
    local ok, err = o.finish(nil, function() return true end)
    assert(not ok and err:find("confirm", 1, true), tostring(err))
    ok, err = o.finish({ confirmed = true }, function() return false, "the level was lowered" end)
    assert(not ok and err:find("lowered", 1, true), "permissions are checked again: " .. tostring(err))
    assert(o.state() == "RECONCILING")
    assert(o.finish({ confirmed = true }, function() return true end))
    assert(o.master_epoch() == 5, "the panel knows the epoch it is talking to now")
  end,

  test_a_new_topology_while_offline_is_a_conflict_for_the_layouts = function()
    local o = new()
    o.set_topology("abc")
    o.heard(master({ topology_version = "xyz" }))
    local result = o.begin_reconcile(master({ topology_version = "xyz" }), { layout = 3, timetable = 7 })
    assert(#result.conflicts == 1 and result.conflicts[1].what == "topology")
    assert(o.resolve("topology", "carry_over") == true)
    assert(o.finish({ confirmed = true }, function() return true end))
  end,

  test_stale_data_is_labelled_and_never_a_proof = function()
    local o = new({ stale_after_s = 30 })
    local fresh = o.freshness(10)
    assert(fresh.stale == false and fresh.label == "aktuell")
    local old = o.freshness(95)
    assert(old.stale == true and old.label:find("95", 1, true) and old.proof == false, old.label)
    assert(o.freshness(nil).stale == true and o.freshness(nil).label:find("unbekannt", 1, true))
  end
}
