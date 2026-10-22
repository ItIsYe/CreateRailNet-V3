--[[
Purpose: What the operator changes from the panel reaches the fleet pair and becomes binding only when both nodes hold it: a draft of a line, its publication against the version it was made on, the cancel of a trip, and the status the master gets (Gesamtkonzept Kap. 9, 11.5; Pruefplan D-10, H-12).
Public API: returns table of tests.
]]

pcall(dofile, "tests/harness/cc_bootstrap.lua")

local fleet_world = require("tests.harness.fleet_world")

local A, B = fleet_world.A, fleet_world.B

local function with_world(opts, fn)
  local w = fleet_world.new(opts)
  local ok, err = pcall(fn, w)
  w.close()
  if not ok then error(err, 0) end
end

local function line(extra)
  local l = { id = "L1", kind = "PASSENGER", time_base = "REAL", window = { from = "06:00", to = "22:00" }, departures = { "08:00", "09:30" }, dwell_s = 30,
    stops = { { station = "NORD" }, { station = "SUED" } }, routes = { EAST = "R-NS" }, origin = "NORD", goal = "SUED", direction = "EAST" }
  for k, v in pairs(extra or {}) do l[k] = v end
  return l
end

local function results(w) local out = {} for _, p in ipairs(w.master.inbox) do if p.type == "fleet_admin_result" then out[#out + 1] = p end end return out end

return {
  test_a_draft_is_taken_as_a_new_version_and_does_not_run_before_it_is_published = function()
    with_world({}, function(w)
      w.run(20000)
      w.master.send_admin({ request_id = "r1", op = "timetable_draft", line = line({ departures = { "08:00", "09:30" } }) })
      w.run(3000)
      local r = results(w)[1]
      assert(r and r.ok == true and r.line_id == "L1" and r.version == 2 and r.request_id == "r1", r and tostring(r.reason))
      local published = w.nodes[A].engine.report().lines.L1
      assert(published.version == 1 and published.drafts[1] == 2, "version 1 keeps running, 2 waits as a draft")
      assert(#published.departures == 1)
    end)
  end,

  test_a_bad_draft_is_refused_with_its_problems_and_changes_nothing = function()
    with_world({}, function(w)
      w.run(20000)
      w.master.send_admin({ request_id = "r2", op = "timetable_draft", line = line({ stops = { { station = "NORD" } } }) })
      w.run(3000)
      local r = results(w)[1]
      assert(r and r.ok == false and r.problems and r.problems[1]:find("two stops", 1, true))
      assert(#w.nodes[A].engine.report().lines.L1.drafts == 0)
    end)
  end,

  test_a_publication_waits_for_the_partner_and_then_replaces_the_running_version_on_both_nodes = function()
    with_world({}, function(w)
      w.run(20000)
      w.master.send_admin({ request_id = "d", op = "timetable_draft", line = line({ departures = { "08:00", "09:30" } }) })
      w.run(3000)
      w.master.send_admin({ request_id = "p", op = "timetable_publish", line_id = "L1", version = 2, base_version = 1 })
      w.run(5000)
      local r = results(w)[2]
      assert(r and r.ok == true and r.version == 2, r and tostring(r.reason))
      assert(w.nodes[A].engine.report().lines.L1.version == 2 and #w.nodes[A].engine.report().lines.L1.departures == 2)
      w.run(5000)
      assert(w.nodes[B].replica.committed_idx() == w.nodes[A].replica.committed_idx(), "the partner holds it durably")
    end)
  end,

  test_a_draft_made_on_an_old_version_is_a_conflict_and_nothing_is_published = function()
    with_world({}, function(w)
      w.run(20000)
      w.master.send_admin({ request_id = "d", op = "timetable_draft", line = line() })
      w.run(3000)
      w.master.send_admin({ request_id = "p", op = "timetable_publish", line_id = "L1", version = 2, base_version = 7 })
      w.run(3000)
      local r = results(w)[2]
      assert(r and r.ok == false and r.conflict == true and r.reason:find("conflict", 1, true), r and tostring(r.reason))
      assert(w.nodes[A].engine.report().lines.L1.version == 1)
    end)
  end,

  test_the_publication_is_not_made_while_the_partner_is_away_and_can_be_repeated_when_it_is_back = function()
    with_world({}, function(w)
      w.run(20000)
      w.master.send_admin({ request_id = "d", op = "timetable_draft", line = line({ departures = { "08:00", "09:30" } }) })
      w.run(3000)
      w.crash(B)
      w.run(20000)
      w.master.send_admin({ request_id = "p", op = "timetable_publish", line_id = "L1", version = 2, base_version = 1 })
      w.run(3000)
      local refused = results(w)[2]
      assert(refused and refused.ok == false and refused.reason:find("not healthy", 1, true), refused and tostring(refused.reason))
      assert(w.nodes[A].engine.report().lines.L1.version == 1, "no publication without the partner")
      w.restart(B)
      w.run(40000)
      w.master.send_admin({ request_id = "p2", op = "timetable_publish", line_id = "L1", version = 2, base_version = 1 })
      w.run(5000)
      local r = results(w)[3]
      assert(r and r.ok == true and w.nodes[A].engine.report().lines.L1.version == 2, r and tostring(r.reason))
    end)
  end,

  test_the_standby_and_a_stranger_do_not_take_operator_commands = function()
    with_world({}, function(w)
      w.run(20000)
      w.master.send_admin({ request_id = "s", op = "timetable_draft", line = line() }, B)
      w.run(3000)
      local r = results(w)[1]
      assert(r and r.ok == false and r.reason:find("standby", 1, true))
      assert(#w.nodes[B].engine.report().lines.L1.drafts == 0)
      w.master.send_admin({ request_id = "x", op = "launch_rocket" })
      w.run(3000)
      assert(results(w)[2].ok == false and results(w)[2].reason:find("unknown operation", 1, true))
    end)
  end,

  test_the_active_node_reports_lines_trips_and_cargo_to_the_master = function()
    with_world({}, function(w)
      w.run(20000)
      local status = w.master.last("fleet_status")
      assert(status and status.pair_id == "P1" and status.report.lines.L1.version == 1 and status.report.lines.L1.departures[1] == "08:00")
      assert(status.healthy == true)
      w.run(130000)
      local later = w.master.last("fleet_status")
      local count = 0
      for _, t in pairs(later.report.trips) do count = count + 1 end
      assert(count == 1, "the trip of 08:00 is in the report")
    end)
  end,

  test_cancelling_a_trip_goes_through_the_engine = function()
    with_world({}, function(w)
      w.run(130000)
      local trip = w.nodes[A].engine.trips()[1]
      assert(trip)
      w.master.send_admin({ request_id = "c", op = "trip_cancel", trip_id = trip.trip_id, who = "ED" })
      w.run(3000)
      local r = results(w)[1]
      assert(r and r.ok == true, r and tostring(r.reason))
      assert(w.nodes[A].engine.trips()[1].state == "CANCELLED")
    end)
  end,

  test_the_master_forwards_the_operator_commands_to_the_active_node_of_the_pair = function()
    local manual_control = require("src.master.manual_control")
    local sent = {}
    local audits = {}
    local mc = manual_control.new({
      network = { send_reliable = function(kind, dst, payload) sent[#sent + 1] = { kind = kind, dst = dst, payload = payload }; return { id = "m" } end },
      config = { fleet = { pairs = { { id = "P1", nodes = { "FLEET-A", "FLEET-B" } } } } },
      audit_log = { record = function(kind, data) audits[#audits + 1] = { kind = kind, data = data } end }
    })
    local ok, request = mc.handle({ action = "timetable_draft", pair_id = "P1", line = { id = "L1" }, operator = "ED" }, "PANEL-1")
    assert(ok == true and request == "REQ-1-P1")
    assert(sent[1].dst == "FLEET-A" and sent[1].kind == "cmd" and sent[1].payload.cmd == "fleet_admin" and sent[1].payload.op == "timetable_draft" and sent[1].payload.line.id == "L1" and sent[1].payload.request_id == request)
    local ok2, request2 = mc.handle({ action = "timetable_publish", pair_id = "P1", line_id = "L1", version = 2, base_version = 1 }, "PANEL-1")
    assert(ok2 and request2 == "REQ-2-P1" and sent[2].payload.base_version == 1 and sent[2].payload.version == 2)
    assert(mc.handle({ action = "trip_cancel", pair_id = "P1", trip_id = "P1-T1" }, "PANEL-1") == true)
    assert(mc.handle({ action = "timetable_draft", pair_id = "NOPE" }, "PANEL-1") == false)
    local draft_audit
    for _, a in ipairs(audits) do if a.kind == "timetable_draft" then draft_audit = a end end
    assert(draft_audit and draft_audit.data.by == "ED" and draft_audit.data.request_id == "REQ-1-P1")
  end,

  test_the_actions_of_the_editor_need_the_admin_level_and_the_publication_a_confirmation = function()
    local permissions = require("src.panel.permissions")
    local cfg = { nodes = { { id = "OP", role = "panel", permission = "operate" }, { id = "AD", role = "panel", permission = "admin" } } }
    assert(not permissions.check(cfg, "OP", "timetable_draft", {}) and permissions.check(cfg, "AD", "timetable_draft", {}))
    assert(not permissions.check(cfg, "AD", "timetable_publish", {}) and permissions.check(cfg, "AD", "timetable_publish", { confirm = true }))
    assert(permissions.check(cfg, "OP", "trip_cancel", {}), "an operator may cancel a trip")
  end
}
