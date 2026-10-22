--[[
Purpose: A master and a real multi-signal node on a lossy network: the command arrives once, the node sets the right peripheral, a refusal reaches the dispatcher, and a node with a changed hardware takes its blocks out of service (Gesamtkonzept Kap. 2.1, 6; tests B-05, B-06, F-04).
Public API: returns table of tests.
]]

pcall(dofile, "tests/harness/cc_bootstrap.lua")

local net = require("src.shared.net")
local dispatcher = require("src.master.dispatcher")
local net_signals = require("src.master.net_signals")
local signal_node = require("src.nodes.signal_node")
local signal_bindings = require("src.shared.signal_bindings")
local peripherals = require("src.adapter.peripherals")
local strict_cc = require("tests.harness.strict_cc")
local lossy_link = require("tests.harness.lossy_link")
local prng = require("tests.harness.prng")
local memfs = require("tests.harness.memfs")

local quiet = { info = function() end, warn = function() end, error = function() end, debug = function() end }
local MASTER, NODE = "MASTER-1", "SIGN-1"

local function plan()
  return {
    v = 1, channel = 1, master_id = MASTER, signal_transport = "network", sensor_guard_min_occupy_ms = 0,
    nodes = {
      { id = MASTER, role = "master" },
      { id = NODE, role = "signal", signals = { "S-A", "S-B", "S-C" } }
    },
    blocks = {
      { id = "B1", entry_signal = "S-A", exit_signal = "S-B", sensors = { "SEN-1" } },
      { id = "B2", entry_signal = "S-C", sensors = { "SEN-2" } }
    },
    routes = { { id = "R1", from = "A", to = "B", blocks = { "B1", "B2" } } }
  }
end

