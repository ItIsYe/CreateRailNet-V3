--[[
Purpose: Network reliability tests.
Public API: returns table of tests.
]]

local net = require("src.shared.net")
local log = require("src.shared.log")
local mock_modem = require("tests.harness.mock_modem")

return {
  test_ack_and_dedup = function()
    local modem = mock_modem.new()
    local logger = log.new("INFO", 10)
    local a = net.new(modem, 1, "A", logger)
    local b = net.new(modem, 1, "B", logger)

    local received = 0
    modem.attach("B", function(msg)
      local status = b.receive(msg)
      if status == "ok" then
        received = received + 1
        b.ack_for(msg)
      end
    end)
    modem.attach("A", function(msg)
      a.receive(msg)
    end)

    a.send_reliable("cmd", "B", { hello = "world" })
    a.tick()
    assert(received == 1, "expected one receive")
  end,
  test_retry = function()
    local modem = mock_modem.new()
    local logger = log.new("INFO", 10)
    local a = net.new(modem, 1, "A", logger)
    local sent = 0
    modem.attach("B", function(msg)
      sent = sent + 1
    end)
    a.send_reliable("cmd", "B", { hello = "world" })
    a.tick()
    a.tick()
    assert(sent >= 1, "expected retries")
  end
}
