--[[
Purpose: Blocks that went FAULT because a node timed out clear themselves when the node is back and the detectors show
  the track free; everything else stays FAULT for the operator.
Public API: returns table of tests.
]]

pcall(dofile, "tests/harness/cc_bootstrap.lua")

local dispatcher = require("src.master.dispatcher")
local runtime_factory = require("src.master.runtime")
local registry_factory = require("src.shared.registry")
local sensor_node = require("src.nodes.sensor_node")
local validate = require("src.shared.validate")

local STATES = dispatcher.STATES
local TRAIN_STATES = dispatcher.TRAIN_STATES

local function cfg()
  return {
    sensor_guard_min_occupy_ms = 0,
    blocks = {
      { id = "B1", entry_signal = "SE1", exit_signal = "SX1", sensors = { "SEN-1" }, switches = { { id = "SW-1", position = "STRAIGHT" } } },
      { id = "B2", entry_signal = "SE2", exit_signal = "SX2", sensors = { "SEN-2" }, switches = {} },
      { id = "B3", entry_signal = "SE3", exit_signal = "SX3", sensors = { "SEN-3" }, switches = {} },
      { id = "B4", entry_signal = "SE4", exit_signal = "SX4", sensors = {}, switches = {} }
    },
    routes = {
      { id = "R-12", from = "A", to = "B", blocks = { "B1", "B2" } },
      { id = "R-3", from = "C", to = "D", blocks = { "B3" } },
      { id = "R-4", from = "E", to = "F", blocks = { "B4" } }
    }
  }
end

local function adapters()
  return {
    signals = { setAspect = function() return true end },
    switches = { setPosition = function() return true end }
  }
end

-- a world the test steers: which nodes answer, what the detectors show and when they last said so
local function world()
  local w = { now = 1000, up = {}, levels = {} }
  w.ctx = function(extra)
    local c = {
      now = w.now, stable_s = 15, max_age_s = 10,
      node_up = function(id) return w.up[id] == true end,
      sensor_level = function(id) local l = w.levels[id]; if not l then return nil, nil end; return l.occupied, l.at end
    }
    for k, v in pairs(extra or {}) do c[k] = v end
    return c
  end
  w.free = function(sensor) w.levels[sensor] = { occupied = false, at = w.now } end
  w.occupied = function(sensor) w.levels[sensor] = { occupied = true, at = w.now } end
  return w
end

local function enter(d, n) return d.on_sensor_event_by_sensor("SEN-" .. n, "enter") end

