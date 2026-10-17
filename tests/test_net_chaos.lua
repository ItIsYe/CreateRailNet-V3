--[[
Purpose: Reliable messaging between a sender and a real node over a lossy, duplicating, delaying link.
Public API: returns table of tests.
Notes: the sender must not give up on commands the node already applied, and the node must apply each command once.
]]

pcall(dofile, "tests/harness/cc_bootstrap.lua")

local net = require("src.shared.net")
local time = require("src.shared.time")
local common_node = require("src.nodes.common_node")
local prng = require("tests.harness.prng")
local lossy_link = require("tests.harness.lossy_link")

local function quiet_logger()
  local function noop() end
  return { info = noop, warn = noop, error = noop, debug = noop }
end

-- Sends `count` reliable commands from "M" to node "N1" and runs the clock until everything settled.
local function run(seed, count, link_opts)
  local rng = prng.new(seed)
  local link = lossy_link.new(rng, link_opts)
  local applied, dropped_ids = {}, {}
  local ok, err = pcall(function()
    local sender = net.new(link.modem("M"), 1, "M", quiet_logger(), time)
    local node = common_node.new({
      id = "N1", role = "signal", config = { channel = 1, master_id = "M" }, modem = link.modem("N1"), logger = quiet_logger(),
      handlers = { on_cmd = function(payload) applied[payload.n] = (applied[payload.n] or 0) + 1; return true end }
    })
    sender.on_drop = function(msg) dropped_ids[msg.payload.n] = true end
    link.set_receiver("N1", function(msg) node.handle_event({ "modem_message", "back", 1, 1, msg }) end)
    link.set_receiver("M", function(msg) sender.receive(msg) end)

    local sent = 0
    for step = 1, 3000 do
      if sent < count and step % 6 == 0 then
        sent = sent + 1
        sender.send_reliable("cmd", "N1", { cmd = "set", n = sent })
      end
      link.advance(50)
      sender.tick()
      node.net.tick()
    end
  end)
  local stats = link.stats
  link.close()
  if not ok then error(err, 0) end
  return applied, dropped_ids, stats
end

return {
  test_every_command_is_applied_at_most_once_on_a_duplicating_link = function()
    local applied = run(11, 120, { drop = 0.1, duplicate = 0.4, delay_max_ms = 400 })
    for n, times in pairs(applied) do assert(times == 1, "command " .. n .. " was applied " .. times .. " times") end
  end,

  test_lost_acks_do_not_make_the_sender_give_up_on_delivered_commands = function()
    local applied, dropped = run(12, 150, { drop = 0.05, drop_acks = 0.35, delay_max_ms = 200 })
    local delivered_but_dropped = 0
    for n in pairs(dropped) do if applied[n] then delivered_but_dropped = delivered_but_dropped + 1 end end
    assert(delivered_but_dropped <= 2, delivered_but_dropped .. " commands were applied but never confirmed to the sender")
  end,

  -- pairs() order differs from run to run on Lua 5.4; retries must not
  test_retries_go_out_in_the_order_the_messages_were_sent = function()
    for _ = 1, 8 do
      local sent, now = {}, 0
      local modem = { send = function(_, _, _, msg) sent[#sent + 1] = msg.payload.n; return true end, broadcast = function() return true end }
      local sender = net.new(modem, 1, "M", quiet_logger(), { now_ms = function() return now end })
      for n = 1, 12 do sender.send_reliable("cmd", "N1", { n = n }) end
      sent = {}
      now = 250
      sender.tick()
      for i = 1, 12 do assert(sent[i] == i, "retry " .. i .. " was message " .. tostring(sent[i])) end
    end
  end,

  test_clean_link_delivers_and_confirms_everything = function()
    local applied, dropped = run(13, 60, { drop = 0, duplicate = 0, delay_max_ms = 0 })
    for n = 1, 60 do assert(applied[n] == 1 and not dropped[n], "command " .. n) end
  end
}
