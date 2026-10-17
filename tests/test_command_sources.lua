--[[
Purpose: Who may tell what to whom: node commands only from the master, sensor events only from the sensor itself,
  manual control only from panels; heartbeats adopt nodes the master does not know after a restart.
Public API: returns table of tests.
]]

pcall(dofile, "tests/harness/cc_bootstrap.lua")

local common_node = require("src.nodes.common_node")
local runtime_factory = require("src.master.runtime")
local registry_factory = require("src.shared.registry")

local function node_with(cfg_extra, on_cmd)
  local sent = {}
  local modem = { open = function() return true end, send = function(_, _, _, m) sent[#sent + 1] = m; return true end, broadcast = function(_, _, m) sent[#sent + 1] = m; return true end }
  local cfg = { channel = 1, master_id = "M" }
  for k, v in pairs(cfg_extra or {}) do cfg[k] = v end
  return common_node.new({ id = "N1", role = "signal", config = cfg, modem = modem, handlers = { on_cmd = on_cmd } }), sent
end

local function cmd(src, id)
  return { v = 1, id = id or "k.1", src = src, dst = "N1", type = "cmd", payload = { cmd = "set", aspect = "GREEN" } }
end

local function master(overrides)
  local audits, acks, sensor_calls, manual_calls = {}, 0, {}, {}
  local reg = registry_factory.new()
  local context = {
    config = { nodes = {} }, registry = reg,
    dispatcher = {
      get_overview = function() return {} end, timeout_node = function() end,
      on_sensor_event_by_sensor = function(sensor, action) sensor_calls[#sensor_calls + 1] = sensor .. ":" .. action; return true end
    },
    network = { receive = function() return "ok" end, ack_for = function() acks = acks + 1 end, send = function() end, tick = function() end },
    ui = { mark_dirty = function() end, draw = function() end, handle_touch = function() end },
    audit_log = { record = function(kind, data) audits[#audits + 1] = { kind = kind, data = data } end },
    manual_control = { handle = function(payload) manual_calls[#manual_calls + 1] = payload.action; return true end },
    auto_restore_state = false, auto_save_state = false
  }
  for k, v in pairs(overrides or {}) do context[k] = v end
  local rt = runtime_factory.new(context)
  return rt, { audits = audits, sensor_calls = sensor_calls, manual_calls = manual_calls, reg = reg, acks = function() return acks end }
end

local function event(src, payload) return { "modem_message", nil, nil, nil, { v = 1, id = src .. "." .. tostring(payload.type) .. tostring(math.random(1, 1e9)), type = "event", src = src, dst = "M", payload = payload } } end

local function has_audit(env, kind) for _, a in ipairs(env.audits) do if a.kind == kind then return true end end; return false end

return {
  test_node_executes_commands_from_the_master = function()
    local calls = 0
    local node, sent = node_with(nil, function() calls = calls + 1; return true end)
    node.handle_message(cmd("M"))
    assert(calls == 1 and sent[#sent].type == "ack")
  end,

  test_node_refuses_commands_from_anyone_else_and_says_so = function()
    local calls = 0
    local node, sent = node_with(nil, function() calls = calls + 1; return true end)
    node.handle_message(cmd("STRANGER"))
    assert(calls == 0, "a stranger's command must not run")
    assert(sent[#sent].type == "err" and tostring(sent[#sent].payload.error):find("not allowed"))
  end,

  test_cmd_sources_in_the_config_extend_the_list = function()
    local calls = 0
    local node = node_with({ cmd_sources = { "TOOL-7" } }, function() calls = calls + 1; return true end)
    node.handle_message(cmd("TOOL-7"))
    assert(calls == 1)
  end,

  test_ota_sender_is_not_a_general_command_sender = function()
    local calls = 0
    local node = node_with(nil, function() calls = calls + 1; return true end)
    node.handle_message(cmd("OTA-TOOL"))
    assert(calls == 0, "OTA-TOOL may update, not steer")
  end,

  test_master_ignores_sensor_events_that_claim_another_sensor = function()
    local rt, env = master()
    rt.handle_event(event("SEN-1", { type = "sensor", sensor_id = "SEN-2", action = "enter" }))
    assert(#env.sensor_calls == 0 and has_audit(env, "event_rejected"))
    assert(env.acks() == 1, "rejected events are still acknowledged so the sender stops retrying")
    rt.handle_event(event("SEN-1", { type = "sensor", sensor_id = "SEN-1", action = "enter" }))
    assert(#env.sensor_calls == 1 and env.sensor_calls[1] == "SEN-1:enter")
  end,

  test_manual_control_is_only_accepted_from_panels = function()
    local rt, env = master()
    rt.handle_event(event("TRAIN-1", { type = "manual_control", action = "emergency_stop" }))
    assert(#env.manual_calls == 0 and has_audit(env, "event_rejected"))
    env.reg.register("PANEL-1", "panel")
    rt.handle_event(event("PANEL-1", { type = "manual_control", action = "emergency_stop" }))
    assert(#env.manual_calls == 1)
  end,

  test_heartbeat_of_an_unknown_node_adopts_it_after_a_master_restart = function()
    local rt, env = master()
    assert(env.reg.get("SIG-1") == nil)
    local heartbeat = { "modem_message", nil, nil, nil, { v = 1, id = "h.1", type = "heartbeat", src = "SIG-1", dst = "M", payload = { role = "signal" } } }
    rt.handle_event(heartbeat)
    local node = env.reg.get("SIG-1")
    assert(node and node.role == "signal" and node.status == "UP")
    assert(has_audit(env, "node_adopted"))
  end,

  test_heartbeat_without_a_role_does_not_create_a_node = function()
    local rt, env = master()
    rt.handle_event({ "modem_message", nil, nil, nil, { v = 1, id = "h.2", type = "heartbeat", src = "X", dst = "M", payload = {} } })
    assert(env.reg.get("X") == nil)
  end,

  test_a_node_that_comes_back_after_being_down_is_audited_as_reconnected = function()
    local rt, env = master()
    env.reg.register("SIG-1", "signal")
    env.reg.mark_down("SIG-1")
    rt.handle_event({ "modem_message", nil, nil, nil, { v = 1, id = "r.1", type = "register", src = "SIG-1", dst = "M", payload = { role = "signal" } } })
    assert(has_audit(env, "node_reconnect"), "the audit compared the status with lower case 'down' while the registry stores 'DOWN'")
  end
}
