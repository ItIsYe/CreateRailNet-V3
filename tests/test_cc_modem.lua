--[[
Purpose: The modem adapter against a modem that is as strict as the one in the game. The fakes of the other tests ignore their arguments; the real
  peripheral checks that the channel is a number, so a method that is called with the wrong arguments finds out only in the game.
Public API: returns table of tests.
]]

pcall(dofile, "tests/harness/cc_bootstrap.lua")

local cc_modem = require("src.adapter.cc_modem")
local net = require("src.shared.net")

local quiet = { info = function() end, warn = function() end, error = function() end, debug = function() end }

-- what peripheral.wrap("modem") gives in CC:Tweaked: open(channel), transmit(channel, replyChannel, payload), isOpen(channel); numbers are checked
local function strict_modem()
  local m = { opened = {}, transmitted = {} }
  local function number(value, position, name)
    if type(value) ~= "number" then error("bad argument #" .. position .. " (number expected, got " .. type(value) .. ") in " .. name, 3) end
  end
  m.open = function(channel) number(channel, 1, "open"); m.opened[channel] = true end
  m.close = function(channel) number(channel, 1, "close"); m.opened[channel] = nil end
  m.isOpen = function(channel) number(channel, 1, "isOpen"); return m.opened[channel] == true end
  m.transmit = function(channel, reply, payload)
    number(channel, 1, "transmit"); number(reply, 2, "transmit")
    m.transmitted[#m.transmitted + 1] = { channel = channel, reply = reply, payload = payload }
  end
  return m
end

return {
  test_the_channel_is_opened_the_way_the_nodes_and_the_master_ask_for_it = function()
    local raw = strict_modem()
    local adapter = cc_modem.new({ modem = raw, channel = 777 })
    -- app.lua, common_node.lua and the setup tools all call modem:open(channel)
    local ok, err = adapter:open(777)
    assert(ok == true, tostring(err))
    assert(raw.opened[777], "the channel of the plan is open on the peripheral")
  end,

  test_a_message_leaves_through_net_with_a_channel_and_a_reply_channel = function()
    local raw = strict_modem()
    local adapter = cc_modem.new({ modem = raw, channel = 777 })
    local network = net.new(adapter, 777, "SIG-1", quiet)
    local msg, err = network.send("heartbeat", "MASTER-1", { role = "signal" })
    assert(msg, tostring(err))
    assert(#raw.transmitted == 1)
    local sent = raw.transmitted[1]
    assert(sent.channel == 777 and sent.reply == 777, "channel and reply channel are numbers")
    assert(sent.payload == msg and sent.payload.dst == "MASTER-1" and sent.payload.src == "SIG-1", "the payload is the message, not its destination")
  end,

  test_a_broadcast_goes_out_on_the_channel = function()
    local raw = strict_modem()
    local adapter = cc_modem.new({ modem = raw, channel = 5 })
    local network = net.new(adapter, 5, "N1", quiet)
    local msg, err = network.send("event", "broadcast", { type = "ota_result" })
    assert(msg, tostring(err))
    assert(raw.transmitted[1].channel == 5 and raw.transmitted[1].payload.dst == "broadcast")
  end,

  test_a_reliable_message_is_sent_again_through_the_same_adapter = function()
    local raw = strict_modem()
    local adapter = cc_modem.new({ modem = raw, channel = 777 })
    local network = net.new(adapter, 777, "N1", quiet)
    assert(network.send_reliable("event", "MASTER-1", { type = "sensor" }))
    assert(#raw.transmitted == 1)
  end,

  test_without_a_modem_nothing_is_sent_and_nothing_is_raised = function()
    local adapter = cc_modem.new({ peripheral_api = { find = function() return nil end, wrap = function() return nil end } })
    local ok, err = adapter:open(777)
    assert(ok == false and err:find("unavailable", 1, true))
    local sent, why = adapter:send(777, "MASTER-1", {})
    assert(sent == false and why:find("unavailable", 1, true))
  end,

  test_a_modem_that_refuses_is_reported_not_raised = function()
    local raw = strict_modem()
    raw.transmit = function() error("Too many messages") end
    raw.open = function() error("Too many open channels") end
    local adapter = cc_modem.new({ modem = raw, channel = 777 })
    local opened, open_err = adapter:open(777)
    assert(opened == false and open_err:find("Too many open channels", 1, true))
    local sent, send_err = adapter:send(777, "M", {})
    assert(sent == false and send_err:find("Too many messages", 1, true))
  end,

  test_incoming_modem_messages_are_unpacked = function()
    local adapter = cc_modem.new({ modem = strict_modem(), channel = 777 })
    local payload = { v = 1 }
    assert(adapter:poll({ "modem_message", "top", 777, 777, payload, 3 }) == payload)
    assert(adapter:poll({ "timer", 1 }) == nil and adapter:poll("nonsense") == nil)
  end,
}
