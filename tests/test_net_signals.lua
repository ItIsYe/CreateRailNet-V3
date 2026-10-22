--[[
Purpose: The signal adapter of the master that talks to signal nodes over the network: where a command goes, what counts as received, applied or failed, and what the dispatcher does with a signal that failed (Gesamtkonzept Kap. 2.1, 6, S-06; tests B-05, F-04).
Public API: returns table of tests.
]]

local net_signals = require("src.master.net_signals")
local dispatcher = require("src.master.dispatcher")

local quiet = { info = function() end, warn = function() end, error = function() end, debug = function() end }

local function plan()
  return {
    signal_transport = "network",
    nodes = {
      { id = "SIGN-1", role = "signal", signals = { "S-A", "S-B", "S-C" } },
      { id = "SIGN-2", role = "signal", signals = { "S-D" } },
      { id = "SIG-SOLO", role = "signal" },
      { id = "SEN-1", role = "sensor" }
    },
    blocks = {
      { id = "B1", entry_signal = "S-A", exit_signal = "S-B", sensors = { "SEN-1" } },
      { id = "B2", entry_signal = "S-D", exit_signal = "SIG-SOLO", sensors = { "SEN-1" } }
    },
    routes = { { id = "R1", from = "A", to = "B", blocks = { "B1", "B2" } } }
  }
end

