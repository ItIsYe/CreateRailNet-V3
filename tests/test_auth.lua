--[[
Purpose: Authenticated messages between computers: handshake, forgery, tampering, replay, restarts, revoked keys, load limit (Gesamtkonzept Kap. 12, tests F-01 .. F-10).
Public API: returns table of tests.
Notes: real nets with real keys on a simulated link (tests/harness/auth_world.lua). Where a test stands for a test case of the Gesamtkonzept the name says which.
]]

pcall(dofile, "tests/harness/cc_bootstrap.lua")

local auth_world = require("tests.harness.auth_world")
local sha256 = require("src.shared.sha256")

local function with_world(opts, fn)
  local w = auth_world.new(opts)
  local ok, err = pcall(fn, w)
  w.close()
  if not ok then error(err, 0) end
end

local function received(entity, kind)
  local list = {}
  for _, item in ipairs(entity.inbox) do
    if item.status == "ok" and (kind == nil or item.msg.payload.type == kind or item.msg.payload.cmd == kind) then list[#list + 1] = item.msg end
  end
  return list
end

local function find_captured(w, predicate)
  for i = #w.captured, 1, -1 do if predicate(w.captured[i]) then return w.captured[i] end end
end

local function copy(msg)
  local out = {}
  for k, v in pairs(msg) do out[k] = v end
  if type(msg.payload) == "table" then
    out.payload = {}
    for k, v in pairs(msg.payload) do out.payload[k] = v end
  end
  return out
end

return {
  test_the_first_message_is_carried_out_once_after_a_handshake_and_the_ack_is_not_lost = function()
    with_world({}, function(w)
      local m, n = w.master("M"), w.node("N1")
      local acked = 0
      n.net.on_ack = function(payload) if payload.applied then acked = acked + 1 end end
      n.net.send_reliable("event", "M", { type = "sensor", sensor_id = "N1" })
      w.settle(400)
      assert(#received(m, "sensor") == 1, "the event was carried out " .. #received(m, "sensor") .. " times")
      assert(acked == 1, "the sender saw " .. acked .. " applied acks")
      assert(next(n.net.pending) == nil, "the message is still pending")
      -- after the handshake there is no more challenge traffic
      local before = #w.captured
      n.net.send_reliable("event", "M", { type = "sensor", sensor_id = "N1" })
      w.settle(400)
      assert(#w.captured - before == 2, "a message and its ack, got " .. (#w.captured - before))
      assert(m.inbox[#m.inbox].msg.authenticated == true)
    end)
  end,

  test_master_commands_reach_a_node_the_same_way = function()
    with_world({}, function(w)
      local m, n = w.master("M"), w.node("N1")
      local done = 0
      m.net.on_ack = function(payload) if payload.applied then done = done + 1 end end
      for i = 1, 5 do m.net.send_reliable("cmd", "N1", { cmd = "set_aspect", n = i }) end
      w.settle(600)
      assert(#received(n, "set_aspect") == 5)
      assert(done == 5, "applied acks: " .. done)
    end)
  end,

  -- F-01: an unknown computer reports in: without being taken in it has no rights
  test_f01_a_stranger_cannot_send_anything_but_the_open_messages = function()
    with_world({}, function(w)
      local m = w.master("M")
      local x = w.stranger("X-1")
      x.net.send("event", "M", { type = "sensor", sensor_id = "X-1", occupied = true })
      x.net.send("event", "M", { type = "manual_control", action = "release_operation" })
      x.net.send("register", "M", { role = "signal" })
      x.net.send("heartbeat", "M", { role = "signal" })
      x.net.send("event", "M", { type = "pair_announce", role = "signal" })
      w.settle(200)
      assert(#received(m) == 1 and received(m)[1].payload.type == "pair_announce", "only the announcement may pass, got " .. #received(m))
      assert(received(m)[1].authenticated == false, "an unsigned message is never marked authenticated")
      assert(w.statuses(m).auth_failed == 4, "four refused, got " .. tostring(w.statuses(m).auth_failed))
    end)
  end,

  test_a_sender_cannot_claim_to_be_authenticated_in_its_own_message = function()
    with_world({}, function(w)
      local m = w.master("M")
      local x = w.stranger("X-1")
      local msg = x.net.send("event", "M", { type = "pair_announce", role = "signal" })
      local forged = copy(msg)
      forged.authenticated = true
      forged.id = "forged.1"
      m.net.receive(forged)
      assert(forged.authenticated == false, "the field of the sender must be overwritten")
    end)
  end,

  -- F-02: a computer uses a name that belongs to another
  test_f02_a_foreign_node_id_fails_authentication = function()
    with_world({}, function(w)
      local m = w.master("M")
      w.node("SIG-1")
      local liar = w.stranger("SIG-1", sha256.hex("a key the liar made up"))
      -- the liar even has the right name now: the real SIG-1 is not on the link
      liar.net.send_reliable("event", "M", { type = "sensor", sensor_id = "SIG-1", occupied = true })
      w.settle(2000)
      assert(#received(m) == 0)
      assert((w.statuses(m).auth_failed or 0) >= 1)
    end)
  end,

  test_a_node_with_a_valid_key_cannot_speak_as_another_node = function()
    with_world({}, function(w)
      local m = w.master("M")
      w.node("SIG-1")
      local other = w.node("SIG-2")
      -- SIG-2 signs with its own key but writes SIG-1 as the sender
      other.net.send("event", "M", { type = "sensor", sensor_id = "SIG-1" })
      local msg = w.captured[#w.captured]
      local forged = copy(msg)
      forged.src = "SIG-1"
      m.net.receive(forged)
      local status, detail = m.net.receive(forged)
      assert(status == "auth_failed" and detail == "bad_mac", tostring(status) .. "/" .. tostring(detail))
    end)
  end,

  -- F-03: the content of a message is changed on the way
  test_f03_a_changed_message_is_refused = function()
    with_world({}, function(w)
      local m, n = w.master("M"), w.node("N1")
      n.net.send_reliable("event", "M", { type = "sensor", sensor_id = "N1", occupied = false })
      w.settle(300)
      n.net.send("event", "M", { type = "sensor", sensor_id = "N1", occupied = false })
      local original = w.captured[#w.captured]
      local tampered = copy(original)
      tampered.payload.occupied = true
      tampered.id = "tampered.1"
      local status, detail = m.net.receive(tampered)
      assert(status == "auth_failed" and detail == "bad_mac")
      for _, field in ipairs({ "src", "dst", "type", "ts", "sq", "ss", "ke", "pv" }) do
        local variant = copy(original)
        variant.id = "variant." .. field
        if type(variant[field]) == "number" then variant[field] = variant[field] + 1 elseif field == "type" then variant[field] = "cmd" elseif field == "dst" then variant[field] = "M" else variant[field] = variant[field] .. "x" end
        local result = m.net.receive(variant)
        assert(result ~= "ok", "a change of " .. field .. " was accepted")
      end
    end)
  end,

  -- F-04: an old command is repeated
  test_f04_a_recorded_command_is_not_carried_out_again = function()
    with_world({}, function(w)
      local m, n = w.master("M"), w.node("N1")
      local ran = 0
      n.on_ok = function(msg) if msg.payload.cmd == "depart" then ran = ran + 1 end end
      m.net.send_reliable("cmd", "N1", { cmd = "depart", train_id = "T1" })
      w.settle(600)
      assert(ran == 1)
      local recorded = find_captured(w, function(msg) return msg.type == "cmd" and msg.payload.cmd == "depart" end)
      -- within the window and long after the duplicate memory of the net forgot it
      w.step(1000, 60)
      local status = n.net.receive(copy(recorded))
      assert(status == "duplicate", "replay inside the window: " .. tostring(status))
      assert(ran == 1)
      -- outside the window: a replay of an old sequence number is refused outright
      for _ = 1, 300 do m.net.send("cmd", "N1", { cmd = "ping" }) end
      w.settle(300)
      local status2, detail2 = n.net.receive(copy(recorded))
      assert(status2 == "auth_failed" and detail2 == "replay", tostring(status2) .. "/" .. tostring(detail2))
      assert(ran == 1)
    end)
  end,

  test_a_recorded_message_is_not_accepted_by_a_receiver_that_restarted = function()
    with_world({}, function(w)
      local m, n = w.master("M"), w.node("N1")
      local ran = 0
      m.on_ok = function(msg) if msg.payload.type == "sensor" then ran = ran + 1 end end
      n.net.send_reliable("event", "M", { type = "sensor", sensor_id = "N1", occupied = true })
      w.settle(400)
      assert(ran == 1)
      local recorded = find_captured(w, function(msg) return msg.src == "N1" and msg.type == "event" and msg.ch ~= nil end)
      assert(recorded, "the message that was carried out has to be in the record")
      w.restart(m) -- the master rebooted: nothing remembered
      local status = m.net.receive(copy(recorded))
      assert(status == "challenge", "got " .. tostring(status))
      assert(ran == 1)
      -- the node, which is alive, still gets through after the new handshake
      n.net.send_reliable("event", "M", { type = "sensor", sensor_id = "N1", occupied = false })
      w.settle(600)
      assert(#received(m, "sensor") == 1, "the live node must be heard again, got " .. #received(m, "sensor"))
      assert(next(n.net.pending) == nil)
    end)
  end,

  test_a_node_that_restarted_starts_a_new_session_and_its_old_session_stays_dead = function()
    with_world({}, function(w)
      local m, n = w.master("M"), w.node("N1")
      n.net.send_reliable("event", "M", { type = "sensor", sensor_id = "N1", occupied = true })
      w.settle(400)
      local old = find_captured(w, function(msg) return msg.src == "N1" and msg.type == "event" and msg.ch ~= nil end)
      w.restart(n)
      n.net.send_reliable("event", "M", { type = "sensor", sensor_id = "N1", occupied = false })
      w.settle(600)
      assert(#received(m, "sensor") == 2, "the rebooted node must get through, got " .. #received(m, "sensor"))
      local status = m.net.receive(copy(old))
      assert(status ~= "ok" and status ~= "duplicate" or status == "duplicate", "unexpected " .. tostring(status))
      assert(status ~= "ok", "the old session must not be carried out again")
    end)
  end,

  test_messages_inside_the_window_may_arrive_in_any_order_but_only_once = function()
    with_world({}, function(w)
      local m, n = w.master("M"), w.node("N1")
      n.net.send_reliable("event", "M", { type = "sensor", n = 0 })
      w.settle(400)
      -- ten messages, delivered backwards and twice
      local messages = {}
      for i = 1, 10 do messages[#messages + 1] = copy(n.net.send("event", "M", { type = "sensor", n = i })) end
      w.link.in_flight = {}
      local statuses = {}
      for i = 10, 1, -1 do statuses[#statuses + 1] = m.net.receive(copy(messages[i])) end
      for i = 1, 10 do statuses[#statuses + 1] = m.net.receive(copy(messages[i])) end
      for i = 1, 10 do assert(statuses[i] == "ok", "first delivery " .. i .. ": " .. statuses[i]) end
      for i = 11, 20 do assert(statuses[i] == "duplicate", "second delivery: " .. statuses[i]) end
    end)
  end,

  -- F-08: a key that was revoked
  test_f08_a_revoked_key_is_refused_and_a_new_key_works = function()
    with_world({}, function(w)
      local m, n = w.master("M"), w.node("N1")
      n.net.send_reliable("event", "M", { type = "sensor", sensor_id = "N1" })
      w.settle(400)
      assert(#received(m, "sensor") == 1)
      local keystore = require("src.shared.keystore")
      assert(keystore.revoke(w.trust, "N1"))
      n.net.send("event", "M", { type = "sensor", sensor_id = "N1", second = true })
      w.settle(300)
      assert(#received(m, "sensor") == 1, "a revoked key must not be heard")
      -- the operator hands out a new key; the old key file is dead for good, the new one works after a restart of the node
      local record = keystore.issue(w.trust, w.master_key, "N1", "signal", 0)
      assert(record.epoch == 2)
      n.net.send("event", "M", { type = "sensor", sensor_id = "N1", third = true })
      w.settle(300)
      assert(#received(m, "sensor") == 1, "the old key file must stay dead after a new key was issued")
      n.key_record = record
      w.restart(n)
      n.net.send_reliable("event", "M", { type = "sensor", sensor_id = "N1", fourth = true })
      w.settle(600)
      assert(#received(m, "sensor") == 2, "the new key works, got " .. #received(m, "sensor"))
    end)
  end,

  -- F-09: a foreign computer on the peripheral net cannot steer a node with commands
  test_f09_a_forged_master_command_is_not_carried_out = function()
    with_world({}, function(w)
      w.master("M")
      local n = w.node("N1")
      local x = w.stranger("X-1")
      local ran = 0
      n.on_ok = function(msg) if msg.payload.cmd == "set_aspect" then ran = ran + 1 end end
      -- the stranger writes the master's name, with and without a MAC
      for _, src in ipairs({ "M", "X-1" }) do
        local msg = x.net.send("cmd", "N1", { cmd = "set_aspect", aspect = "GREEN" })
        local forged = copy(msg)
        forged.src = src
        forged.id = "forged." .. src
        n.net.receive(forged)
        local unsigned = copy(forged)
        unsigned.at = nil
        unsigned.id = "unsigned." .. src
        n.net.receive(unsigned)
      end
      w.settle(300)
      assert(ran == 0)
    end)
  end,

  -- F-10: a flood of invented messages
  test_f10_a_flood_of_forged_messages_costs_a_bounded_number_of_mac_checks = function()
    with_world({}, function(w)
      local m, n = w.master("M"), w.node("N1")
      n.net.send_reliable("event", "M", { type = "sensor", sensor_id = "N1" })
      w.settle(400)
      local template = w.captured[#w.captured - 1]
      local calls = 0
      local original = sha256.hmac_hex
      sha256.hmac_hex = function(...) calls = calls + 1; return original(...) end
      local refused = 0
      for i = 1, 5000 do
        local msg = copy(template)
        msg.id = "flood." .. i
        msg.at = string.rep("a", 32)
        msg.src = (i % 2 == 0) and "N1" or ("FAKE-" .. i)
        local status = m.net.receive(msg)
        if status == "auth_failed" then refused = refused + 1 end
      end
      sha256.hmac_hex = original
      assert(refused == 5000, "every forged message must be refused, got " .. refused)
      assert(calls <= 450, "mac checks within one second must stay near the budget, got " .. calls)
    end)
  end,

  test_a_node_whose_name_is_abused_gets_through_after_the_flood = function()
    with_world({}, function(w)
      local m, n = w.master("M"), w.node("N1")
      n.net.send_reliable("event", "M", { type = "sensor", sensor_id = "N1" })
      w.settle(400)
      local template = w.captured[#w.captured - 1]
      for i = 1, 300 do
        local msg = copy(template)
        msg.id = "flood." .. i
        msg.at = string.rep("b", 32)
        m.net.receive(msg)
      end
      n.net.send_reliable("event", "M", { type = "sensor", sensor_id = "N1", after = true })
      w.settle(8000)
      assert(#received(m, "sensor") == 2, "the node must be heard again, got " .. #received(m, "sensor"))
    end)
  end,

  test_mode_monitor_counts_failures_but_refuses_nothing = function()
    with_world({ mode = "monitor" }, function(w)
      local m = w.master("M")
      local x = w.stranger("X-1")
      x.net.send("event", "M", { type = "sensor", sensor_id = "X-1" })
      w.settle(200)
      assert(#received(m, "sensor") == 1, "monitor mode only watches")
      assert(m.auth.stats.unsigned == 1)
    end)
  end,

  test_mode_off_adds_nothing_to_the_messages = function()
    with_world({ mode = "off" }, function(w)
      local m, n = w.master("M"), w.node("N1")
      n.net.send_reliable("event", "M", { type = "sensor", sensor_id = "N1" })
      w.settle(300)
      assert(#received(m, "sensor") == 1)
      local sent = find_captured(w, function(msg) return msg.src == "N1" end)
      assert(sent.at == nil and sent.ss == nil and sent.sq == nil and sent.ke == nil and sent.ch == nil)
      assert(m.inbox[1].msg.authenticated == nil)
    end)
  end,

  test_a_node_without_a_key_is_not_heard_and_does_not_crash = function()
    with_world({}, function(w)
      local m = w.master("M")
      local n = w.node("N1", { no_key = true })
      n.net.send_reliable("event", "M", { type = "sensor", sensor_id = "N1" })
      n.net.send("event", "M", { type = "pair_announce", role = "signal" })
      m.net.send("cmd", "N1", { cmd = "set_aspect" })
      w.settle(2000)
      assert(#received(m, "pair_announce") == 1)
      assert(#received(m, "sensor") == 0)
      assert(#received(n) == 0)
    end)
  end,

  test_traffic_in_both_directions_over_a_bad_link_is_carried_out_exactly_once = function()
    for _, seed in ipairs({ 21, 22, 23, 24 }) do
      with_world({ seed = seed, drop = 0.15, duplicate = 0.3, delay_max_ms = 300 }, function(w)
        local m, n = w.master("M"), w.node("N1")
        local ran_node, ran_master = {}, {}
        n.on_ok = function(msg) if msg.payload.cmd == "x" then ran_node[msg.payload.i] = (ran_node[msg.payload.i] or 0) + 1 end end
        m.on_ok = function(msg) if msg.payload.type == "y" then ran_master[msg.payload.i] = (ran_master[msg.payload.i] or 0) + 1 end end
        for i = 1, 40 do
          m.net.send_reliable("cmd", "N1", { cmd = "x", i = i })
          n.net.send_reliable("event", "M", { type = "y", i = i })
          w.step(40, 3)
        end
        w.settle(15000)
        for i = 1, 40 do
          assert(ran_node[i] == 1, "seed " .. seed .. ": command " .. i .. " carried out " .. tostring(ran_node[i]))
          assert(ran_master[i] == 1, "seed " .. seed .. ": event " .. i .. " carried out " .. tostring(ran_master[i]))
        end
      end)
    end
  end,

  test_two_masters_and_a_node_all_talk_to_each_other = function()
    with_world({ masters = { "MA", "MB" } }, function(w)
      local a, b, n = w.master("MA"), w.master("MB"), w.node("N1")
      a.net.send_reliable("cmd", "MB", { cmd = "sync" })
      b.net.send_reliable("cmd", "MA", { cmd = "sync" })
      a.net.send_reliable("cmd", "N1", { cmd = "go" })
      b.net.send_reliable("cmd", "N1", { cmd = "go" })
      n.net.send_reliable("event", "MA", { type = "sensor" })
      n.net.send_reliable("event", "MB", { type = "sensor" })
      w.settle(1000)
      assert(#received(a, "sync") == 1 and #received(b, "sync") == 1)
      assert(#received(n, "go") == 2)
      assert(#received(a, "sensor") == 1 and #received(b, "sensor") == 1)
    end)
  end
}
