--[[
Purpose: Several signals on one computer: each logical signal goes to the peripheral it was bound to, a signal that cannot be trusted stays at RED and says why (Gesamtkonzept Kap. 6, tests B-05, B-06, F-04).
Public API: returns table of tests.
]]

pcall(dofile, "tests/harness/cc_bootstrap.lua")

local signal_host = require("src.nodes.signal_host")
local signal_bindings = require("src.shared.signal_bindings")
local peripherals = require("src.adapter.peripherals")
local strict_cc = require("tests.harness.strict_cc")
local memfs = require("tests.harness.memfs")

local quiet = { info = function() end, warn = function() end, error = function() end, debug = function() end }

local function signal_object(log, name)
  return { setForcedRed = function(red) log[#log + 1] = name .. "=" .. (red and "RED" or "FREE"); return true end, isForcedRed = function() return true end }
end

-- n signals plus a modem; devices can be replaced to play a hardware change
local function world(count, opts)
  opts = opts or {}
  local log, devices = {}, {}
  for i = 0, count - 1 do
    local name = "create_signal_" .. i
    devices[name] = { type = "Create_Signal", methods = { "setForcedRed", "isForcedRed", "getState" }, object = signal_object(log, name) }
  end
  devices.modem_0 = { type = "modem", methods = { "getNameLocal" }, object = {} }
  local api = strict_cc.peripheral(devices)
  local per = peripherals.new(api)
  local fs = opts.fs or memfs.new()
  local bindings = signal_bindings.new({ fs = fs, node_id = "SIG-NODE" })
  bindings.load()
  for i = 0, count - 1 do
    assert(bindings.bind("SIG-" .. string.char(65 + i), "create_signal_" .. i, { confirmed = true, ptype = "Create_Signal", track_id = "T" .. i }))
  end
  local host = signal_host.new({ bindings = bindings, peripherals = per, logger = quiet, expected = opts.expected })
  return { host = host, log = log, devices = devices, api = api, bindings = bindings, per = per }
end

local function calls(w, name)
  local n = 0
  for _, entry in ipairs(w.log) do if entry:find(name, 1, true) then n = n + 1 end end
  return n
end

return {
  test_each_logical_signal_goes_to_its_own_peripheral = function()
    local w = world(8)
    for i = 0, 7 do
      local id = "SIG-" .. string.char(65 + i)
      assert(w.host.set_aspect(id, "GREEN"), id)
      assert(w.log[#w.log] == "create_signal_" .. i .. "=FREE", w.log[#w.log])
    end
    assert(w.host.set_aspect("SIG-C", "RED") and w.log[#w.log] == "create_signal_2=RED")
    assert(#w.log == 9, "one call per command, no other signal was touched")
  end,

  test_a_signal_that_is_not_bound_is_refused_and_nothing_else_moves = function()
    local w = world(4)
    local ok, err = w.host.set_aspect("SIG-NOPE", "GREEN")
    assert(not ok and err:find("not bound", 1, true), tostring(err))
    assert(#w.log == 0)
  end,

  test_a_missing_peripheral_refuses_green_and_is_reported = function()
    local w = world(4)
    w.devices.create_signal_1 = nil
    local ok, err = w.host.set_aspect("SIG-B", "GREEN")
    assert(not ok and err:find("missing", 1, true), tostring(err))
    local red_ok, red_err = w.host.set_aspect("SIG-B", "RED")
    assert(not red_ok, "RED cannot be set either: the master hears that and treats the block as faulty: " .. tostring(red_err))
    assert(w.host.set_aspect("SIG-A", "GREEN"), "the others work")
    local status = w.host.status()
    assert(status.signals["SIG-B"].state == "MISSING" and status.signals["SIG-A"].state == "OK" and status.ok == false)
  end,

  test_a_peripheral_of_another_type_is_no_signal_any_more = function()
    local w = world(2)
    w.devices.create_signal_0 = { type = "monitor", methods = { "write" }, object = {} }
    local ok, err = w.host.set_aspect("SIG-A", "GREEN")
    assert(not ok and err:find("type", 1, true), tostring(err))
    assert(calls(w, "create_signal_0") == 0)
  end,

  test_a_new_signal_peripheral_is_reported_and_not_used = function()
    local w = world(2)
    w.devices.create_signal_9 = { type = "Create_Signal", methods = { "setForcedRed" }, object = signal_object(w.log, "create_signal_9") }
    local status = w.host.status()
    assert(status.ok == false and status.unbound[1] == "create_signal_9")
    assert(not w.host.set_aspect("create_signal_9", "GREEN"), "it has no logical id")
    assert(calls(w, "create_signal_9") == 0)
  end,

  test_at_the_start_and_before_an_update_every_usable_signal_goes_to_red = function()
    local w = world(4)
    w.devices.create_signal_2 = nil
    local ok, failed = w.host.all_red()
    assert(ok == false and #failed == 1 and failed[1] == "SIG-C", "one signal cannot be set, it is named")
    local reds = 0
    for _, entry in ipairs(w.log) do if entry:find("=RED", 1, true) then reds = reds + 1 end end
    assert(reds == 3)
    local w2 = world(3)
    assert(w2.host.all_red() == true)
  end,

  test_the_state_of_each_signal_is_tracked_as_last_commanded = function()
    local w = world(2)
    w.host.set_aspect("SIG-A", "GREEN")
    w.host.set_aspect("SIG-B", "RED")
    local s = w.host.status().signals
    assert(s["SIG-A"].last == "GREEN" and s["SIG-B"].last == "RED")
    w.devices.create_signal_0 = nil
    assert(w.host.status().signals["SIG-A"].last == nil, "after a loss nobody knows what it shows")
  end,

  test_the_topology_of_the_master_decides_which_signals_are_expected = function()
    local w = world(3, { expected = { "SIG-A", "SIG-B", "SIG-X" } })
    local status = w.host.status()
    assert(status.topology.ok == false and status.topology.unbound[1] == "SIG-X" and status.topology.unknown[1] == "SIG-C")
    local ok, err = w.host.set_aspect("SIG-C", "GREEN")
    assert(not ok and err:find("master", 1, true), "a bound signal the master does not know is never used: " .. tostring(err))
    assert(w.host.set_aspect("SIG-A", "GREEN"))
    local brief = w.host.brief()
    assert(brief["SIG-A"] == "OK" and brief["SIG-X"] == "UNBOUND" and brief["SIG-C"] == "UNKNOWN")
  end,

  test_the_peripheral_call_failing_is_an_error_not_a_silent_success = function()
    local w = world(2)
    w.devices.create_signal_0.object.setForcedRed = function() error("boom") end
    local ok, err = w.host.set_aspect("SIG-A", "GREEN")
    assert(not ok and err:find("boom", 1, true), tostring(err))
    assert(w.host.status().signals["SIG-A"].last == nil)
  end
}
