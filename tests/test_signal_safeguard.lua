--[[
Purpose: Signals do not depend on what they showed before: the master sends them again (at start, in a rolling
  refresh, when a signal node comes back) and puts every signal to RED when it stops.
Public API: returns table of tests.
]]

pcall(dofile, "tests/harness/cc_bootstrap.lua")

local dispatcher = require("src.master.dispatcher")
local runtime_factory = require("src.master.runtime")
local registry_factory = require("src.shared.registry")
local signal_node = require("src.nodes.signal_node")

local STATES = dispatcher.STATES

local function cfg()
  return {
    sensor_guard_min_occupy_ms = 0,
    blocks = {
      { id = "B1", entry_signal = "SE1", exit_signal = "SX1", sensors = { "SEN-1" }, switches = {} },
      { id = "B2", entry_signal = "SE2", exit_signal = "SX2", sensors = { "SEN-2" }, switches = {} },
      { id = "B3", entry_signal = "SE3", exit_signal = "SX3", sensors = { "SEN-3" }, switches = {} }
    },
    routes = {
      { id = "R-12", from = "A", to = "B", blocks = { "B1", "B2" } },
      { id = "R-3", from = "C", to = "D", blocks = { "B3" } }
    }
  }
end

local function adapters()
  local a = { aspects = {}, sent = {}, down = {} }
  a.signals = { setAspect = function(id, aspect)
    a.sent[#a.sent + 1] = id .. "=" .. aspect
    if a.down[id] then return false, "no peripheral" end
    a.aspects[id] = aspect
    return true
  end }
  a.switches = { setPosition = function() return true end }
  return a
end

local function proceed(aspect) return aspect == "GREEN" or aspect == "YELLOW" end

return {
  test_refresh_all_sets_red_except_the_signal_of_a_waiting_train = function()
    local a = adapters()
    local d = dispatcher.new(cfg(), a)
    assert(d.reserve_route("T1", "R-12"))
    -- before the master came up the signals showed anything
    a.aspects.SE1, a.aspects.SE2, a.aspects.SE3, a.aspects.SX3 = "RED", "GREEN", "GREEN", "YELLOW"
    local result = d.refresh_signals()
    assert(result.sent == 3 and result.failed == 0)
    assert(proceed(a.aspects.SE1), "the waiting train gets its signal back")
    assert(a.aspects.SE2 == "RED" and a.aspects.SE3 == "RED" and a.aspects.SX3 == "RED")
  end,

  test_rolling_refresh_visits_blocks_in_turn_and_wraps = function()
    local a = adapters()
    local d = dispatcher.new(cfg(), a)
    d.refresh_signals(1)
    assert(a.sent[1] == "SE1=RED" and a.sent[2] == "SX1=RED" and #a.sent == 2, table.concat(a.sent, ","))
    d.refresh_signals(2)
    assert(a.sent[3] == "SE2=RED" and a.sent[5] == "SE3=RED")
    d.refresh_signals(1)
    assert(a.sent[7] == "SE1=RED", "back at the first block: " .. tostring(a.sent[7]))
    local result = d.refresh_signals(100)
    assert(result.sent == 3, "never more than every block once per call")
  end,

  test_a_signal_that_lost_its_state_is_corrected_within_one_round = function()
    local a = adapters()
    local d = dispatcher.new(cfg(), a)
    assert(d.reserve_route("T1", "R-12"))
    a.aspects.SE1 = "RED"       -- the node rebooted
    a.aspects.SE3 = "GREEN"     -- and this one shows something nobody asked for
    for _ = 1, 3 do d.refresh_signals(1) end
    assert(proceed(a.aspects.SE1) and a.aspects.SE3 == "RED")
  end,

  test_refresh_never_gives_proceed_to_a_train_that_is_not_waiting = function()
    local a = adapters()
    local d = dispatcher.new(cfg(), a)
    assert(d.reserve_route("T1", "R-12"))
    assert(d.on_sensor_event_by_sensor("SEN-1", "enter"))
    d.refresh_signals()
    for _, id in ipairs({ "SE1", "SE2", "SE3", "SX1", "SX2" }) do assert(a.aspects[id] == "RED", id .. " shows " .. tostring(a.aspects[id])) end
    assert(d.on_sensor_event_by_sensor("SEN-1", "leave"))
    d.refresh_signals()
    assert(proceed(a.aspects.SE2) and a.aspects.SE1 == "RED")
  end,

  test_failing_signals_are_counted_and_do_not_fault_blocks = function()
    local a = adapters()
    local d = dispatcher.new(cfg(), a)
    a.down.SE2 = true
    local result = d.refresh_signals()
    assert(result.failed == 1 and result.failed_blocks[1] == "B2")
    assert(d.get_block("B2").state == STATES.FREE)
  end,

  test_resend_touches_only_the_blocks_of_that_signal = function()
    local a = adapters()
    local d = dispatcher.new(cfg(), a)
    assert(d.reserve_route("T1", "R-12"))
    a.sent = {}
    local result = d.resend_signals("SE1")
    assert(result.sent == 1 and #a.sent == 2, table.concat(a.sent, ","))
    assert(a.sent[1]:sub(1, 4) == "SE1=" and proceed(a.aspects.SE1))
    assert(d.resend_signals("NOPE").sent == 0)
  end,

  test_shutdown_puts_every_signal_to_red_and_keeps_the_state = function()
    local a = adapters()
    local d = dispatcher.new(cfg(), a)
    assert(d.reserve_route("T1", "R-12"))
    assert(proceed(a.aspects.SE1))
    a.down.SX2 = true
    local failed = d.shutdown_red()
    assert(failed == 1, failed)
    for _, id in ipairs({ "SE1", "SE2", "SE3", "SX1", "SX3" }) do assert(a.aspects[id] == "RED", id) end
    assert(d.get_trains()["T1"].state == "RESERVED" and d.get_block("B1").state == STATES.RESERVED, "state is untouched")
    -- a restart gives the waiting train its GREEN back
    local a2 = adapters()
    local d2 = dispatcher.new(cfg(), a2)
    assert(d2.restore(d.snapshot()))
    d2.refresh_signals()
    assert(proceed(a2.aspects.SE1))
  end,

  test_shutdown_survives_a_signal_adapter_that_raises = function()
    local a = adapters()
    a.signals.setAspect = function() error("peripheral gone") end
    local d = dispatcher.new(cfg(), a)
    assert(d.shutdown_red() == 6)
  end,

  test_signal_node_starts_with_red = function()
    local calls = {}
    local peripherals = {
      methods = function() return { "setForcedRed" } end,
      wrap = function(name) if name == "monitor" then return nil end; return { setForcedRed = function(v) calls[#calls + 1] = v end } end,
      invalidate = function() end
    }
    local modem = { open = function() return true end, send = function() return true end, broadcast = function() return true end }
    signal_node.new_runtime({
      id = "SIG-1", role = "signal", config = { channel = 1, master_id = "M", nodes = { { id = "SIG-1", role = "signal" } } },
      logger = { info = function() end, warn = function() end, error = function() end, debug = function() end },
      peripherals = peripherals, modem = modem
    })
    assert(calls[1] == true, "forced red at start")
  end,

  -- master wiring --------------------------------------------------------------------------------------------

  test_master_refreshes_at_start_and_in_a_job = function()
    local calls = { refresh = {}, resend = {} }
    local reg = registry_factory.new()
    local dispatcher_stub = {
      get_overview = function() return {} end, timeout_node = function() end,
      refresh_signals = function(limit) calls.refresh[#calls.refresh + 1] = limit or "all"; return { sent = 1, failed = 0, failed_blocks = {} } end,
      resend_signals = function(id) calls.resend[#calls.resend + 1] = id; return { sent = 1, failed = 0, failed_blocks = {} } end
    }
    local function build(extra)
      local config = { nodes = {} }
      for k, v in pairs(extra or {}) do config[k] = v end
      calls.refresh, calls.resend = {}, {}
      return runtime_factory.new({
        config = config, registry = reg, dispatcher = dispatcher_stub,
        network = { receive = function() return "ok" end, ack_for = function() end, send = function() end, tick = function() end },
        ui = { mark_dirty = function() end, draw = function() end, handle_touch = function() end },
        auto_restore_state = false, auto_save_state = false,
        pull_event = function() error("stop") end
      })
    end
    local rt = build()
    pcall(rt.start)
    assert(calls.refresh[1] == "all", "everything once at start: " .. tostring(calls.refresh[1]))
    rt.refresh_signals()
    assert(calls.refresh[#calls.refresh] == 2, "two blocks per second by default")
    rt = build({ signal_refresh_per_s = 5 })
    rt.refresh_signals()
    assert(calls.refresh[1] == 5)
    rt = build({ signal_refresh_per_s = 0 })
    pcall(rt.start)
    rt.refresh_signals()
    assert(#calls.refresh == 0, "switched off")
  end,

  test_master_resends_when_a_signal_node_registers_or_returns = function()
    local resent = {}
    local reg = registry_factory.new()
    local rt = runtime_factory.new({
      config = { nodes = { { id = "SIG-1", role = "signal" }, { id = "SEN-1", role = "sensor" } } }, registry = reg,
      dispatcher = {
        get_overview = function() return {} end, timeout_node = function() end,
        resend_signals = function(id) resent[#resent + 1] = id; return { sent = 1, failed = 0, failed_blocks = {} } end
      },
      network = { receive = function() return "ok" end, ack_for = function() end, send = function() end, tick = function() end },
      ui = { mark_dirty = function() end, draw = function() end, handle_touch = function() end },
      auto_restore_state = false, auto_save_state = false
    })
    local function send(kind, src, payload) rt.handle_event({ "modem_message", nil, nil, nil, { v = 1, id = src .. "." .. kind .. #resent, type = kind, src = src, dst = "M", payload = payload } }) end
    send("register", "SIG-1", { role = "signal" })
    assert(resent[1] == "SIG-1")
    reg.mark_down("SIG-1")
    send("heartbeat", "SIG-1", { role = "signal" })
    assert(resent[2] == "SIG-1", "back after an outage")
    send("heartbeat", "SIG-1", { role = "signal" })
    assert(#resent == 2, "a normal heartbeat is no reason")
    send("register", "SEN-1", { role = "sensor" })
    assert(#resent == 2, "sensors have no signals")
  end
}