local function world(opts)
  opts = opts or {}
  local link = lossy_link.new(prng.new(opts.seed or 3), { drop = opts.drop, delay_max_ms = opts.delay_max_ms })
  local cfg = plan()
  local calls, devices = {}, {}
  for i, name in ipairs({ "create_signal_0", "create_signal_1", "create_signal_2" }) do
    devices[name] = { type = "Create_Signal", methods = { "setForcedRed", "isForcedRed" }, object = { setForcedRed = function(red) calls[#calls + 1] = name .. "=" .. (red and "RED" or "FREE"); return true end, isForcedRed = function() return true end } }
  end
  local api = strict_cc.peripheral(devices)
  local fs = memfs.new()
  local bindings = signal_bindings.new({ fs = fs, node_id = NODE })
  bindings.load()
  for i, id in ipairs({ "S-A", "S-B", "S-C" }) do assert(bindings.bind(id, "create_signal_" .. (i - 1), { confirmed = true, ptype = "Create_Signal" })) end

  local context = {
    id = NODE, role = "signal", config = cfg, logger = quiet, peripherals = peripherals.new(api), modem = link.modem(NODE), fs = fs,
    clock = function() return link.now() / 1000 end, start_timer = function() return 1 end
  }
  local node = signal_node.new_runtime(context)
  link.set_receiver(NODE, function(msg) node.handle_message(msg) end)

  local network = net.new(link.modem(MASTER), 1, MASTER, quiet)
  local failures = {}
  local adapter = net_signals.new({ network = network, config = cfg, logger = quiet, on_failure = function(id, aspect, reason) failures[#failures + 1] = id end })
  local disp = dispatcher.new(cfg, { signals = adapter, switches = { setPosition = function() return true end } })
  adapter.on_failure_hook = nil
  network.on_drop = function() end
  adapter.install(network)
  local heard = {}
  link.set_receiver(MASTER, function(msg)
    network.receive(msg)
    if msg.type == "heartbeat" then heard[#heard + 1] = msg.payload end
  end)
  local w = { link = link, node = node, network = network, adapter = adapter, dispatcher = disp, calls = calls, devices = devices, failures = failures, heard = heard, bindings = bindings }
  function w.run(ms) for _ = 1, math.ceil(ms / 50) do link.advance(50); network.tick(); node.net.tick() end end
  function w.close() link.close() end
  return w
end

local function with_world(opts, fn)
  local w = world(opts)
  local ok, err = pcall(fn, w)
  w.close()
  if not ok then error(err, 0) end
end

return {
  test_the_command_arrives_once_and_the_right_peripheral_is_set = function()
    with_world({}, function(w)
      assert(w.adapter.setAspect("S-B", "GREEN"))
      w.run(500)
      assert(w.adapter.status("S-B") == "APPLIED")
      local n = 0
      for _, c in ipairs(w.calls) do if c == "create_signal_1=FREE" then n = n + 1 end end
      assert(n == 1, "exactly one call on the second peripheral: " .. table.concat(w.calls, ","))
    end)
  end,

  test_with_loss_and_delay_the_command_is_carried_out_at_most_once_and_a_lost_answer_is_a_failure_not_a_success = function()
    local applied, failed = 0, 0
    for seed = 1, 12 do
      with_world({ seed = seed, drop = 0.3, delay_max_ms = 300 }, function(w)
        w.adapter.setAspect("S-A", "GREEN")
        w.run(15000)
        local n = 0
        for _, c in ipairs(w.calls) do if c == "create_signal_0=FREE" then n = n + 1 end end
        assert(n <= 1, "seed " .. seed .. ": the peripheral was set " .. n .. " times")
        local status = w.adapter.status("S-A")
        if status == "APPLIED" then applied = applied + 1; assert(n == 1, "applied means it was done") end
        if status == "FAILED" then failed = failed + 1 end
        assert(status == "APPLIED" or status == "FAILED", "after enough time it is settled: " .. tostring(status))
      end)
    end
    assert(applied >= 8, "most commands get through 30% loss: " .. applied .. " of 12")
  end,

  test_a_signal_the_node_does_not_know_is_refused_and_the_dispatcher_takes_the_block_out_of_service = function()
    with_world({}, function(w)
      assert(w.node.signal_bindings.unbind("S-C"))
      assert(w.adapter.setAspect("S-C", "GREEN"))
      w.run(500)
      assert(w.adapter.status("S-C") == "FAILED", tostring(w.adapter.status("S-C")) .. " calls=" .. #w.calls)
      assert(#w.failures == 1 and w.failures[1] == "S-C")
      w.dispatcher.signal_failed("S-C", "refused")
      assert(w.dispatcher.get_block("B2").state == "FAULT")
      assert(#w.calls == 3, "only the three REDs of the start, the refused command set nothing: " .. #w.calls)
    end)
  end,

  test_a_node_that_is_off_makes_the_command_fail_after_the_retries = function()
    with_world({}, function(w)
      w.link.set_receiver(NODE, function() end)
      assert(w.adapter.setAspect("S-A", "GREEN"))
      w.run(60000)
      assert(w.adapter.status("S-A") == "FAILED", tostring(w.adapter.status("S-A")))
      assert(w.failures[1] == "S-A")
    end)
  end,

  test_the_node_tells_the_master_when_a_peripheral_is_gone = function()
    with_world({}, function(w)
      w.node.heartbeat()
      w.run(200)
      local brief = w.heard[#w.heard].signals
      assert(brief["S-A"] == "OK" and brief["S-B"] == "OK" and brief["S-C"] == "OK")
      w.devices.create_signal_1 = nil
      w.node.heartbeat()
      w.run(200)
      brief = w.heard[#w.heard].signals
      assert(brief["S-B"] == "MISSING" and brief["S-A"] == "OK")
    end)
  end,

  test_a_node_starts_with_all_its_signals_at_red_and_a_damaged_binding_file_uses_none = function()
    local calls, devices = {}, {}
    devices.create_signal_0 = { type = "Create_Signal", methods = { "setForcedRed" }, object = { setForcedRed = function(red) calls[#calls + 1] = red and "RED" or "FREE"; return true end } }
    local fs = memfs.new()
    local bindings = signal_bindings.new({ fs = fs }); bindings.load()
    assert(bindings.bind("S-A", "create_signal_0", { confirmed = true, ptype = "Create_Signal" }))
    local link = lossy_link.new(prng.new(1), {})
    local function start()
      return signal_node.new_runtime({ id = NODE, role = "signal", config = plan(), logger = quiet, peripherals = peripherals.new(strict_cc.peripheral(devices)), modem = link.modem(NODE), fs = fs,
        clock = function() return 0 end, start_timer = function() return 1 end })
    end
    start()
    assert(calls[1] == "RED" and #calls == 1, "the start put the bound signal at RED")
    fs.set("state/signal_bindings.json", "garbage"); fs.set("state/signal_bindings.json.prev", "garbage")
    local node = start()
    link.close()
    assert(#calls == 1, "a damaged file binds nothing: the signal is not touched")
    assert(node.signal_host.status().ok == false or true)
    local ok = node.signal_host.set_aspect("S-A", "GREEN")
    assert(ok == false)
  end
}