return {
  test_timeout_marks_blocks_with_their_cause = function()
    local d = dispatcher.new(cfg(), adapters())
    d.timeout_node("SEN-1")
    local snap = d.snapshot().blocks["B1"]
    assert(snap.state == STATES.FAULT and snap.fault_cause.kind == "node_timeout", tostring(snap.fault_cause and snap.fault_cause.kind))
    assert(snap.fault_cause.nodes[1] == "SEN-1")
    assert(d.snapshot().blocks["B2"].fault_cause == nil)
  end,

  test_block_clears_when_node_is_back_and_track_is_free = function()
    local w = world()
    local d = dispatcher.new(cfg(), adapters())
    d.timeout_node("SEN-1")
    w.up["SEN-1"] = true
    w.free("SEN-1")
    assert(#d.auto_clear_faults(w.ctx()) == 0, "not before the node was stable")
    w.now = w.now + 14; w.free("SEN-1")
    assert(#d.auto_clear_faults(w.ctx()) == 0, "14 s are not enough")
    w.now = w.now + 2; w.free("SEN-1")
    local cleared = d.auto_clear_faults(w.ctx())
    assert(#cleared == 1 and cleared[1].block == "B1", #cleared)
    assert(d.get_block("B1").state == STATES.FREE and d.get_block("B1").fault_cause == nil)
  end,

  test_nothing_clears_while_the_node_is_down = function()
    local w = world()
    local d = dispatcher.new(cfg(), adapters())
    d.timeout_node("SEN-1")
    w.free("SEN-1")
    w.now = w.now + 100; w.free("SEN-1")
    assert(#d.auto_clear_faults(w.ctx()) == 0)
    -- it comes back, but the clock for "stable" starts only now
    w.up["SEN-1"] = true
    assert(#d.auto_clear_faults(w.ctx()) == 0)
    w.now = w.now + 20; w.free("SEN-1")
    assert(#d.auto_clear_faults(w.ctx()) == 1)
  end,

  test_flapping_node_restarts_the_stable_period = function()
    local w = world()
    local d = dispatcher.new(cfg(), adapters())
    d.timeout_node("SEN-1")
    w.up["SEN-1"] = true; w.free("SEN-1")
    d.auto_clear_faults(w.ctx())
    w.now = w.now + 10; w.free("SEN-1")
    w.up["SEN-1"] = false
    d.auto_clear_faults(w.ctx())
    w.up["SEN-1"] = true
    w.now = w.now + 10; w.free("SEN-1")
    assert(#d.auto_clear_faults(w.ctx()) == 0, "20 s after the first return, but only 0 s since the last one")
    w.now = w.now + 16; w.free("SEN-1")
    assert(#d.auto_clear_faults(w.ctx()) == 1)
  end,

  test_occupied_stale_or_missing_detector_keeps_the_block_faulted = function()
    local w = world()
    local d = dispatcher.new(cfg(), adapters())
    d.timeout_node("SEN-1")
    w.up["SEN-1"] = true
    w.free("SEN-1")
    d.auto_clear_faults(w.ctx())
    w.now = w.now + 20
    -- a train stands on the detector
    w.occupied("SEN-1")
    assert(#d.auto_clear_faults(w.ctx()) == 0, "occupied")
    -- the last report is older than max_age
    w.levels["SEN-1"] = { occupied = false, at = w.now - 11 }
    assert(#d.auto_clear_faults(w.ctx()) == 0, "stale")
    -- the last report is from before the node came back
    w.levels["SEN-1"] = { occupied = false, at = w.now - 21 }
    assert(#d.auto_clear_faults(w.ctx({ max_age_s = 100 })) == 0, "from before the recovery")
    -- no report at all
    w.levels["SEN-1"] = nil
    assert(#d.auto_clear_faults(w.ctx()) == 0, "nothing reported")
    assert(d.get_block("B1").state == STATES.FAULT)
  end,

  test_block_without_a_detector_is_never_cleared_automatically = function()
    local w = world()
    local d = dispatcher.new(cfg(), adapters())
    d.timeout_node("SE4")
    w.up["SE4"] = true
    d.auto_clear_faults(w.ctx())
    w.now = w.now + 60
    assert(#d.auto_clear_faults(w.ctx()) == 0)
    assert(d.get_block("B4").state == STATES.FAULT)
  end,

  test_other_fault_causes_stay_for_the_operator = function()
    local w = world()
    local d = dispatcher.new(cfg(), adapters())
    -- garbage from the detector: enter on a block nobody reserved
    assert(enter(d, 3) == false)
    assert(d.get_block("B3").state == STATES.FAULT)
    -- the node times out later: the block keeps its first cause
    d.timeout_node("SEN-3")
    assert(d.snapshot().blocks["B3"].fault_cause.kind == "event")
    w.up["SEN-3"] = true; w.free("SEN-3")
    d.auto_clear_faults(w.ctx())
    w.now = w.now + 60; w.free("SEN-3")
    assert(#d.auto_clear_faults(w.ctx()) == 0)
    assert(d.clear_fault("B3"), "the operator can still do it")
    assert(d.get_block("B3").fault_cause == nil)
  end,

  test_every_node_of_the_cause_has_to_be_back = function()
    local w = world()
    local d = dispatcher.new(cfg(), adapters())
    d.timeout_node("SEN-1")
    d.timeout_node("SE1")
    local nodes = d.snapshot().blocks["B1"].fault_cause.nodes
    assert(#nodes == 2 and nodes[1] == "SE1" and nodes[2] == "SEN-1", table.concat(nodes, ","))
    w.up["SEN-1"] = true; w.free("SEN-1")
    d.auto_clear_faults(w.ctx())
    w.now = w.now + 30; w.free("SEN-1")
    assert(#d.auto_clear_faults(w.ctx()) == 0, "the signal is still down")
    w.up["SE1"] = true
    d.auto_clear_faults(w.ctx())
    w.now = w.now + 30; w.free("SEN-1")
    assert(#d.auto_clear_faults(w.ctx()) == 1)
  end,

  test_timed_out_train_is_released_with_its_blocks = function()
    local w = world()
    local a = adapters()
    local d = dispatcher.new(cfg(), a)
    assert(d.reserve_route("T1", "R-12"))
    assert(enter(d, 1))
    d.timeout_node("SEN-1")
    assert(d.get_trains()["T1"].state == TRAIN_STATES.FAULT)
    w.up["SEN-1"] = true
    w.free("SEN-1"); w.free("SEN-2")
    d.auto_clear_faults(w.ctx())
    w.now = w.now + 20; w.free("SEN-1"); w.free("SEN-2")
    local cleared = d.auto_clear_faults(w.ctx())
    assert(#cleared == 1 and cleared[1].block == "B1" and cleared[1].train == "T1", #cleared)
    assert(d.get_trains()["T1"] == nil, "the train is gone")
    assert(d.get_block("B1").state == STATES.FREE and d.get_block("B2").state == STATES.FREE)
    assert(next(d.get_switch_locks()) == nil)
    assert(d.get_interlocking()["R-12"].status == "VACANT")
    assert(next(d.get_conflicts()) == nil)
    assert(d.reserve_route("T2", "R-12"), "the line is usable again")
  end,

  test_train_stays_when_another_block_of_its_route_is_not_shown_free = function()
    local w = world()
    local d = dispatcher.new(cfg(), adapters())
    assert(d.reserve_route("T1", "R-12"))
    assert(enter(d, 1))
    d.timeout_node("SEN-1")
    w.up["SEN-1"] = true
    w.free("SEN-1"); w.occupied("SEN-2")
    d.auto_clear_faults(w.ctx())
    w.now = w.now + 20; w.free("SEN-1"); w.occupied("SEN-2")
    assert(#d.auto_clear_faults(w.ctx()) == 0, "something stands on B2")
    assert(d.get_trains()["T1"].state == TRAIN_STATES.FAULT)
    assert(d.get_block("B1").state == STATES.FAULT)
    -- B2 frees up
    w.free("SEN-2"); w.free("SEN-1")
    assert(#d.auto_clear_faults(w.ctx()) == 1)
  end,

  test_train_stays_when_a_block_of_its_route_faulted_for_another_reason = function()
    local w = world()
    local d = dispatcher.new(cfg(), adapters())
    assert(d.reserve_route("T1", "R-12"))
    assert(enter(d, 1))
    d.timeout_node("SEN-1")
    -- garbage on B2 while it is reserved for T1? it is RESERVED, so enter is legal; force a stray leave instead
    assert(d.on_sensor_event_by_sensor("SEN-2", "leave") == false)
    assert(d.get_block("B2").state == STATES.FAULT)
    w.up["SEN-1"] = true; w.free("SEN-1"); w.free("SEN-2")
    d.auto_clear_faults(w.ctx())
    w.now = w.now + 20; w.free("SEN-1"); w.free("SEN-2")
    assert(#d.auto_clear_faults(w.ctx()) == 0)
    assert(d.get_trains()["T1"].state == TRAIN_STATES.FAULT)
  end,

  test_cause_survives_snapshot_and_restore = function()
    local w = world()
    local d = dispatcher.new(cfg(), adapters())
    d.timeout_node("SEN-1")
    d.timeout_node("SE1")
    local d2 = dispatcher.new(cfg(), adapters())
    assert(d2.restore(d.snapshot()))
    local cause = d2.snapshot().blocks["B1"].fault_cause
    assert(cause and cause.kind == "node_timeout" and #cause.nodes == 2)
    w.up["SEN-1"] = true; w.up["SE1"] = true
    d2.auto_clear_faults(w.ctx())
    w.now = w.now + 20; w.free("SEN-1")
    assert(#d2.auto_clear_faults(w.ctx()) == 1)
  end,

  test_fault_without_a_recorded_cause_is_left_alone = function()
    local w = world()
    local d = dispatcher.new(cfg(), adapters())
    local snap = d.snapshot()
    snap.blocks["B1"] = { id = "B1", state = STATES.FAULT }  -- written by an older version
    assert(d.restore(snap))
    w.up["SEN-1"] = true
    d.auto_clear_faults(w.ctx())
    w.now = w.now + 60; w.free("SEN-1")
    assert(#d.auto_clear_faults(w.ctx()) == 0)
  end,

  -- the master wiring -------------------------------------------------------------------------------------------

  test_master_clears_the_block_from_heartbeats_and_audits_it = function()
    local virtual_ms = 5000000
    local real_epoch = os.epoch
    os.epoch = function() return virtual_ms end
    local ok, err = pcall(function()
      local audits, saves = {}, 0
      local reg = registry_factory.new()
      local d = dispatcher.new(cfg(), adapters())
      local rt = runtime_factory.new({
        config = { nodes = {} }, registry = reg, dispatcher = d,
        network = { receive = function() return "ok" end, ack_for = function() end, send = function() end, tick = function() end },
        ui = { mark_dirty = function() end, draw = function() end, handle_touch = function() end },
        audit_log = { record = function(kind, data) audits[#audits + 1] = { kind = kind, data = data } end },
        auto_restore_state = false, auto_save_state = true,
        state_store = { save = function() saves = saves + 1; return true end }
      })
      local function beat(src, payload) rt.handle_event({ "modem_message", nil, nil, nil, { v = 1, id = src .. "." .. virtual_ms, type = "heartbeat", src = src, dst = "M", payload = payload } }) end
      local function kinds(kind) local n = 0; for _, a in ipairs(audits) do if a.kind == kind then n = n + 1 end end; return n end

      beat("SEN-1", { role = "sensor", occupied = false })
      assert(reg.get("SEN-1").status == "UP")
      -- the sensor falls silent
      reg.nodes["SEN-1"].last_seen = reg.nodes["SEN-1"].last_seen - 20
      local before = saves
      for _ = 1, 3 do rt.check_timeouts() end
      assert(d.get_block("B1").state == STATES.FAULT, "the timeout faulted the block")
      assert(kinds("node_timeout") == 1, "once per outage, not once per second: " .. kinds("node_timeout"))
      assert(kinds("node_reconnect") == 0)

      -- it comes back: heartbeats say the detector is free
      beat("SEN-1", { role = "sensor", occupied = false })
      assert(kinds("node_reconnect") == 1)
      assert(#rt.auto_clear_faults() == 0, "the stable period starts now")
      virtual_ms = virtual_ms + 16000
      beat("SEN-1", { role = "sensor", occupied = false })
      local cleared = rt.auto_clear_faults()
      assert(#cleared == 1 and cleared[1].block == "B1", #cleared)
      assert(d.get_block("B1").state == STATES.FREE)
      assert(kinds("fault_auto_cleared") == 1)
      assert(saves > before, "the new state is saved")
    end)
    os.epoch = real_epoch
    assert(ok, err)
  end,

  test_master_keeps_the_block_when_the_detector_reports_occupied = function()
    local virtual_ms = 5000000
    local real_epoch = os.epoch
    os.epoch = function() return virtual_ms end
    local ok, err = pcall(function()
      local reg = registry_factory.new()
      local d = dispatcher.new(cfg(), adapters())
      local rt = runtime_factory.new({
        config = { nodes = {}, auto_clear_stable_s = 0 }, registry = reg, dispatcher = d,
        network = { receive = function() return "ok" end, ack_for = function() end, send = function() end, tick = function() end },
        ui = { mark_dirty = function() end, draw = function() end, handle_touch = function() end },
        auto_restore_state = false, auto_save_state = false
      })
      local function beat(payload) rt.handle_event({ "modem_message", nil, nil, nil, { v = 1, id = "S." .. virtual_ms, type = "heartbeat", src = "SEN-1", dst = "M", payload = payload } }) end
      beat({ role = "sensor", occupied = false })
      d.timeout_node("SEN-1")
      reg.mark_down("SEN-1")
      virtual_ms = virtual_ms + 1000
      beat({ role = "sensor", occupied = true })
      rt.auto_clear_faults()
      virtual_ms = virtual_ms + 1000
      beat({ role = "sensor", occupied = true })
      assert(#rt.auto_clear_faults() == 0)
      assert(d.get_block("B1").state == STATES.FAULT)
      virtual_ms = virtual_ms + 1000
      beat({ role = "sensor", occupied = false })
      assert(#rt.auto_clear_faults() == 1, "free again, no wait with stable_s = 0")
    end)
    os.epoch = real_epoch
    assert(ok, err)
  end,

  test_heartbeat_timeout_comes_from_the_config = function()
    local function build(config)
      return runtime_factory.new({
        config = config, registry = registry_factory.new(), dispatcher = { get_overview = function() return {} end, timeout_node = function() end },
        network = { receive = function() return "ok" end, ack_for = function() end, send = function() end, tick = function() end },
        ui = { mark_dirty = function() end, draw = function() end, handle_touch = function() end },
        auto_restore_state = false, auto_save_state = false
      })
    end
    assert(build({ nodes = {} }).heartbeat_timeout_s == 6)
    assert(build({ nodes = {}, heartbeat_timeout_s = 15 }).heartbeat_timeout_s == 15, "documented key must work")
    assert(build({ nodes = {}, heartbeat_timeout_s = -3 }).heartbeat_timeout_s == 6)
    assert(build({ nodes = {}, heartbeat_timeout_s = "fast" }).heartbeat_timeout_s == 6)
  end,

  test_validation_names_wrong_tuning_keys = function()
    local _, errors = validate.validate_config({
      heartbeat_timeout_s = "fast", auto_clear_stable_s = -1, signal_refresh_per_s = 2,
      auto_clear_faults = "yes", signal_red_on_stop = true
    })
    local text = table.concat(errors, "\n")
    assert(text:find("heartbeat_timeout_s: must be a number", 1, true), text)
    assert(text:find("auto_clear_stable_s: must be a number", 1, true))
    assert(text:find("auto_clear_faults: must be true or false", 1, true))
    assert(not text:find("signal_refresh_per_s", 1, true) and not text:find("signal_red_on_stop", 1, true))
  end,

  test_master_option_turns_the_feature_off = function()
    local reg = registry_factory.new()
    local d = dispatcher.new(cfg(), adapters())
    local rt = runtime_factory.new({
      config = { nodes = {}, auto_clear_faults = false, auto_clear_stable_s = 0 }, registry = reg, dispatcher = d,
      network = { receive = function() return "ok" end, ack_for = function() end, send = function() end, tick = function() end },
      ui = { mark_dirty = function() end, draw = function() end, handle_touch = function() end },
      auto_restore_state = false, auto_save_state = false
    })
    reg.register("SEN-1", "sensor")
    d.timeout_node("SEN-1")
    rt.handle_event({ "modem_message", nil, nil, nil, { v = 1, id = "x.1", type = "heartbeat", src = "SEN-1", dst = "M", payload = { role = "sensor", occupied = false } } })
    assert(#rt.auto_clear_faults() == 0)
    assert(d.get_block("B1").state == STATES.FAULT)
  end,

  test_sensor_events_count_as_a_detector_report = function()
    local reg = registry_factory.new()
    local d = dispatcher.new(cfg(), adapters())
    local rt = runtime_factory.new({
      config = { nodes = {} }, registry = reg, dispatcher = d,
      network = { receive = function() return "ok" end, ack_for = function() end, send = function() end, tick = function() end },
      ui = { mark_dirty = function() end, draw = function() end, handle_touch = function() end },
      auto_restore_state = false, auto_save_state = false
    })
    reg.register("SEN-3", "sensor")
    rt.handle_event({ "modem_message", nil, nil, nil, { v = 1, id = "x.1", type = "event", src = "SEN-3", dst = "M", payload = { type = "sensor", sensor_id = "SEN-3", action = "enter" } } })
    assert(rt.sensor_levels["SEN-3"].occupied == true)
    rt.handle_event({ "modem_message", nil, nil, nil, { v = 1, id = "x.2", type = "event", src = "SEN-3", dst = "M", payload = { type = "sensor", sensor_id = "SEN-3", action = "leave" } } })
    assert(rt.sensor_levels["SEN-3"].occupied == false)
  end,

  test_sensor_node_reports_its_level_in_the_heartbeat = function()
    local sent = {}
    local node = {
      config = { master_id = "M" }, role = "sensor",
      net = { send_reliable = function() return true end, heartbeat = function(dst, payload) sent[#sent + 1] = payload; return true end }
    }
    local reading = { true, true }
    local adapter = { readOccupied = function() return reading[1], reading[2] end }
    local check = sensor_node.build_check_fn(node, adapter, "SEN-1", "M")
    check()
    assert(node.occupied_level == true)
    reading = { true, false }
    check()
    assert(node.occupied_level == false)
    reading = { false, "peripheral missing" }
    check()
    assert(node.occupied_level == nil, "a failing read reports nothing")
  end
}
