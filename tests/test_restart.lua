--[[
Purpose: The controlled restart of the master: the order (state saved, signals to RED, reboot), what happens when a step fails, the button
  that appears only after a computer was accepted, and that a restart needs two touches.
Public API: returns table of tests.
]]

pcall(dofile, "tests/harness/cc_bootstrap.lua")

local restart_module = require("src.master.restart")
local runtime_factory = require("src.master.runtime")
local registry_factory = require("src.shared.registry")
local alerts_module = require("src.domain.alerts")
local pairing_module = require("src.master.pairing")
local setup_panel = require("src.master.ui.panels.setup")
local netplan = require("src.setup.netplan")
local memfs = require("tests.harness.memfs")

local PLAN = "configs/network.json"

return {
  test_signals_go_to_red_before_the_computer_restarts = function()
    local steps = {}
    local go = restart_module.build({
      dispatcher = { shutdown_red = function() steps[#steps + 1] = "red"; return 0 end },
      logger = { info = function() steps[#steps + 1] = "log" end, warn = function() steps[#steps + 1] = "warn" end },
      reboot = function() steps[#steps + 1] = "reboot" end,
    })
    local ok, message = go("MASTER-UI")
    assert(ok and message:find("Neustart", 1, true))
    assert(table.concat(steps, ",") == "red,log,reboot", table.concat(steps, ","))
  end,

  test_a_signal_that_does_not_answer_is_said_but_does_not_stop_the_restart = function()
    local rebooted, warnings = 0, 0
    local logger = { info = function() end, warn = function() warnings = warnings + 1 end }
    local partly = restart_module.build({ dispatcher = { shutdown_red = function() return 2 end }, logger = logger, reboot = function() rebooted = rebooted + 1 end })
    local ok, message = partly("x")
    assert(ok and rebooted == 1 and warnings == 1 and message:find("nicht alle Signale", 1, true))
    local broken = restart_module.build({ dispatcher = { shutdown_red = function() error("boom") end }, logger = logger, reboot = function() rebooted = rebooted + 1 end })
    local ok2 = broken("x")
    assert(ok2 and rebooted == 2 and warnings == 2, "a failing hardware call is no reason to stay up")
  end,

  test_without_red_on_stop_the_signals_are_left_alone = function()
    local called = false
    local go = restart_module.build({ dispatcher = { shutdown_red = function() called = true; return 0 end }, red = false, reboot = function() end })
    assert(go("x") and not called)
  end,

  test_a_computer_that_cannot_restart_says_so = function()
    local go = restart_module.build({ dispatcher = { shutdown_red = function() return 0 end } })
    local ok, message = go("x")
    assert(ok == false and message:find("nicht neu starten", 1, true))
  end,

  -- the runtime ------------------------------------------------------------------------------------------------------------

  test_the_runtime_saves_the_state_audits_and_then_restarts = function()
    local order, audits = {}, {}
    local rt = runtime_factory.new({
      config = { nodes = {} }, registry = registry_factory.new(),
      dispatcher = { get_overview = function() return {} end, timeout_node = function() end, snapshot = function() order[#order + 1] = "snapshot"; return {} end },
      network = { receive = function() return "ok" end, ack_for = function() end, send = function() end, tick = function() end },
      ui = { mark_dirty = function() end, draw = function() end, handle_touch = function() end },
      audit_log = { record = function(kind) audits[#audits + 1] = kind end },
      state_store = { save = function() order[#order + 1] = "saved"; return true end, load = function() return nil, "missing" end },
      restart = function(operator) order[#order + 1] = "restart:" .. tostring(operator); return true, "Neustart ..." end,
      auto_restore_state = false, auto_save_state = true,
    })
    local ok, message = rt.restart_master("MASTER-UI")
    assert(ok and message == "Neustart ...")
    assert(table.concat(order, ",") == "snapshot,saved,restart:MASTER-UI", table.concat(order, ","))
    local audited = false
    for _, kind in ipairs(audits) do if kind == "master_restart" then audited = true end end
    assert(audited)
  end,

  test_a_runtime_without_a_restart_function_refuses = function()
    local rt = runtime_factory.new({
      config = { nodes = {} }, registry = registry_factory.new(),
      dispatcher = { get_overview = function() return {} end, timeout_node = function() end },
      network = { receive = function() return "ok" end, ack_for = function() end, send = function() end, tick = function() end },
      ui = { mark_dirty = function() end, draw = function() end, handle_touch = function() end },
      auto_restore_state = false, auto_save_state = false,
    })
    local ok, message = rt.restart_master("x")
    assert(ok == false and message:find("nicht verfuegbar", 1, true))
  end,

  test_busy_blocks_are_counted = function()
    local rt = runtime_factory.new({
      config = { nodes = {} }, registry = registry_factory.new(),
      dispatcher = { get_overview = function() return { B1 = { state = "FREE" }, B2 = { state = "OCCUPIED" }, B3 = { state = "RESERVED" }, B4 = { state = "FAULT" } } end, timeout_node = function() end },
      network = { receive = function() return "ok" end, ack_for = function() end, send = function() end, tick = function() end },
      ui = { mark_dirty = function() end, draw = function() end, handle_touch = function() end },
      auto_restore_state = false, auto_save_state = false,
    })
    assert(rt.busy_blocks() == 2, "occupied and reserved, not free or faulted")
  end,

  test_accepting_a_computer_asks_for_a_restart_and_rejecting_does_not = function()
    local fs = memfs.new()
    local cfg = { v = 1, channel = 1, master_id = "M", nodes = { { id = "M", role = "master" } }, blocks = {}, routes = {} }
    fs.set(PLAN, netplan.encode(cfg))
    local pairing = pairing_module.new({ config = cfg, plan_path = PLAN, fs = fs })
    local rt = runtime_factory.new({
      config = cfg, registry = registry_factory.new(),
      dispatcher = { get_overview = function() return {} end, timeout_node = function() end },
      network = { receive = function() return "ok" end, ack_for = function() end, send = function() end, tick = function() end, peer_revision = function() return 4 end },
      ui = { mark_dirty = function() end, draw = function() end, handle_touch = function() end },
      alerts = alerts_module.new(), pairing = pairing,
      auto_restore_state = false, auto_save_state = false,
    })
    assert(rt.restart_needed == false)
    pairing.announce("SIG-1", { role = "signal" })
    pairing.announce("SIG-2", { role = "signal" })
    assert(rt.pair_decide("reject", "SIG-2", "x"))
    assert(rt.restart_needed == false, "a rejected computer changes nothing in the plan")
    assert(rt.pair_decide("accept", "SIG-1", "x"))
    assert(rt.restart_needed == true)
  end,

  -- the page -------------------------------------------------------------------------------------------------------------

  test_the_button_appears_after_an_acceptance_and_needs_two_touches = function()
    local clock, needed, restarts, busy = { t = 1000 }, false, {}, 0
    local function monitor()
      local m = { writes = {} }
      m.getSize = function() return 51, 19 end
      m.isColor = function() return true end
      m.setCursorPos = function(x, y) m.x, m.y = x, y end
      m.setBackgroundColor = function() end
      m.setTextColor = function() end
      m.write = function(text) m.writes[#m.writes + 1] = { x = m.x, y = m.y, text = text } end
      m.clear = function() m.writes = {} end
      m.text = function() local parts = {}; for _, item in ipairs(m.writes) do parts[#parts + 1] = item.text end return table.concat(parts, "\n") end
      m.row_of = function(needle) for _, item in ipairs(m.writes) do if item.text:find(needle, 1, true) then return item.y, item.x end end end
      return m
    end
    local panel = setup_panel.new({
      config = { channel = 1, master_id = "M", nodes = {}, blocks = {}, routes = {} }, registry = { all = function() return {} end },
      now_s = function() return clock.t end,
      restart_needed = function() return needed end,
      restart = function(operator) restarts[#restarts + 1] = operator; return true, "Neustart ..." end,
      busy_blocks = function() return busy end,
    })
    local m = monitor()
    panel.draw(m)
    assert(not m.text():find("NEU STARTEN", 1, true), "nothing to restart for")
    needed, busy = true, 3
    m = monitor()
    panel.draw(m)
    local row, column = m.row_of("[MASTER NEU STARTEN]")
    assert(row == 14 and column == 1)
    panel.touch(5, row)
    assert(#restarts == 0, "the first touch only asks")
    m = monitor()
    panel.draw(m)
    assert(m.text():find("[SICHER? SIGNALE ROT]", 1, true), "the button asks")
    assert(m.text():find("belegt", 1, true) and m.text():find("Signale gehen auf ROT", 1, true) and m.text():find("ACHTUNG", 1, true), "what will happen is said")
    panel.touch(5, row)
    assert(#restarts == 1 and restarts[1] == "MASTER-UI")
    m = monitor()
    panel.draw(m)
    assert(m.text():find("Neustart ...", 1, true))
  end,

  test_an_old_first_touch_does_not_count_and_another_place_cancels = function()
    local clock, restarts = { t = 1000 }, 0
    local panel = setup_panel.new({
      config = { channel = 1, master_id = "M", nodes = {}, blocks = {}, routes = {} }, registry = { all = function() return {} end },
      now_s = function() return clock.t end,
      restart_needed = function() return true end, restart = function() restarts = restarts + 1; return true end,
    })
    local m = { writes = {} }
    m.getSize = function() return 51, 19 end
    m.isColor = function() return true end
    m.setCursorPos = function() end
    m.setBackgroundColor = function() end
    m.setTextColor = function() end
    m.write = function(text) m.writes[#m.writes + 1] = text end
    m.clear = function() end
    panel.draw(m)
    panel.touch(3, 14)
    clock.t = clock.t + 30
    panel.touch(3, 14)
    assert(restarts == 0, "the screen was not redrawn in between: the old first touch still must not count")
    clock.t = clock.t + 30
    panel.draw(m)
    panel.touch(3, 14)
    assert(restarts == 0, "after the time ran out the second touch is a first touch")
    panel.touch(3, 14)
    assert(restarts == 1)
    panel.touch(3, 14)
    panel.touch(40, 14)
    panel.touch(3, 14)
    assert(restarts == 1, "a touch beside the button took the question back")
  end,
}
