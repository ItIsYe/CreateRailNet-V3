--[[
Purpose: The epoch check at an actuator, the stored topology of masters and arbiter, and the gate / stamp / mirror hooks of the net (Gesamtkonzept Kap. 5.1, E-10, F-07).
Public API: returns table of tests.
]]

pcall(dofile, "tests/harness/cc_bootstrap.lua")

local fence = require("src.shared.fence")
local ha_topology = require("src.shared.ha_topology")
local net = require("src.shared.net")
local memfs = require("tests.harness.memfs")
local mock_modem = require("tests.harness.mock_modem")

local function clock() return { now_ms = function() return 0 end } end

return {
  test_a_higher_epoch_is_stored_an_equal_one_passes_and_a_lower_one_is_refused = function()
    local fs = memfs.new()
    local f = fence.new({ masters = { "A", "B" }, required = true, fs = fs })
    assert(f.check({ election_epoch = 3, election_leader = "A" }, "A") and f.epoch() == 3)
    assert(f.check({ election_epoch = 3, election_leader = "A" }, "A"))
    assert(f.check({ election_epoch = 5, election_leader = "B" }, "B") and f.epoch() == 5)
    local ok, why = f.check({ election_epoch = 4, election_leader = "A" }, "A")
    assert(ok == false and why == "old_epoch")
    assert(fence.new({ masters = { "A", "B" }, fs = fs }).epoch() == 5, "the epoch is on the disk")
  end,

  test_a_command_without_an_epoch_is_refused_only_when_two_masters_are_configured = function()
    local f = fence.new({ masters = { "A", "B" }, required = true, fs = memfs.new() })
    local ok, why = f.check({}, "A")
    assert(ok == false and why == "no_epoch")
    assert(fence.new({ masters = { "A" }, required = false, fs = memfs.new() }).check({}, "A"))
  end,

  test_the_leader_named_in_the_command_must_be_its_sender = function()
    local f = fence.new({ masters = { "A", "B" }, required = true, fs = memfs.new() })
    local ok, why = f.check({ election_epoch = 5, election_leader = "B" }, "A")
    assert(ok == false and why == "leader_mismatch")
    assert(f.epoch() == 0, "a refused command does not move the epoch")
  end,

  test_only_a_listed_master_can_move_the_epoch = function()
    local f = fence.new({ masters = { "A", "B" }, required = true, fs = memfs.new() })
    local ok, why = f.check({ election_epoch = 99 }, "EVIL-1")
    assert(ok == false and why == "leader_mismatch" and f.epoch() == 0)
  end,

  test_an_epoch_that_is_not_a_whole_positive_number_is_refused = function()
    local f = fence.new({ masters = { "A" }, required = true, fs = memfs.new() })
    for _, bad in ipairs({ "x", 0, -1, 1.5, true }) do
      local ok, why = f.check({ election_epoch = bad }, "A")
      assert(ok == false and why == "bad_epoch", tostring(bad))
    end
  end,

  test_an_epoch_that_cannot_be_stored_is_not_accepted = function()
    local fs = memfs.new()
    fs.capacity = 0
    local f = fence.new({ masters = { "A" }, required = true, fs = fs })
    local ran, ok, why = pcall(f.check, { election_epoch = 3 }, "A")
    assert(not ran or ok == false, "a command whose epoch could not be written down does not run")
    assert(f.epoch() == 0, "what was not written down is not remembered")
  end,

  test_a_new_topology_changes_the_rules_later = function()
    local f = fence.new({ fs = memfs.new() })
    assert(f.check({}, "A"), "one master: no epoch needed")
    f.set_topology({ "A", "B" }, true)
    local ok, why = f.check({}, "A")
    assert(ok == false and why == "no_epoch")
    assert(f.check({ election_epoch = 1 }, "B"))
    ok, why = f.check({ election_epoch = 2 }, "C")
    assert(ok == false and why == "leader_mismatch")
  end,

  test_a_sane_topology_has_two_or_three_distinct_masters_and_an_arbiter_that_is_none_of_them = function()
    assert(ha_topology.sane({ "A", "B" }, "ARB", "A"))
    assert(ha_topology.sane({ "A", "B" }, nil, "B"))
    for _, case in ipairs({
      { { "A" }, "ARB", "A" }, { { "A", "A" }, "ARB", "A" }, { { "A", "B", "C", "D" }, "ARB", "A" }, { "x", "ARB", "A" },
      { { "A", "B" }, "ARB", "Z" }, { { "A", "B" }, "A", "A" }, { { "A", "B" }, string.rep("x", 100), "A" }, { { "A", string.rep("y", 100) }, "ARB", "A" }, { { "A", "" }, "ARB", "A" },
    }) do
      assert(not ha_topology.sane(case[1], case[2], case[3]), "accepted: " .. tostring(case[1]) .. " " .. tostring(case[2]))
    end
  end,

  test_the_topology_file_roundtrips_and_a_broken_one_is_ignored = function()
    local fs = memfs.new()
    assert(ha_topology.save({ "A", "B" }, "ARB", nil, { fs = fs }))
    local loaded = ha_topology.load(nil, { fs = fs })
    assert(loaded.masters[2] == "B" and loaded.arbiter == "ARB")
    fs.files[ha_topology.DEFAULT_PATH] = "garbage"
    fs.files[ha_topology.DEFAULT_PATH .. ".prev"] = nil
    assert(ha_topology.load(nil, { fs = fs }) == nil)
    fs.files[ha_topology.DEFAULT_PATH] = '{"masters":["A"],"arbiter":"X"}'
    assert(ha_topology.load(nil, { fs = fs }) == nil, "a list that is not sane is not believed")
  end,

  test_the_gate_stops_a_message_before_it_is_sent_and_a_retry_before_it_is_resent = function()
    local sent = {}
    local modem = { send = function(_, _, _, msg) sent[#sent + 1] = msg; return true end, broadcast = function() return true end }
    local open = true
    local n = net.new(modem, 1, "M", nil, clock(), { gate = function(kind) if kind == "cmd" then return open, "closed" end return true end })
    assert(n.send("cmd", "N", { cmd = "x" }))
    open = false
    local msg, why = n.send("cmd", "N", { cmd = "y" })
    assert(msg == nil and why == "closed" and #sent == 1)
    assert(n.send("event", "N", { type = "e" }), "other message types pass")
    open = true
    assert(n.send_reliable("cmd", "N", { cmd = "z" }) and next(n.pending))
    open = false
    local before = #sent
    local now = 0
    n.dedup_ttl = 1
    local dropped = 0
    n.on_drop = function() dropped = dropped + 1 end
    clock().now_ms = function() return now end
    -- the retry time comes: the pending command is dropped without a resend and without on_drop
    local timed = net.new(modem, 1, "M", nil, { now_ms = function() return now end }, { gate = function(kind) return kind ~= "cmd", "closed" end })
    timed.on_drop = function() dropped = dropped + 1 end
    open = true
    local timed_open = true
    timed.gate = function() return timed_open end
    assert(timed.send_reliable("cmd", "N", { cmd = "z" }))
    timed_open = false
    now = 1000
    timed.tick()
    assert(next(timed.pending) == nil and dropped == 0 and #sent == before + 1, "dropped quietly")
  end,

  test_the_stamp_is_applied_to_the_payload_before_it_is_signed_and_sent = function()
    local sent = {}
    local modem = { send = function(_, _, _, msg) sent[#sent + 1] = msg; return true end, broadcast = function() return true end }
    local n = net.new(modem, 1, "M", nil, clock(), { stamp = function(kind, dst, payload) payload.stamped_for = dst end })
    n.send("cmd", "N1", { cmd = "x" })
    assert(sent[1].payload.stamped_for == "N1")
  end,

  test_mirrors_send_a_message_of_its_own_to_every_other_id_with_its_own_payload = function()
    local sent = {}
    local modem = { send = function(_, _, dst, msg) sent[#sent + 1] = msg; return true end, broadcast = function() return true end }
    local n = net.new(modem, 1, "N1", nil, clock(), {
      mirrors = { ["MASTER-A"] = { "MASTER-B" } }, stamp = function(kind, dst, payload) payload.stamped_for = dst end
    })
    n.send("heartbeat", "MASTER-A", { role = "signal" })
    n.send("event", "MASTER-A", { type = "sensor" })
    n.send("cmd", "MASTER-A", { cmd = "not mirrored" })
    n.send("event", "SOMEONE-ELSE", { type = "sensor" })
    assert(#sent == 6, "heartbeat and event twice, the cmd and the other event once: " .. #sent)
    local seen = {}
    for _, msg in ipairs(sent) do
      seen[#seen + 1] = msg.dst .. ":" .. tostring(msg.payload.stamped_for)
    end
    for _, entry in ipairs(seen) do
      local dst, stamped = entry:match("^(.-):(.*)$")
      assert(dst == stamped, "each message carries the stamp of its own destination: " .. entry)
    end
    assert(sent[1].id ~= sent[2].id, "two messages, two ids")
    -- reliable: both are tracked
    local reliable = net.new(modem, 1, "N1", nil, clock(), { mirrors = { ["MASTER-A"] = { "MASTER-B" } } })
    reliable.send_reliable("event", "MASTER-A", { type = "sensor" })
    local count = 0
    for _ in pairs(reliable.pending) do count = count + 1 end
    assert(count == 2)
  end
}
