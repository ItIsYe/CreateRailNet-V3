--[[
Purpose: Two masters, the arbiter and an actuator node with real nets, stores and files on a simulated link: the election carried by messages, the gate that keeps a non-leader from commanding,
  the epoch check at the actuator, nodes that report to both masters, and the topology a node learns from its master (Gesamtkonzept Kap. 5.1, E-01, E-10, F-07).
Public API: returns table of tests.
]]

pcall(dofile, "tests/harness/cc_bootstrap.lua")

local net = require("src.shared.net")
local time = require("src.shared.time")
local ha_module = require("src.shared.ha")
local election_store = require("src.shared.election_store")
local common_node = require("src.nodes.common_node")
local arbiter_node = require("src.nodes.arbiter_node")
local memfs = require("tests.harness.memfs")
local prng = require("tests.harness.prng")
local lossy_link = require("tests.harness.lossy_link")

local A, B, ARB, N1 = "MASTER-A", "MASTER-B", "ARBITER-1", "SIG-1"

local quiet = { info = function() end, warn = function() end, error = function() end, debug = function() end }

local function plan_config(extra)
  local cfg = { channel = 1, master_id = A, masters = { A, B }, arbiter = ARB }
  for k, v in pairs(extra or {}) do cfg[k] = v end
  return cfg
end

