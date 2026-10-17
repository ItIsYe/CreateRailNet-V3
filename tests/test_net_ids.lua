--[[
Purpose: Message ids must be unique across computers and boots, and duplicate detection must key on sender and id.
Public API: returns table of tests.
Notes: every computer starts its id counter at 1; with bare "msg-<n>" ids two nodes (or one node after a reboot) send the
  same id, and the master drops the second message as a "duplicate" for the next 30 seconds.
]]

pcall(dofile, "tests/harness/cc_bootstrap.lua")

local mock_modem = require("tests.harness.mock_modem")

-- loads net as a freshly booted computer would: new module state, id counter at zero again
local function fresh_net_module()
  local saved = { util = package.loaded["src.shared.util"], net = package.loaded["src.shared.net"] }
  package.loaded["src.shared.util"] = nil
  package.loaded["src.shared.net"] = nil
  local module = require("src.shared.net")
  package.loaded["src.shared.util"] = saved.util
  package.loaded["src.shared.net"] = saved.net
  return module
end

local function clock() return { now_ms = function() return 0 end } end

return {
  test_two_computers_never_send_the_same_message_id = function()
    local a = fresh_net_module().new(mock_modem.new(), 1, "NODE-A", nil, clock())
    local b = fresh_net_module().new(mock_modem.new(), 1, "NODE-B", nil, clock())
    local seen = {}
    for _ = 1, 20 do
      for _, endpoint in ipairs({ a, b }) do
        local msg = endpoint.send("event", "M", {})
        assert(not seen[msg.id], "id sent twice: " .. msg.id)
        seen[msg.id] = true
      end
    end
  end,

  test_a_rebooted_node_does_not_reuse_the_ids_of_its_previous_boot = function()
    local first = fresh_net_module().new(mock_modem.new(), 1, "NODE-A", nil, clock())
    local second = fresh_net_module().new(mock_modem.new(), 1, "NODE-A", nil, clock())
    local before = {}
    for _ = 1, 10 do before[first.send("heartbeat", "M", {}).id] = true end
    for _ = 1, 10 do
      local id = second.send("heartbeat", "M", {}).id
      assert(not before[id], "id of the previous boot reused: " .. id)
    end
  end,

  test_duplicate_detection_keys_on_sender_and_id = function()
    local m = fresh_net_module().new(mock_modem.new(), 1, "M", nil, clock())
    assert(m.receive({ v = 1, id = "msg-1", src = "A", dst = "M", type = "event", payload = {} }) == "ok")
    assert(m.receive({ v = 1, id = "msg-1", src = "B", dst = "M", type = "event", payload = {} }) == "ok", "same id from another sender is a different message")
    assert(m.receive({ v = 1, id = "msg-1", src = "A", dst = "M", type = "event", payload = {} }) == "duplicate")
  end
}
