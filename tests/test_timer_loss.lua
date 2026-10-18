--[[
Purpose: Event loops must survive a dropped timer event (CC:Tweaked drops events while 256 are queued).
Public API: returns table of tests.
Notes: each test starts a real node/master runtime with a fake clock and fake timers, never delivers the timer
  event, advances the clock and feeds an unrelated event. The periodic work must still happen.
]]

pcall(dofile, "tests/harness/cc_bootstrap.lua")

local common_node = require("src.nodes.common_node")
local sensor_node = require("src.nodes.sensor_node")
local train_node = require("src.nodes.train_node")
local runtime_factory = require("src.master.runtime")
local time = require("src.shared.time")

local function fake_env()
  local env = { now = 0, last_id = 0, sent = {}, warnings = {} }
  env.clock = function() return env.now end
  env.start_timer = function() env.last_id = env.last_id + 1; return env.last_id end
  env.modem = {
    open = function() return true end,
    send = function(_, _, _, m) env.sent[#env.sent + 1] = m; return true end,
    broadcast = function(_, _, m) env.sent[#env.sent + 1] = m; return true end
  }
  env.logger = {
    info = function() end, debug = function() end, error = function() end,
    warn = function(msg, data) env.warnings[#env.warnings + 1] = { msg = msg, data = data } end
  }
  return env
end

local function count_type(env, message_type, payload_type)
  local n = 0
  for _, m in ipairs(env.sent) do
    if m.type == message_type and (payload_type == nil or (m.payload and m.payload.type == payload_type)) then n = n + 1 end
  end
  return n
end

local NO_TIMER_EVENT = { "peripheral", "left" }

return {
  test_node_heartbeat_fires_on_its_timer = function()
    local env = fake_env()
    local node = common_node.new({ id = "N1", role = "signal", config = { channel = 1, master_id = "M" }, modem = env.modem, logger = env.logger, clock = env.clock, start_timer = env.start_timer })
    node.start()
    assert(count_type(env, "heartbeat") == 1)
    env.now = 2
    node.handle_event({ "timer", env.last_id })
    assert(count_type(env, "heartbeat") == 2)
  end,

  test_node_heartbeat_survives_dropped_timer = function()
    local env = fake_env()
    local node = common_node.new({ id = "N1", role = "signal", config = { channel = 1, master_id = "M" }, modem = env.modem, logger = env.logger, clock = env.clock, start_timer = env.start_timer })
    node.start()
    assert(count_type(env, "heartbeat") == 1)
    env.now = 2 + 1.1
    node.handle_event(NO_TIMER_EVENT)
    assert(count_type(env, "heartbeat") == 2, "heartbeat must be sent although its timer event never arrived")
    env.now = env.now + 2 + 1.1
    node.handle_event(NO_TIMER_EVENT)
    assert(count_type(env, "heartbeat") == 3, "and it must keep running afterwards")
  end,

  test_node_survives_failing_heartbeat = function()
    local env = fake_env()
    local node = common_node.new({ id = "N1", role = "signal", config = { channel = 1, master_id = "M" }, modem = env.modem, logger = env.logger, clock = env.clock, start_timer = env.start_timer })
    node.start()
    node.heartbeat = function() error("modem unplugged", 0) end
    env.now = 2
    node.handle_event({ "timer", env.last_id })
    assert(#env.warnings == 1 and env.warnings[1].data.job == "heartbeat")
    node.heartbeat = function() env.sent[#env.sent + 1] = { type = "heartbeat" } end
    env.now = 4
    node.handle_event({ "timer", env.last_id })
    assert(count_type(env, "heartbeat") == 2, "loop must keep ticking after a failed heartbeat")
  end,

  test_sensor_node_reports_occupancy_after_dropped_timer = function()
    local env = fake_env()
    local occupied = false
    local peripherals = {
      methods = function() return { "isTrainPassing" } end,
      wrap = function() return { isTrainPassing = function() return occupied end } end,
      invalidate = function() end
    }
    local node = sensor_node.new_runtime({
      id = "SEN-1", role = "sensor", config = { channel = 1, master_id = "M" }, logger = env.logger,
      peripherals = peripherals, modem = env.modem, clock = env.clock, start_timer = env.start_timer
    })
    node.start()
    occupied = true
    env.now = 0.2 + 1.1
    node.handle_event(NO_TIMER_EVENT)
    assert(count_type(env, "event", "sensor") == 1, "occupancy change must be reported without the sensor timer event")
  end,

  test_train_node_status_survives_dropped_timer = function()
    local env = fake_env()
    local peripherals = { methods = function() return {} end, wrap = function() return nil end, invalidate = function() end }
    local node = train_node.new_runtime({
      id = "TRAIN-1", role = "train", config = { channel = 1, master_id = "M", nodes = {} }, logger = env.logger,
      peripherals = peripherals, modem = env.modem, clock = env.clock, start_timer = env.start_timer
    })
    node.start()
    env.now = 2 + 1.1
    node.handle_event(NO_TIMER_EVENT)
    assert(count_type(env, "event", "train_status") == 1)
  end,

  test_master_marks_silent_node_down_after_dropped_timer = function()
    local env = fake_env()
    local marked_down, ui_draws = {}, 0
    local registry = {
      all = function() return { SIG = { role = "signal", status = "up", last_seen = time.now_s() - 100 } } end,
      mark_down = function(id) marked_down[#marked_down + 1] = id end,
      register = function() end, heartbeat = function() end
    }
    local rt = runtime_factory.new({
      config = { nodes = {} }, logger = env.logger, registry = registry,
      dispatcher = { get_overview = function() return {} end, timeout_node = function() end },
      network = { receive = function() return "ok" end, ack_for = function() end, send = function() end, tick = function() end },
      ui = { mark_dirty = function() end, draw = function() ui_draws = ui_draws + 1 end, handle_touch = function() end },
      auto_restore_state = false, auto_save_state = false,
      clock = env.clock, start_timer = env.start_timer
    })
    rt.start()
    env.now = 1 + 1.1
    rt.handle_event(NO_TIMER_EVENT)
    assert(#marked_down == 1 and marked_down[1] == "SIG", "timeout job must run although its timer event was lost")
    assert(ui_draws >= 2, "ui job must run too")
    local stats = rt.ticker.stats()
    assert(stats.jobs.timeouts.recovered == 1)
  end,

  test_master_survives_failing_ui_draw = function()
    local env = fake_env()
    local draws = 0
    local rt = runtime_factory.new({
      config = { nodes = {} }, logger = env.logger,
      registry = { all = function() return {} end, register = function() end, heartbeat = function() end },
      dispatcher = { get_overview = function() return {} end, timeout_node = function() end },
      network = { receive = function() return "ok" end, ack_for = function() end, send = function() end, tick = function() end },
      ui = { mark_dirty = function() end, draw = function() draws = draws + 1; if draws > 1 then error("monitor gone", 0) end end, handle_touch = function() end },
      auto_restore_state = false, auto_save_state = false,
      clock = env.clock, start_timer = env.start_timer
    })
    rt.start()
    for step = 1, 5 do
      env.now = step * 0.3
      rt.handle_event({ "timer", env.last_id })
    end
    assert(draws >= 3, "ui job must keep ticking after a draw error, got " .. draws)
  end
}
