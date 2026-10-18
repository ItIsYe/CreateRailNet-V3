--[[
Purpose: Alerts: one entry per cause, acknowledgement, red faults stay until seen, bounded list, rules from the status model.
Public API: returns table of tests.
]]

pcall(dofile, "tests/harness/cc_bootstrap.lua")

local alerts_module = require("src.domain.alerts")
local alert_rules = require("src.domain.alert_rules")

local function new_alerts(opts)
  local env = { now = 1000 }
  local o = { now_s = function() return env.now end }
  for k, v in pairs(opts or {}) do o[k] = v end
  env.alerts = alerts_module.new(o)
  return env
end

return {
  test_the_same_cause_is_one_entry_with_a_counter = function()
    local env = new_alerts()
    for _ = 1, 5 do env.alerts.raise("node:SIG-1", "RED", "SIG-1 antwortet nicht") end
    local list = env.alerts.list()
    assert(#list == 1 and list[1].count == 5 and list[1].severity == "RED")
  end,

  test_a_cleared_red_alert_stays_until_somebody_acknowledged_it = function()
    local env = new_alerts()
    env.alerts.raise("block:B1", "RED", "Block B1 gestoert")
    assert(env.alerts.clear("block:B1"))
    local list = env.alerts.list()
    assert(#list == 1 and list[1].state == "CLEARED" and not list[1].acked)
    assert(env.alerts.counts().unacked == 1 and env.alerts.counts().active_red == 0)
    assert(env.alerts.ack("block:B1", "PANEL-1"))
    assert(#env.alerts.list() == 0, "cleared and acknowledged: gone")
  end,

  test_a_cleared_yellow_alert_expires_by_itself = function()
    local env = new_alerts({ clear_ttl_s = 100 })
    env.alerts.raise("node:T1", "YELLOW", "T1 weg")
    env.alerts.clear("node:T1")
    env.now = env.now + 50; env.alerts.tick()
    assert(#env.alerts.list() == 1)
    env.now = env.now + 60; env.alerts.tick()
    assert(#env.alerts.list() == 0)
  end,

  test_raising_a_cleared_key_again_reopens_it_unacknowledged = function()
    local env = new_alerts()
    env.alerts.raise("node:S1", "RED", "weg")
    env.alerts.ack("node:S1", "A")
    env.alerts.clear("node:S1")
    assert(#env.alerts.list() == 0)
    env.alerts.raise("node:S1", "RED", "wieder weg")
    local e = env.alerts.get("node:S1")
    assert(e.state == "ACTIVE" and e.acked == false)
    env.alerts.ack("node:S1", "A")
    env.alerts.raise("node:S1", "RED", "schon wieder")
    assert(env.alerts.get("node:S1").acked == true, "raising an active acknowledged alert does not un-acknowledge it")
  end,

  test_transient_alerts_clear_themselves_unless_raised_again = function()
    local env = new_alerts()
    env.alerts.raise("event:X", "YELLOW", "abgelehnt", nil, { ttl_s = 60 })
    env.now = env.now + 30; env.alerts.tick()
    env.alerts.raise("event:X", "YELLOW", "abgelehnt", nil, { ttl_s = 60 })
    env.now = env.now + 45; env.alerts.tick()
    assert(env.alerts.get("event:X").state == "ACTIVE", "raised again, so the clock restarted")
    env.now = env.now + 30; env.alerts.tick()
    assert(env.alerts.get("event:X").state == "CLEARED")
  end,

  test_list_puts_unacknowledged_red_first_and_pages = function()
    local env = new_alerts()
    env.alerts.raise("a", "YELLOW", "gelb"); env.now = env.now + 1
    env.alerts.raise("b", "RED", "rot"); env.now = env.now + 1
    env.alerts.raise("c", "RED", "rot alt, quittiert"); env.alerts.ack("c", "A"); env.now = env.now + 1
    env.alerts.raise("d", "RED", "rot, behoben"); env.alerts.clear("d")
    local keys = {}
    for _, e in ipairs(env.alerts.list()) do keys[#keys + 1] = e.key end
    assert(table.concat(keys, ",") == "b,a,c,d", table.concat(keys, ","))
    local page = env.alerts.list({ limit = 2, offset = 1 })
    assert(#page == 2 and page[1].key == "a" and page[2].key == "c")
    assert(#env.alerts.list({ active_only = true }) == 3)
  end,

  test_ack_all_acknowledges_everything_open = function()
    local env = new_alerts()
    env.alerts.raise("a", "RED", "x"); env.alerts.raise("b", "YELLOW", "y")
    assert(env.alerts.ack_all("PANEL-1") == 2)
    assert(env.alerts.counts().unacked == 0)
  end,

  test_the_list_is_bounded_and_keeps_unacknowledged_red_longest = function()
    local env = new_alerts({ capacity = 10 })
    env.alerts.raise("important", "RED", "wichtig")
    for i = 1, 40 do env.now = env.now + 1; env.alerts.raise("noise:" .. i, "YELLOW", "rauschen") end
    assert(env.alerts.counts().total == 10)
    assert(env.alerts.get("important"), "an unacknowledged red alert outlives yellow noise")
    local cleared = new_alerts({ capacity = 5 })
    for i = 1, 5 do cleared.alerts.raise("k" .. i, "RED", "x"); cleared.alerts.clear("k" .. i) end
    cleared.alerts.raise("live", "RED", "aktiv")
    assert(cleared.alerts.get("live") and cleared.alerts.counts().total == 5)
  end,

  test_losing_unacknowledged_red_alerts_is_counted = function()
    local env = new_alerts({ capacity = 3 })
    for i = 1, 8 do env.now = env.now + 1; env.alerts.raise("r" .. i, "RED", "x") end
    assert(env.alerts.counts().total == 3 and env.alerts.counts().dropped == 5)
  end,

  test_rules_follow_the_network_state = function()
    local env = new_alerts()
    local rules = alert_rules.new(env.alerts)
    local inputs = { nodes = { SIG1 = { role = "signal", status = "DOWN" }, T1 = { role = "train", status = "UP" } }, blocks = { B1 = { state = "FAULT" } } }
    assert(rules.evaluate(inputs) == 2)
    assert(env.alerts.get("node:SIG1").severity == "RED" and env.alerts.get("block:B1"))
    rules.evaluate(inputs)
    assert(env.alerts.get("node:SIG1").count == 2, "a repeated evaluation counts up")
    inputs.nodes.SIG1.status = "UP"
    inputs.blocks.B1.state = "FREE"
    assert(rules.evaluate(inputs) == 0)
    assert(env.alerts.get("node:SIG1").state == "CLEARED" and env.alerts.get("block:B1").state == "CLEARED")
  end,

  test_a_large_network_does_not_flood_the_list = function()
    local env = new_alerts()
    local rules = alert_rules.new(env.alerts)
    local nodes = {}
    for i = 1, 1500 do nodes["N" .. i] = { role = "train", status = "DOWN" } end
    rules.evaluate({ nodes = nodes, blocks = {} })
    assert(env.alerts.counts().total <= 200)
  end
}
