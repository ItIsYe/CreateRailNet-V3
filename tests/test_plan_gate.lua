--[[
Purpose: The plan decides who is a node. A computer that is not in the master's plan (or whose id has another role there) can announce
  itself and wait; it is not registered, none of its events is handled, and it gets nothing back but its pairing state. An event type
  belongs to one role. Accepting a computer (the operator's decision) is what makes it a node.
Public API: returns table of tests.
]]

pcall(dofile, "tests/harness/cc_bootstrap.lua")

local runtime_factory = require("src.master.runtime")
local registry_factory = require("src.shared.registry")
local alerts_module = require("src.domain.alerts")
local pairing_module = require("src.master.pairing")
local plan_service_module = require("src.master.plan_service")
local checksum = require("src.shared.checksum")
local log_collector = require("src.domain.log_collector")
local memfs = require("tests.harness.memfs")
local netplan = require("src.setup.netplan")

local PLAN = "configs/network.json"

local function master(opts)
  local o = opts or {}
  local fs = memfs.new()
  local cfg = {
    v = 1, channel = 1, master_id = "M", blocks = {}, routes = {},
    nodes = {
      { id = "M", role = "master" }, { id = "SEN-1", role = "sensor" }, { id = "SIG-1", role = "signal" },
      { id = "TRAIN-1", role = "train" }, { id = "PANEL-1", role = "panel" }, { id = "ST-1", role = "station", create_station_name = "Alpha" }, { id = "DEP-1", role = "depot" },
    },
  }
  fs.set(PLAN, netplan.encode(cfg))
  local env = { fs = fs, cfg = cfg, sent = {}, audits = {}, no_plan_service = o.no_plan_service, calls = { sensor = {}, manual = {}, train = {}, station = {}, depot = {}, ota = {} } }
  env.alerts = alerts_module.new()
  env.logs = log_collector.new()
  env.pairing = pairing_module.new({ config = cfg, plan_path = PLAN, fs = fs })
  env.registry = registry_factory.new()
  local plan_service = nil
  if not o.no_plan_service then plan_service = plan_service_module.new({ plan_path = PLAN, fs = fs, chunk_size = 200 }) end
  env.runtime = runtime_factory.new({
    config = cfg, registry = env.registry,
    dispatcher = {
      get_overview = function() return {} end, timeout_node = function() end,
      on_sensor_event_by_sensor = function(sensor, action) env.calls.sensor[#env.calls.sensor + 1] = sensor .. ":" .. action; return true end,
    },
    network = {
      receive = function() return "ok" end, ack_for = function() end, tick = function() end,
      send = function(kind, dst, payload) env.sent[#env.sent + 1] = { kind = kind, dst = dst, payload = payload } end,
      send_reliable = function(kind, dst, payload) env.sent[#env.sent + 1] = { kind = kind, dst = dst, payload = payload, reliable = true } end,
      peer_revision = function() return 3 end,
    },
    ui = { mark_dirty = function() end, draw = function() end, handle_touch = function() end },
    audit_log = { record = function(kind, data) env.audits[#env.audits + 1] = { kind = kind, data = data } end },
    alerts = env.alerts, pairing = env.pairing, logs = env.logs,
    plan_service = plan_service,
    manual_control = { handle = function(payload, src) env.calls.manual[#env.calls.manual + 1] = src .. ":" .. tostring(payload.action); return true end },
    route_integration = {
      handle_train_request = function(payload, src) env.calls.train[#env.calls.train + 1] = src; return true end,
      process_queue = function() end, process_due = function() end,
    },
    train_registry = { update_status = function(id) env.calls.train[#env.calls.train + 1] = "status:" .. tostring(id) end, register = function() end, list = function() return {} end },
    station_registry = { update_status = function(id) env.calls.station[#env.calls.station + 1] = id end, register = function() end, update_platform = function() end, list = function() return {} end },
    depot_registry = { update_status = function(id) env.calls.depot[#env.calls.depot + 1] = id end, register = function() end, update_track = function() end, list = function() return {} end },
    service_plan_registry = { list = function() return {} end },
    ota = { on_heartbeat = function() env.calls.ota[#env.calls.ota + 1] = "heartbeat" end, on_need = function() env.calls.ota[#env.calls.ota + 1] = "need" end, on_result = function() end, on_confirmed = function() end },
    auto_restore_state = false, auto_save_state = false,
  })
  local counter = 0
  local function deliver(src, kind, payload)
    counter = counter + 1
    env.runtime.handle_event({ "modem_message", nil, nil, nil, { v = 1, pv = 3, id = src .. "." .. kind .. counter, type = kind, src = src, dst = "M", payload = payload } })
  end
  function env.event(src, payload) deliver(src, "event", payload) end
  function env.register(src, role) deliver(src, "register", { role = role }) end
  function env.heartbeat(src, role, extra)
    local payload = { role = role }
    for k, v in pairs(extra or {}) do payload[k] = v end
    deliver(src, "heartbeat", payload)
  end
  function env.rejected(src) for _, a in ipairs(env.audits) do if a.kind == "event_rejected" and (src == nil or a.data.src == src) then return true end end return false end
  function env.snapshots_sent_to(dst) local n = 0; for _, m in ipairs(env.sent) do if m.dst == dst and m.payload.cmd == "panel_update" then n = n + 1 end end return n end
  return env
end

local function none(list) return #list == 0 end

local function parts_to(m, src, role)
  m.event(src, { type = "plan_get", role = role, index = 1 })
  local first
  for _, item in ipairs(m.sent) do if item.kind == "cmd" and item.dst == src and item.payload.cmd == "plan_part" then first = item.payload end end
  return first
end


return {
  test_a_stranger_who_calls_itself_a_panel_cannot_steer = function()
    local m = master()
    m.register("EVIL-1", "panel")
    m.heartbeat("EVIL-1", "panel")
    assert(m.registry.get("EVIL-1") == nil, "not registered")
    assert(m.pairing.get("EVIL-1") and m.pairing.get("EVIL-1").state == "pending", "waits for the operator")
    m.event("EVIL-1", { type = "manual_control", action = "emergency_stop" })
    m.event("EVIL-1", { type = "manual_control", action = "confirm_recovery", reason = "me" })
    assert(none(m.calls.manual) and m.runtime.recovery.confirmed ~= false, "no operator action")
    assert(m.rejected("EVIL-1"))
    m.event("EVIL-1", { type = "panel_request_snapshot" })
    assert(m.snapshots_sent_to("EVIL-1") == 0, "the network is not shown to strangers")
  end,

  test_strangers_cannot_report_trains_sensors_stations_or_depots = function()
    local m = master()
    m.register("EVIL-2", "sensor")
    m.event("EVIL-2", { type = "sensor", sensor_id = "EVIL-2", action = "enter" })
    m.event("EVIL-3", { type = "sensor", sensor_id = "EVIL-3", action = "enter" })
    m.event("EVIL-4", { type = "request_departure", train_id = "TRAIN-1", route_id = "R1" })
    m.event("EVIL-4", { type = "train_status", train_id = "TRAIN-1" })
    m.event("EVIL-5", { type = "station_status", station_id = "ST-1" })
    m.event("EVIL-6", { type = "depot_status", depot_id = "DEP-1" })
    m.event("EVIL-6", { type = "depot_request_dispatch", depot_id = "DEP-1" })
    assert(none(m.calls.sensor) and none(m.calls.train) and none(m.calls.station) and none(m.calls.depot), "nothing reached the dispatcher or a registry")
    assert(m.runtime.sensor_levels["EVIL-2"] == nil and m.runtime.sensor_levels["EVIL-3"] == nil)
  end,

  test_strangers_have_no_log_ota_or_heartbeat_effect = function()
    local m = master()
    m.event("EVIL-1", { type = "log_batch", entries = { { lvl = "ERROR", msg = "spam" } } })
    m.event("EVIL-1", { type = "ota_need", update_id = "u1", need = {} })
    m.event("EVIL-1", { type = "ota_result", update_id = "u1", success = true, node_id = "SIG-1" })
    m.heartbeat("EVIL-1", "signal")
    assert(#m.logs.recent() == 0, "nothing in the central log")
    assert(none(m.calls.ota), "the update manager was not asked")
    assert(m.registry.get("EVIL-1") == nil)
  end,

  test_a_computer_of_the_plan_is_a_node_for_its_own_role_only = function()
    local m = master()
    m.register("SEN-1", "sensor")
    m.heartbeat("SEN-1", "sensor", { occupied = true })
    assert(m.registry.get("SEN-1") and m.registry.get("SEN-1").role == "sensor")
    assert(m.runtime.sensor_levels["SEN-1"] and m.runtime.sensor_levels["SEN-1"].occupied == true)
    m.event("SEN-1", { type = "sensor", sensor_id = "SEN-1", action = "enter" })
    assert(m.calls.sensor[1] == "SEN-1:enter")
    -- a signal node must not send what a sensor, a train or a panel sends
    m.register("SIG-1", "signal")
    m.event("SIG-1", { type = "sensor", sensor_id = "SIG-1", action = "enter" })
    m.event("SIG-1", { type = "request_departure", train_id = "TRAIN-1" })
    m.event("SIG-1", { type = "manual_control", action = "emergency_stop" })
    m.event("SEN-1", { type = "station_status", station_id = "ST-1" })
    assert(#m.calls.sensor == 1 and none(m.calls.train) and none(m.calls.manual) and none(m.calls.station))
    assert(m.rejected("SIG-1") and m.rejected("SEN-1"))
    assert(m.alerts.get("event:SIG-1:sensor"), "a computer of the plan that oversteps is shown to the operator")
  end,

  test_a_panel_of_the_plan_steers_once_the_master_has_seen_it = function()
    local m = master()
    m.event("PANEL-1", { type = "manual_control", action = "emergency_stop" })
    assert(none(m.calls.manual) and m.rejected("PANEL-1"), "listed in the plan, but the master has not heard from it yet")
    m.heartbeat("PANEL-1", "panel")
    m.event("PANEL-1", { type = "manual_control", action = "emergency_stop" })
    assert(m.calls.manual[1] == "PANEL-1:emergency_stop")
  end,

  test_the_role_in_the_plan_wins_over_the_role_a_computer_announces = function()
    local m = master()
    m.register("SEN-1", "panel")
    m.heartbeat("SEN-1", "panel")
    assert(m.registry.get("SEN-1") == nil, "not registered as a panel")
    local candidate = m.pairing.get("SEN-1")
    assert(candidate and candidate.state == "conflict" and candidate.role == "panel")
    m.event("SEN-1", { type = "manual_control", action = "emergency_stop" })
    assert(none(m.calls.manual))
  end,

  test_accepting_a_computer_is_what_makes_it_a_node = function()
    local m = master()
    m.event("PANEL-2", { type = "pair_announce", role = "panel", entry = { id = "PANEL-2", role = "panel" } })
    m.register("PANEL-2", "panel")
    m.event("PANEL-2", { type = "manual_control", action = "emergency_stop" })
    assert(none(m.calls.manual) and m.registry.get("PANEL-2") == nil)
    local ok, why = m.runtime.pair_decide("accept", "PANEL-2", "PANEL-1")
    assert(ok, tostring(why))
    assert(netplan.find_node(assert(netplan.parse(m.fs.files[PLAN])), "PANEL-2"), "written to the plan")
    -- the same computer, now listed
    m.register("PANEL-2", "panel")
    assert(m.registry.get("PANEL-2") and m.registry.get("PANEL-2").role == "panel")
    m.event("PANEL-2", { type = "manual_control", action = "emergency_stop" })
    assert(m.calls.manual[1] == "PANEL-2:emergency_stop")
  end,

  test_a_rejected_computer_stays_outside = function()
    local m = master()
    m.register("PANEL-3", "panel")
    assert(m.runtime.pair_decide("reject", "PANEL-3", "PANEL-1"))
    m.register("PANEL-3", "panel")
    m.heartbeat("PANEL-3", "panel")
    m.event("PANEL-3", { type = "manual_control", action = "emergency_stop" })
    assert(none(m.calls.manual) and m.registry.get("PANEL-3") == nil)
  end,

  test_many_strangers_do_not_fill_the_alerts_or_the_audit = function()
    local m = master()
    for i = 1, 300 do
      m.event("NOISE-" .. i, { type = "sensor", sensor_id = "NOISE-" .. i, action = "enter" })
      m.event("NOISE-" .. i, { type = "manual_control", action = "emergency_stop" })
    end
    assert(#m.alerts.list() == 0, "no alert per stranger")
    local lines = 0
    for _, a in ipairs(m.audits) do if a.kind == "event_rejected" then lines = lines + 1 end end
    assert(lines <= 2, "one line for all strangers within a minute, got " .. lines)
    assert(none(m.calls.sensor) and none(m.calls.manual))
  end,

  test_the_pairing_messages_stay_open_to_everybody = function()
    local m = master()
    m.event("NEW-1", { type = "pair_announce", role = "signal", entry = { id = "NEW-1", role = "signal" } })
    m.event("NEW-2", { type = "pair_probe", role = "sensor", entry = { id = "NEW-2", role = "sensor" } })
    assert(m.pairing.get("NEW-1") and m.pairing.get("NEW-2"))
    assert(not m.rejected("NEW-1") and not m.rejected("NEW-2"))
  end,

  -- the plan itself: handed out to the station and depot computers of the plan, and to nobody else ---------------------------------

  test_a_station_and_a_depot_of_the_plan_get_the_plan_in_parts = function()
    local m = master()
    for _, who in ipairs({ { "ST-1", "station" }, { "DEP-1", "depot" } }) do
      m.sent = {}
      local first = parts_to(m, who[1], who[2])
      assert(first and first.ok and first.index == 1 and first.total > 1, "several parts of 200 bytes")
      local text = first.data
      for index = 2, first.total do
        m.event(who[1], { type = "plan_get", role = who[2], index = index, version = first.version })
        local part = m.sent[#m.sent].payload
        assert(part.ok and part.index == index and part.version == first.version)
        text = text .. part.data
      end
      assert(text == m.fs.files[PLAN] and #text == first.size)
      assert(checksum.hex(checksum.adler32(text)) == first.version)
    end
    local served = false
    for _, a in ipairs(m.audits) do if a.kind == "plan_served" and a.data.node_id == "DEP-1" then served = true end end
    assert(served, "handing the plan out is audited")
  end,

  test_the_answer_names_the_question_and_is_not_kept_for_retries = function()
    local m = master()
    m.event("ST-1", { type = "plan_get", role = "station", index = 1 })
    local reply = m.sent[#m.sent]
    assert(reply.kind == "cmd" and reply.dst == "ST-1" and reply.reliable == nil, "a plain message: the asker asks again")
    assert(type(reply.payload.question) == "string" and reply.payload.cmd == "plan_part")
  end,

  test_the_plan_is_refused_to_everybody_else_with_a_small_answer = function()
    local m = master()
    local stranger = parts_to(m, "EVIL-1", "station")
    assert(stranger and stranger.ok == false and stranger.state == "refused" and stranger.reason == "not_in_plan" and stranger.data == nil)
    local sensor = parts_to(m, "SEN-1", "sensor")
    assert(sensor.ok == false and sensor.reason == "role" and sensor.data == nil, "only the roles that read their platforms and tracks from the plan")
    local claims = parts_to(m, "SEN-1", "station")
    assert(claims.ok == false and claims.reason == "conflict" and claims.data == nil, "the role in the plan counts")
    for _, a in ipairs(m.audits) do assert(a.kind ~= "plan_served", "nothing was handed out") end
    assert(#m.alerts.list() == 0 and m.registry.get("EVIL-1") == nil, "asking registers nothing and raises nothing")
  end,

  test_a_master_without_a_plan_service_says_so = function()
    local m = master({ no_plan_service = true })
    local reply = parts_to(m, "ST-1", "station")
    assert(reply and reply.ok == false and reply.reason == "unavailable")
  end,

  test_many_strangers_asking_for_the_plan_cost_one_small_answer_each = function()
    local m = master()
    for i = 1, 200 do m.event("NOISE-" .. i, { type = "plan_get", role = "station", index = 1 }) end
    assert(#m.sent == 200)
    for _, item in ipairs(m.sent) do assert(item.payload.data == nil and item.payload.ok == false) end
    assert(#m.alerts.list() == 0)
  end,

  test_a_plan_without_nodes_admits_nobody = function()
    local m = master()
    m.cfg.nodes = {}
    m.register("SEN-1", "sensor")
    m.event("SEN-1", { type = "sensor", sensor_id = "SEN-1", action = "enter" })
    assert(m.registry.get("SEN-1") == nil and none(m.calls.sensor), "fail closed")
  end,
}