local function build(opts)
  opts = opts or {}
  local rng = prng.new(opts.seed or 3)
  local link = lossy_link.new(rng, { drop = opts.drop, delay_max_ms = opts.delay_max_ms })
  local w = { link = link, masters = {}, ran = {}, heard = { [A] = {}, [B] = {} }, files = {} }
  local function fs_of(name) w.files[name] = w.files[name] or memfs.new(); return w.files[name] end
  w.fs_of = fs_of

  local function master(id)
    local m = { id = id }
    m.net = net.new(link.modem(id), 1, id, quiet, time)
    m.ha = ha_module.new({ id = id, config = plan_config(), network = m.net, now_ms = time.now_ms, logger = quiet, store = election_store.new(nil, { fs = fs_of(id .. ":election") }) })
    m.net.gate, m.net.stamp = m.ha.gate, m.ha.stamp
    m.alive = true
    link.set_receiver(id, function(msg)
      if not m.alive then return end
      local status = m.net.receive(msg)
      if status == "ok" and msg.type == "cmd" and msg.payload.cmd == "election" then m.ha.handle(msg) end
      if status == "ok" and (msg.type == "heartbeat" or msg.type == "event") then w.heard[id][#w.heard[id] + 1] = msg end
    end)
    w.masters[id] = m
    return m
  end
  master(A); master(B)

  w.arbiter = arbiter_node.new_runtime({
    id = ARB, config = plan_config(), logger = quiet, modem = link.modem(ARB),
    election_path = nil, election_fs = fs_of(ARB .. ":election"), fence_fs = fs_of(ARB .. ":fence"), topology_fs = fs_of(ARB .. ":topology")
  })
  link.set_receiver(ARB, function(msg) w.arbiter.handle_event({ "modem_message", "x", 1, 1, msg }) end)

  local function node(config, id)
    local n = common_node.new({
      id = id or N1, role = "signal", config = config, modem = link.modem(id or N1), logger = quiet, ledger = false,
      fence_fs = fs_of((id or N1) .. ":fence"), topology_fs = fs_of((id or N1) .. ":topology"),
      handlers = { on_cmd = function(payload) w.ran[#w.ran + 1] = payload; return true end }
    })
    link.set_receiver(id or N1, function(msg) n.handle_event({ "modem_message", "x", 1, 1, msg }) end)
    return n
  end
  w.node = node(plan_config())

  function w.step(ms, count)
    for _ = 1, count or 1 do
      link.advance(ms)
      for _, m in pairs(w.masters) do if m.alive then m.ha.tick(); m.net.tick() end end
      if w.arbiter.ha then w.arbiter.ha.tick() end
      w.arbiter.net.tick()
      w.node.net.tick()
    end
  end
  function w.run(ms) w.step(50, math.ceil(ms / 50)) end
  function w.leader()
    local out
    for id, m in pairs(w.masters) do if m.alive and m.ha.is_leader() then out = out and (out .. "," .. id) or id end end
    return out
  end
  w.make_node = node
  return w
end

return {
  test_the_election_runs_over_real_messages_and_the_arbiter_votes = function()
    local w = build()
    w.run(20000)
    assert(w.leader() == A, "got " .. tostring(w.leader()))
    assert(w.arbiter.ha and w.arbiter.ha.term() == w.masters[A].ha.term())
    w.link.close()
  end,

  test_only_the_leader_may_command_a_node_and_its_commands_carry_the_epoch = function()
    local w = build()
    w.run(20000)
    assert(w.masters[A].net.send_reliable("cmd", N1, { cmd = "set_aspect", aspect = "GREEN" }))
    local msg, why = w.masters[B].net.send_reliable("cmd", N1, { cmd = "set_aspect", aspect = "GREEN" })
    assert(msg == nil and why == "not the active leader", "the standby must not command")
    w.run(1000)
    assert(#w.ran == 1 and w.ran[1].election_epoch == w.masters[A].ha.term() and w.ran[1].election_leader == A)
    assert(type(w.ran[1].election_proof) == "table" and #w.ran[1].election_proof >= 1)
    -- election messages and pairing answers are free for everybody
    assert(w.masters[B].net.send("cmd", N1, { cmd = "pair_state", state = "known" }))
    assert(w.masters[B].net.send("cmd", A, { cmd = "anything" }), "commands to the other voters are not gated")
    w.link.close()
  end,

  -- E-10: the old leader sends a command: the actuator refuses it
  test_e10_a_command_of_an_old_epoch_is_refused_at_the_actuator = function()
    local w = build()
    w.run(20000)
    local old_term = w.masters[A].ha.term()
    w.masters[A].alive = false
    w.run(30000)
    assert(w.leader() == B)
    local new_term = w.masters[B].ha.term()
    assert(new_term > old_term)
    assert(w.masters[B].net.send_reliable("cmd", N1, { cmd = "set_aspect", aspect = "RED" }))
    w.run(1000)
    assert(#w.ran == 1 and w.ran[1].election_epoch == new_term)
    -- the old master wakes up convinced and sends with its old epoch (the gate is bypassed on purpose: the actuator is the second line)
    local count = #w.ran
    w.node.handle_message({ v = 1, id = "stale.1", src = A, dst = N1, type = "cmd", ts = 0, payload = { cmd = "set_aspect", aspect = "GREEN", election_epoch = old_term, election_leader = A } })
    assert(#w.ran == count, "the stale leader's command must not run")
    w.node.handle_message({ v = 1, id = "stale.2", src = A, dst = N1, type = "cmd", ts = 0, payload = { cmd = "set_aspect", aspect = "GREEN" } })
    assert(#w.ran == count, "and neither does a command without an epoch")
    w.link.close()
  end,

  test_the_epoch_is_remembered_across_a_restart_of_the_actuator = function()
    local w = build()
    w.run(20000)
    w.masters[A].net.send_reliable("cmd", N1, { cmd = "set_aspect" })
    w.run(1000)
    local term = w.masters[A].ha.term()
    assert(w.node.fence.epoch() == term)
    local reborn = w.make_node(plan_config())
    assert(reborn.fence.epoch() == term, "read from the file")
    local count = #w.ran
    reborn.handle_message({ v = 1, id = "replay.1", src = A, dst = N1, type = "cmd", ts = 0, payload = { cmd = "set_aspect", election_epoch = term - 1, election_leader = A } })
    assert(#w.ran == count)
    w.link.close()
  end,

  test_a_plan_with_one_master_takes_commands_without_an_epoch = function()
    local w = build()
    local single = w.make_node({ channel = 1, master_id = A }, "SIG-9")
    single.handle_message({ v = 1, id = "c1", src = A, dst = "SIG-9", type = "cmd", ts = 0, payload = { cmd = "set_aspect" } })
    assert(#w.ran == 1)
    w.link.close()
  end,

  test_a_command_from_a_computer_that_is_not_a_master_is_refused_even_with_an_epoch = function()
    local w = build()
    w.node.handle_message({ v = 1, id = "x1", src = "EVIL-1", dst = N1, type = "cmd", ts = 0, payload = { cmd = "set_aspect", election_epoch = 99, election_leader = "EVIL-1" } })
    assert(#w.ran == 0)
    w.link.close()
  end,

  test_a_node_reports_to_both_masters = function()
    local w = build()
    w.run(20000)
    w.node.net.send_reliable("event", A, { type = "sensor", sensor_id = N1, action = "enter" })
    w.node.net.heartbeat(A, { role = "signal" })
    w.run(1000)
    local function count(list, kind) local n = 0 for _, m in ipairs(list) do if m.payload.type == kind or (kind == "hb" and m.type == "heartbeat") then n = n + 1 end end return n end
    assert(count(w.heard[A], "sensor") == 1 and count(w.heard[B], "sensor") == 1, "both masters got the event")
    assert(count(w.heard[A], "hb") == 1 and count(w.heard[B], "hb") == 1, "and the heartbeat")
    w.link.close()
  end,

  test_a_command_queued_by_a_leader_is_dropped_when_it_stops_being_leader = function()
    local w = build()
    w.run(20000)
    assert(w.leader() == A)
    -- the node is out of reach and A is cut off from the other voters: it queues a command and then loses its majority
    w.link.set_receiver(N1, function() end)
    local queued = w.masters[A].net.send_reliable("cmd", N1, { cmd = "set_aspect", aspect = "GREEN" })
    assert(queued and next(w.masters[A].net.pending))
    local dropped = 0
    w.masters[A].net.on_drop = function() dropped = dropped + 1 end
    w.masters[B].alive = false
    w.link.set_receiver(ARB, function() end)
    w.run(12000)
    assert(not w.masters[A].ha.is_leader())
    assert(next(w.masters[A].net.pending) == nil, "no retry of a command after the leadership is gone")
    assert(dropped == 0, "dropped quietly, not reported as a lost node")
    w.link.close()
  end,

  test_a_node_with_a_short_plan_learns_the_masters_from_its_master_and_remembers_them = function()
    local w = build()
    local short = w.make_node({ channel = 1, master_id = A }, "SIG-5")
    assert(short.config.masters == nil)
    short.handle_message({ v = 1, id = "ps1", src = A, dst = "SIG-5", type = "cmd", ts = 0, payload = { cmd = "pair_state", state = "known", masters = { A, B }, arbiter = ARB } })
    assert(short.config.masters[2] == B and short.config.arbiter == ARB)
    local sent = {}
    short.net.send = function(kind, dst) sent[#sent + 1] = dst end
    -- from now on it mirrors (the net itself does it; checked through the pending list of a reliable event)
    short.net.send_reliable("event", A, { type = "sensor" })
    local destinations = {}
    for _, entry in pairs(short.net.pending) do destinations[entry.msg.dst] = true end
    assert(destinations[A] and destinations[B], "events go to both masters now")
    -- a restart: the file brings it back
    local again = w.make_node({ channel = 1, master_id = A }, "SIG-5")
    assert(again.config.masters and again.config.masters[2] == B and again.config.arbiter == ARB)
    assert(again.fence ~= nil)
    w.link.close()
  end,

  test_a_topology_that_does_not_fit_is_not_taken = function()
    local w = build()
    local short = w.make_node({ channel = 1, master_id = A }, "SIG-6")
    for _, masters in ipairs({ { B, "MASTER-C" }, { A }, { A, A }, "x", { A, string.rep("x", 100) } }) do
      short.handle_message({ v = 1, id = "ps" .. tostring(masters), src = A, dst = "SIG-6", type = "cmd", ts = 0, payload = { cmd = "pair_state", state = "known", masters = masters, arbiter = ARB } })
      assert(short.config.masters == nil, "refused: " .. tostring(masters))
    end
    w.link.close()
  end,

  test_the_arbiter_starts_voting_as_soon_as_it_learns_the_masters = function()
    local w = build()
    local lone = arbiter_node.new_runtime({
      id = "ARB-2", config = { channel = 1, master_id = A }, logger = quiet, modem = w.link.modem("ARB-2"),
      election_fs = w.fs_of("arb2:election"), fence_fs = w.fs_of("arb2:fence"), topology_fs = w.fs_of("arb2:topology")
    })
    assert(lone.ha == nil)
    lone.handle_message({ v = 1, id = "ps1", src = A, dst = "ARB-2", type = "cmd", ts = 0, payload = { cmd = "pair_state", state = "known", masters = { A, B }, arbiter = "ARB-2" } })
    assert(lone.ha ~= nil and lone.ha.status().role == "follower")
    w.link.close()
  end,

  test_an_unreadable_election_file_keeps_a_master_out_of_the_election_and_closed = function()
    local fs = memfs.new()
    fs.set("state/election.json", "garbage")
    fs.set("state/election.json.prev", "garbage")
    local link = lossy_link.new(prng.new(1), {})
    local network = net.new(link.modem(A), 1, A, quiet, time)
    local h = ha_module.new({ id = A, config = plan_config(), network = network, now_ms = time.now_ms, logger = quiet, store = election_store.new(nil, { fs = fs }) })
    h.tick()
    assert(h.is_leader() == false and h.status().disabled)
    local ok, why = h.gate("cmd", N1, { cmd = "set_aspect" })
    assert(ok == false and why == "election state unreadable")
    assert(h.gate("cmd", N1, { cmd = "pair_state" }) == true)
    link.close()
  end,

  test_after_learning_the_masters_a_command_without_an_epoch_is_refused = function()
    local w = build()
    local short = w.make_node({ channel = 1, master_id = A }, "SIG-7")
    short.handle_message({ v = 1, id = "c0", src = A, dst = "SIG-7", type = "cmd", ts = 0, payload = { cmd = "set_aspect" } })
    assert(#w.ran == 1, "before it knows about two masters a plain command is fine")
    short.handle_message({ v = 1, id = "ps", src = A, dst = "SIG-7", type = "cmd", ts = 0, payload = { cmd = "pair_state", state = "known", masters = { A, B }, arbiter = ARB } })
    short.handle_message({ v = 1, id = "c1", src = A, dst = "SIG-7", type = "cmd", ts = 0, payload = { cmd = "set_aspect" } })
    assert(#w.ran == 1, "now the epoch is required")
    short.handle_message({ v = 1, id = "c2", src = A, dst = "SIG-7", type = "cmd", ts = 0, payload = { cmd = "set_aspect", election_epoch = 1, election_leader = A } })
    assert(#w.ran == 2)
    w.link.close()
  end,

  test_the_topology_is_believed_only_from_an_authenticated_message_when_authentication_is_on = function()
    local w = build()
    local verdict = "open"
    local fake_auth = {
      mode = "enforce", session = "s", keyring = {},
      sign = function() return false end, verify = function() return verdict end,
      challenge_nonce_for = function() end, counter_challenge = function() end, resign = function() end, accept_challenge = function() return false end
    }
    local n = common_node.new({
      id = "SIG-8", role = "signal", config = { channel = 1, master_id = A }, modem = w.link.modem("SIG-8"), logger = quiet, ledger = false,
      auth = fake_auth, fence_fs = w.fs_of("sig8:fence"), topology_fs = w.fs_of("sig8:topology")
    })
    n.handle_message({ v = 1, id = "ps1", src = A, dst = "SIG-8", type = "cmd", ts = 0, payload = { cmd = "pair_state", state = "known", masters = { A, B }, arbiter = ARB } })
    assert(n.config.masters == nil, "an unsigned pair_state may announce a state but not change who the masters are")
    verdict = "ok"
    n.handle_message({ v = 1, id = "ps2", src = A, dst = "SIG-8", type = "cmd", ts = 0, payload = { cmd = "pair_state", state = "known", masters = { A, B }, arbiter = ARB } })
    assert(n.config.masters and n.config.masters[2] == B)
    w.link.close()
  end,
}
