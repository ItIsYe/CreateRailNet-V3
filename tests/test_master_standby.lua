--[[
Purpose: A master that is not the leader keeps the registry and the pairing but does not touch the dispatcher; the election messages reach the election; a change of leadership is audited
  and shown (Gesamtkonzept Kap. 5.1, 5.3).
Public API: returns table of tests.
]]

pcall(dofile, "tests/harness/cc_bootstrap.lua")

local runtime_factory = require("src.master.runtime")
local registry_factory = require("src.shared.registry")
local alerts_module = require("src.domain.alerts")

local NODES = {
  { id = "M", role = "master" }, { id = "M2", role = "master" }, { id = "ARB", role = "arbiter" },
  { id = "SIG-1", role = "signal" }, { id = "SEN-1", role = "sensor" }, { id = "TRAIN-1", role = "train" }, { id = "ST-1", role = "station" },
}

local function master(leader)
  local env = { calls = {}, audits = {}, now = 1000, leader = leader, election_messages = {}, ticks = 0 }
  local function count(name) env.calls[name] = (env.calls[name] or 0) + 1 end
  env.registry = registry_factory.new()
  env.alerts = alerts_module.new()
  env.ha = {
    is_leader = function() return env.leader end, term = function() return 4 end, tick = function() env.ticks = env.ticks + 1 end,
    handle = function(msg) if msg.payload and msg.payload.cmd == "election" then env.election_messages[#env.election_messages + 1] = msg; return true end return false end,
  }
  env.runtime = runtime_factory.new({
    config = { v = 1, channel = 1, master_id = "M", masters = { "M", "M2" }, arbiter = "ARB", blocks = {}, routes = {}, nodes = NODES },
    registry = env.registry, ha = env.ha,
    dispatcher = {
      get_overview = function() return {} end, timeout_node = function() count("timeout_node") end,
      on_sensor_event_by_sensor = function() count("sensor"); return true end, snapshot = function() return {} end,
      refresh_signals = function() count("refresh"); return { failed = 0, failed_blocks = {} } end, auto_clear_faults = function() count("auto_clear"); return {} end,
    },
    network = {
      receive = function() return "ok" end, ack_for = function() count("ack") end, tick = function() end,
      send = function() end, send_reliable = function() end, peer_revision = function() return 5 end,
    },
    ui = { mark_dirty = function() end, draw = function() end, handle_touch = function() end },
    audit_log = { record = function(kind, data) env.audits[#env.audits + 1] = { kind = kind, data = data } end },
    alerts = env.alerts,
    manual_control = { handle = function() count("manual"); return true end },
    route_integration = {
      handle_train_request = function() count("train_request"); return true end, handle_train_arrival = function() count("train_arrival") end,
      handle_station_ready = function() count("station_ready") end, handle_depot_request = function() count("depot_request") end,
      send_service_plan = function() end, process_queue = function() end, process_due = function() count("due") end,
    },
    train_registry = { update_status = function() end, register = function() end, list = function() return {} end, mark_offline = function() end },
    station_registry = { update_status = function() end, register = function() end, update_platform = function() end, list = function() return {} end, mark_offline = function() end },
    depot_registry = { update_status = function() end, register = function() end, update_track = function() end, list = function() return {} end, mark_offline = function() end },
    service_plan_registry = { list = function() return {} end },
    clock = function() return env.now end, start_timer = function() return 1 end, auto_restore_state = false, auto_save_state = false,
  })
  local counter = 0
  function env.deliver(src, kind, payload)
    counter = counter + 1
    env.runtime.handle_event({ "modem_message", nil, nil, nil, { v = 1, pv = 5, id = src .. "." .. kind .. counter, type = kind, src = src, dst = "M", payload = payload } })
  end
  function env.advance(seconds)
    env.now = env.now + seconds
    env.runtime.handle_event({ "timer", 999 })
  end
  function env.audited(kind) for _, a in ipairs(env.audits) do if a.kind == kind then return a end end return nil end
  return env
end

local OBSERVATIONS = {
  { "SEN-1", { type = "sensor", sensor_id = "SEN-1", action = "enter" }, "sensor" },
  { "TRAIN-1", { type = "request_departure", train_id = "TRAIN-1", route_id = "R1" }, "train_request" },
  { "ST-1", { type = "station_ready_departure", station_id = "ST-1" }, "station_ready" },
}

return {
  test_the_leader_acts_on_events_as_before = function()
    local m = master(true)
    for _, item in ipairs(OBSERVATIONS) do m.deliver(item[1], "event", item[2]) end
    assert(m.calls.sensor == 1 and m.calls.train_request == 1 and m.calls.station_ready == 1)
  end,

  test_the_standby_takes_events_in_and_leaves_the_decisions_to_the_leader = function()
    local m = master(false)
    for _, item in ipairs(OBSERVATIONS) do m.deliver(item[1], "event", item[2]) end
    assert(m.calls.sensor == nil and m.calls.train_request == nil and m.calls.station_ready == nil, "the dispatcher is not touched")
    assert(m.calls.ack == 3, "every event is acknowledged so the sender stops retrying")
  end,

  test_the_standby_still_keeps_the_registry = function()
    local m = master(false)
    m.deliver("SIG-1", "heartbeat", { role = "signal" })
    local node = m.registry.all()["SIG-1"]
    assert(node and tostring(node.status):upper() == "UP")
  end,

  test_the_standby_marks_a_silent_node_down_but_does_not_tell_the_dispatcher = function()
    local standby, leader = master(false), master(true)
    for _, m in ipairs({ standby, leader }) do
      m.deliver("SIG-1", "heartbeat", { role = "signal" })
      m.registry.all()["SIG-1"].last_seen = 0 -- silent for a very long time (the registry counts in wall-clock seconds)
      m.runtime.start()
      m.advance(30)
    end
    assert(tostring(standby.registry.all()["SIG-1"].status):upper() == "DOWN", "the registry follows the silence on both")
    assert(standby.calls.timeout_node == nil, "the standby does not decide what a silent node means for the blocks")
    assert(leader.calls.timeout_node == 1)
  end,

  test_the_standby_does_not_run_the_dispatcher_jobs = function()
    local standby, leader = master(false), master(true)
    for _, m in ipairs({ standby, leader }) do
      m.runtime.start()
      m.advance(3)
    end
    assert(standby.calls.refresh == nil and standby.calls.auto_clear == nil and standby.calls.due == nil, "no signal refresh, no auto clear, no dwell on the standby")
    assert(leader.calls.refresh and leader.calls.auto_clear and leader.calls.due)
  end,

  test_election_messages_go_to_the_election_and_other_commands_do_not = function()
    local m = master(false)
    m.deliver("M2", "cmd", { cmd = "election", kind = "lead_beat", term = 4 })
    m.deliver("M2", "cmd", { cmd = "something" })
    assert(#m.election_messages == 1)
  end,

  test_the_election_ticks_and_a_change_of_leadership_is_audited_and_shown = function()
    local m = master(false)
    m.runtime.start()
    m.advance(3)
    assert(m.ticks >= 1)
    assert(m.audited("leader_gained") == nil)
    m.leader = true
    m.advance(3)
    assert(m.audited("leader_gained") and m.audited("leader_gained").data.term == 4)
    local found
    for _, alert in ipairs(m.alerts.list({ active_only = true })) do if alert.key == "ha:leader" then found = alert end end
    assert(found and found.text:find("fuehrt jetzt", 1, true), "the operator sees it")
    m.leader = false
    m.advance(3)
    assert(m.audited("leader_lost"))
  end,

  test_a_master_without_a_partner_has_no_election_and_acts_always = function()
    local env = master(true)
    local single = runtime_factory.new({
      config = { v = 1, channel = 1, master_id = "M", blocks = {}, routes = {}, nodes = { { id = "M", role = "master" }, { id = "SEN-1", role = "sensor" } } },
      registry = registry_factory.new(), dispatcher = { get_overview = function() return {} end, timeout_node = function() end, on_sensor_event_by_sensor = function() env.calls.single = (env.calls.single or 0) + 1; return true end, snapshot = function() return {} end },
      network = { receive = function() return "ok" end, ack_for = function() end, tick = function() end, send = function() end, send_reliable = function() end },
      ui = { mark_dirty = function() end, draw = function() end, handle_touch = function() end }, audit_log = { record = function() end },
      clock = function() return 1 end, start_timer = function() return 1 end, auto_restore_state = false, auto_save_state = false,
    })
    assert(single.active() == true)
    single.handle_event({ "modem_message", nil, nil, nil, { v = 1, pv = 5, id = "s1", type = "event", src = "SEN-1", dst = "M", payload = { type = "sensor", sensor_id = "SEN-1", action = "enter" } } })
    assert(env.calls.single == 1)
  end
}
