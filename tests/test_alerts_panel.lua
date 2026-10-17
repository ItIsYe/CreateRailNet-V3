--[[
Purpose: Alerts page (list, touch to acknowledge, paging) and the master runtime keeping the list in step with the network.
Public API: returns table of tests.
]]

pcall(dofile, "tests/harness/cc_bootstrap.lua")

local alerts_panel = require("src.master.ui.panels.alerts")
local alerts_module = require("src.domain.alerts")
local runtime_factory = require("src.master.runtime")

local function recording_monitor(w, h)
  local m = { texts = {} }
  m.getSize = function() return w, h end
  m.isColor = function() return true end
  m.setCursorPos = function() end
  m.setBackgroundColor = function() end
  m.setTextColor = function() end
  m.write = function(text) m.texts[#m.texts + 1] = text end
  m.clear = function() m.texts = {} end
  m.text = function() return table.concat(m.texts, "\n") end
  return m
end

local function fake_mc(alerts)
  local calls = {}
  return calls, { handle = function(cmd, src)
    calls[#calls + 1] = cmd
    if cmd.action == "ack_alert" then
      if cmd.all then alerts.ack_all(src) else alerts.ack(cmd.key, src) end
    end
    return true
  end }
end

return {
  test_empty_list_says_so = function()
    local alerts = alerts_module.new()
    local panel = alerts_panel.new(alerts, nil)
    local m = recording_monitor(51, 19)
    panel.draw(m)
    assert(m.text():find("Keine Meldungen", 1, true) and m.text():find("0 offen", 1, true))
  end,

  test_alerts_are_listed_with_counter_and_state = function()
    local alerts = alerts_module.new()
    for _ = 1, 3 do alerts.raise("node:SIG-1", "RED", "SIG-1 antwortet nicht") end
    alerts.raise("block:B2", "RED", "Block B2 gestoert"); alerts.clear("block:B2")
    local panel = alerts_panel.new(alerts, nil)
    local m = recording_monitor(51, 19)
    panel.draw(m)
    local text = m.text()
    assert(text:find("SIG-1 antwortet nicht x3", 1, true), text)
    assert(text:find("Block B2 gestoert behoben", 1, true))
    assert(text:find("2 offen", 1, true))
  end,

  test_touching_a_row_acknowledges_that_alert = function()
    local alerts = alerts_module.new()
    alerts.raise("node:A", "RED", "A weg")
    alerts.raise("node:B", "YELLOW", "B weg")
    local calls, mc = fake_mc(alerts)
    local panel = alerts_panel.new(alerts, mc)
    panel.draw(recording_monitor(51, 19))
    panel.touch(10, 3)
    assert(#calls == 1 and calls[1].key == "node:A" and calls[1].action == "ack_alert")
    assert(alerts.get("node:A").acked == true and alerts.get("node:B").acked == false)
  end,

  test_all_acknowledge_button_and_paging = function()
    local alerts = alerts_module.new()
    for i = 1, 40 do alerts.raise(string.format("node:N%02d", i), "YELLOW", string.format("N%02d weg", i)) end
    local calls, mc = fake_mc(alerts)
    local panel = alerts_panel.new(alerts, mc)
    local m = recording_monitor(51, 19)
    panel.draw(m)
    assert(m.text():find("Seite 1/3", 1, true) or m.text():find("Seite 1/", 1, true))
    panel.touch(40, 19)
    m = recording_monitor(51, 19); panel.draw(m)
    assert(m.text():find("Seite 2/", 1, true))
    panel.touch(30, 19)
    m = recording_monitor(51, 19); panel.draw(m)
    assert(m.text():find("Seite 1/", 1, true))
    panel.touch(5, 19)
    assert(calls[#calls].all == true and alerts.counts().unacked == 0)
  end,

  test_runtime_keeps_the_list_in_step_with_the_network = function()
    local env = { now = 0, last_id = 0, lines = {} }
    local alerts = alerts_module.new()
    local nodes = { SIG = { role = "signal", status = "DOWN", last_seen = math.huge } }
    local rt = runtime_factory.new({
      config = { nodes = {} },
      registry = { all = function() return nodes end, register = function() end, heartbeat = function() end, mark_down = function() end },
      dispatcher = { get_overview = function() return {} end, timeout_node = function() end, get_deadlocks = function() return {} end },
      network = { receive = function() return "ok" end, ack_for = function() end, send = function() end, tick = function() end },
      ui = { mark_dirty = function() end, draw = function() end, handle_touch = function() end },
      alerts = alerts,
      auto_restore_state = false, auto_save_state = false,
      clock = function() return env.now end, start_timer = function() env.last_id = env.last_id + 1; return env.last_id end, tick_grace = 0
    })
    rt.start()
    env.now = 2.1
    rt.handle_event({ "peripheral", "tick" })
    assert(alerts.get("node:SIG") and alerts.get("node:SIG").severity == "RED", "a lost signal node raises a red alert")
    nodes.SIG.status = "UP"
    env.now = 4.2
    rt.handle_event({ "peripheral", "tick" })
    assert(alerts.get("node:SIG").state == "CLEARED" and not alerts.get("node:SIG").acked, "the fault stays listed until somebody acknowledged it")
  end,

  test_rejected_events_raise_a_transient_alert = function()
    local alerts = alerts_module.new()
    local rt = runtime_factory.new({
      config = { nodes = {} },
      registry = { all = function() return {} end, register = function() end, heartbeat = function() end },
      dispatcher = { get_overview = function() return {} end, timeout_node = function() end },
      network = { receive = function() return "ok" end, ack_for = function() end, send = function() end, tick = function() end },
      ui = { mark_dirty = function() end, draw = function() end, handle_touch = function() end },
      alerts = alerts, auto_restore_state = false, auto_save_state = false
    })
    rt.handle_event({ "modem_message", nil, nil, nil, { v = 1, id = "e.1", type = "event", src = "SEN-1", dst = "M", payload = { type = "sensor", sensor_id = "SEN-9", action = "enter" } } })
    local list = alerts.list()
    assert(#list == 1 and list[1].key == "event:SEN-1:sensor" and list[1].severity == "YELLOW" and list[1].expires_at)
  end
}