local function fake_network()
  local n = { sent = {}, seq = 0, refuse = false }
  function n.send_reliable(msg_type, dst, payload)
    if n.refuse then return nil, "refused" end
    n.seq = n.seq + 1
    local msg = { id = "m" .. n.seq, type = msg_type, dst = dst, payload = payload }
    n.sent[#n.sent + 1] = msg
    return msg
  end
  return n
end

local function new(extra)
  local network = fake_network()
  local failures = {}
  local adapter = net_signals.new({ network = network, config = plan(), logger = quiet, on_failure = function(signal_id, aspect, reason) failures[#failures + 1] = { signal_id, aspect, reason } end })
  adapter.install(network)
  return adapter, network, failures
end

return {
  test_a_command_goes_to_the_node_that_hosts_the_signal_with_the_logical_id = function()
    local a, n = new()
    assert(a.setAspect("S-B", "GREEN") == true)
    assert(a.setAspect("S-D", "RED") == true)
    assert(a.setAspect("SIG-SOLO", "GREEN") == true, "a node without a list hosts the signal of its own id")
    assert(n.sent[1].dst == "SIGN-1" and n.sent[1].payload.cmd == "set_aspect" and n.sent[1].payload.signal_id == "S-B" and n.sent[1].payload.aspect == "GREEN")
    assert(n.sent[2].dst == "SIGN-2" and n.sent[3].dst == "SIG-SOLO")
    assert(n.sent[1].type == "cmd")
  end,

  test_a_signal_no_node_hosts_is_an_error_and_nothing_is_sent = function()
    local a, n = new()
    local ok, err = a.setAspect("S-NOPE", "GREEN")
    assert(ok == false and err:find("no signal node", 1, true), tostring(err))
    assert(#n.sent == 0)
    local ok2 = a.setAspect("SEN-1", "GREEN")
    assert(ok2 == false, "a sensor hosts no signal")
  end,

  test_a_command_the_net_refuses_is_an_error = function()
    local a, n = new()
    n.refuse = true
    local ok, err = a.setAspect("S-A", "GREEN")
    assert(ok == false and err:find("refused", 1, true), tostring(err))
    assert(a.status("S-A") == "FAILED", "a command that was not even sent is a failed command")
    assert(a.failed()[1] == "S-A")
  end,

  test_received_applied_and_physical_effect_are_three_things = function()
    local a, n = new()
    a.setAspect("S-A", "GREEN")
    assert(a.status("S-A") == "PENDING", "sent is not applied")
    -- the delivery ack without applied
    n.on_ack({ ack_id = "m1" }, n.sent[1])
    assert(a.status("S-A") == "PENDING", "delivered is not applied")
    n.on_ack({ ack_id = "m1", applied = true }, n.sent[1])
    local status, detail = a.status("S-A")
    assert(status == "APPLIED" and detail.aspect == "GREEN")
    assert(a.getState("S-A") == true)
    local _, state = a.getState("S-A")
    assert(state == "UNKNOWN", "applied is what the node did; what the signal shows is not read back")
  end,

  test_a_refusal_of_the_node_is_a_failure_that_the_dispatcher_hears_of = function()
    local a, n, failures = new()
    a.setAspect("S-A", "GREEN")
    n.on_err({ ref_id = "m1", error = "signal S-A is not bound on this node" }, n.sent[1], "SIGN-1")
    local status, detail = a.status("S-A")
    assert(status == "FAILED" and detail.reason:find("not bound", 1, true))
    assert(#failures == 1 and failures[1][1] == "S-A" and failures[1][2] == "GREEN")
  end,

  test_a_command_that_ran_out_of_retries_is_a_failure_and_the_old_handler_still_runs = function()
    local network = fake_network()
    local dropped = {}
    network.on_drop = function(msg) dropped[#dropped + 1] = msg.id end
    local failures = {}
    local a = net_signals.new({ network = network, config = plan(), logger = quiet, on_failure = function(id) failures[#failures + 1] = id end })
    a.install(network)
    a.setAspect("S-D", "RED")
    network.on_drop(network.sent[1])
    assert(a.status("S-D") == "FAILED" and failures[1] == "S-D")
    assert(dropped[1] == "m1", "what was installed before still hears of the drop")
  end,

  test_a_newer_command_for_a_signal_replaces_the_state_of_the_older_one = function()
    local a, n, failures = new()
    a.setAspect("S-A", "GREEN")
    a.setAspect("S-A", "RED")
    -- the late failure of the first command says nothing about the signal as it is commanded now
    n.on_err({ ref_id = "m1", error = "late" }, n.sent[1], "SIGN-1")
    assert(a.status("S-A") == "PENDING" and #failures == 0)
    n.on_ack({ ack_id = "m2", applied = true }, n.sent[2])
    local status, detail = a.status("S-A")
    assert(status == "APPLIED" and detail.aspect == "RED")
  end,

  test_the_handlers_that_were_installed_before_still_hear_acks_and_errs = function()
    local network = fake_network()
    local acks, errs = {}, {}
    network.on_ack = function(payload) acks[#acks + 1] = payload.ack_id end
    network.on_err = function(payload) errs[#errs + 1] = payload.ref_id end
    local a = net_signals.new({ network = network, config = plan(), logger = quiet })
    a.install(network)
    a.setAspect("S-A", "GREEN"); a.setAspect("S-D", "RED")
    network.on_ack({ ack_id = "m1", applied = true }, network.sent[1])
    network.on_err({ ref_id = "m2", error = "e" }, network.sent[2], "SIGN-2")
    assert(acks[1] == "m1" and errs[1] == "m2")
  end,

  test_foreign_acks_are_ignored = function()
    local a, n = new()
    n.on_ack({ ack_id = "x9", applied = true }, { id = "x9", type = "cmd", dst = "SIGN-1", payload = { cmd = "ota_begin" } })
    n.on_ack({ ack_id = "x10" }, nil)
    n.on_err({ ref_id = "x11", error = "e" }, nil, "SIGN-1")
    assert(a.status("S-A") == "NONE")
  end,

  test_the_dispatcher_takes_a_block_out_of_service_when_its_signal_failed = function()
    local cfg = plan()
    local aspects = {}
    local d = dispatcher.new(cfg, { signals = { setAspect = function(id, a) aspects[id] = a; return true end }, switches = { setPosition = function() return true end } })
    local changed = d.signal_failed("S-B", "node refused")
    assert(#changed == 1 and changed[1] == "B1")
    assert(d.get_block("B1").state == "FAULT" and d.get_block("B1").fault_cause.kind == "signal")
    assert(d.get_block("B2").state == "FREE")
    local ok, err = d.reserve_route("T1", "R1")
    assert(not ok, "a route over a block with a failed signal is not given")
    assert(#d.signal_failed("S-NONE", "x") == 0)
  end,

  test_the_failed_list_names_every_signal_that_could_not_be_set = function()
    local a, n = new()
    a.setAspect("S-A", "GREEN"); a.setAspect("S-D", "RED"); a.setAspect("S-C", "RED")
    n.on_err({ ref_id = "m1", error = "e" }, n.sent[1], "SIGN-1")
    n.on_ack({ ack_id = "m2", applied = true }, n.sent[2])
    local failed = a.failed()
    assert(#failed == 1 and failed[1] == "S-A")
  end,

  test_the_config_check_knows_signal_nodes_and_the_transport = function()
    local validate = require("src.shared.validate")
    local function base()
      local c = plan()
      c.v = 1; c.channel = 1; c.master_id = "M"
      table.insert(c.nodes, { id = "M", role = "master" })
      c.nodes[4] = { id = "SEN-1", role = "sensor" }
      return c
    end
    local function errors_of(c) local _, errs = validate.validate_config(c); return table.concat(errs or {}, "\n") end
    local text = errors_of(base())
    assert(not text:find("signal", 1, true), text)
    local bad = base(); bad.signal_transport = "radio"
    assert(errors_of(bad):find("signal_transport", 1, true))
    local dup = base(); dup.nodes[2].signals = { "S-D", "S-A" }
    assert(errors_of(dup):find("already hosted", 1, true))
    local wrong = base(); wrong.nodes[4].signals = { "X" }
    assert(errors_of(wrong):find("only a signal node", 1, true))
    local empty = base(); empty.nodes[1].signals = {}
    assert(errors_of(empty):find("non-empty list", 1, true))
    local unhosted = base(); unhosted.blocks[1].entry_signal = "S-NOWHERE"
    assert(errors_of(unhosted):find("hosted by no signal node", 1, true))
    local local_ok = base(); local_ok.signal_transport = "local"; local_ok.blocks[1].entry_signal = "S-NOWHERE"
    assert(not errors_of(local_ok):find("hosted by no signal node", 1, true), "with local transport the master's own peripherals are used")
  end
}
