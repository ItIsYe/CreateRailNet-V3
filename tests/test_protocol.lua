--[[
Purpose: Protocol envelope: revision field, fail-closed validation, peer revisions, delivered versus applied acknowledgements.
Public API: returns table of tests.
]]

pcall(dofile, "tests/harness/cc_bootstrap.lua")

local net = require("src.shared.net")
local common_node = require("src.nodes.common_node")

local function clock() return { now_ms = function() return 0 end } end

local function endpoint(id)
  local sent = {}
  local modem = { send = function(_, _, _, m) sent[#sent + 1] = m; return true end, broadcast = function(_, _, m) sent[#sent + 1] = m; return true end }
  return net.new(modem, 1, id, nil, clock()), sent
end

local function msg(overrides)
  local m = { v = 1, id = "x.1", src = "A", dst = "B", type = "event", payload = {} }
  for k, v in pairs(overrides or {}) do m[k] = v end
  return m
end

return {
  test_sent_messages_carry_major_and_revision = function()
    local a, sent = endpoint("A")
    a.send("event", "B", {})
    assert(sent[1].v == net.PROTOCOL_VERSION and sent[1].v == 1)
    assert(sent[1].pv == net.PROTOCOL_REVISION and net.PROTOCOL_REVISION >= 2)
  end,

  test_messages_of_older_nodes_without_revision_are_accepted_and_counted_as_revision_1 = function()
    local b = endpoint("B")
    assert(b.receive(msg({ id = "old-1" })) == "ok")
    assert(b.peer_revision("A") == 1)
    assert(b.receive(msg({ id = "new-1", src = "C", pv = 2 })) == "ok")
    assert(b.peer_revision("C") == 2)
    assert(b.peer_revision("nobody") == nil)
  end,

  test_a_different_major_version_is_refused = function()
    local b = endpoint("B")
    assert(b.receive(msg({ v = 2 })) == "invalid")
    local without = msg(); without.v = nil
    assert(b.receive(without) == "invalid")
  end,

  test_malformed_envelopes_are_refused = function()
    local b = endpoint("B")
    local bad = {
      msg({ payload = "text" }), msg({ payload = 5 }), msg({ src = "" }), msg({ dst = "" }), msg({ id = string.rep("x", 200) }),
      msg({ ts = "yesterday" }), msg({ type = "format-disk" }), msg({ src = string.rep("n", 100) }), msg({ pv = "two" })
    }
    for i, m in ipairs(bad) do assert(b.receive(m) == "invalid", "case " .. i .. " was accepted") end
    assert(b.receive(msg({ payload = nil, id = "no-payload" })) == "ok", "a missing payload is fine, it means empty")
    assert(b.receive(msg({ id = "with-ts", ts = 12345 })) == "ok")
  end,

  test_peer_table_does_not_grow_without_bound = function()
    local b = endpoint("B")
    for i = 1, 3000 do b.receive(msg({ id = "i." .. i, src = "S" .. i, pv = 2 })) end
    local count = 0
    for _ in pairs(b.peers) do count = count + 1 end
    assert(count <= 1024, "peer table holds " .. count)
  end,

  test_ack_says_whether_the_work_was_done = function()
    local a, sent = endpoint("A")
    local original = msg({ id = "o.1", src = "M", dst = "A", type = "cmd" })
    a.ack_for(original)
    a.ack_for(original, true)
    assert(sent[1].payload.ack_id == "o.1" and sent[1].payload.applied == nil)
    assert(sent[2].payload.applied == true)
  end,

  test_on_ack_reports_the_kind_of_acknowledgement = function()
    local m, sent = endpoint("M")
    local seen = {}
    m.on_ack = function(ack_payload, original) seen[#seen + 1] = { applied = ack_payload.applied, type = original and original.type } end
    local one = m.send_reliable("cmd", "N1", {})
    local two = m.send_reliable("cmd", "N1", {})
    m.receive({ v = 1, id = "a.1", src = "N1", dst = "M", type = "ack", payload = { ack_id = one.id } })
    m.receive({ v = 1, id = "a.2", src = "N1", dst = "M", type = "ack", payload = { ack_id = two.id, applied = true } })
    assert(#seen == 2 and seen[1].applied == nil and seen[2].applied == true and seen[1].type == "cmd")
    assert(next(m.pending) == nil)
  end,

  test_node_acknowledges_an_executed_command_as_applied_and_an_ota_chunk_as_delivered_only = function()
    local sent = {}
    local modem = { open = function() return true end, send = function(_, _, _, m) sent[#sent + 1] = m; return true end, broadcast = function(_, _, m) sent[#sent + 1] = m; return true end }
    local node = common_node.new({ id = "N1", role = "signal", config = { channel = 1, master_id = "M" }, modem = modem, handlers = { on_cmd = function() return true end } })
    node.handle_message({ v = 1, id = "c.1", src = "M", dst = "N1", type = "cmd", payload = { cmd = "set" } })
    assert(sent[#sent].type == "ack" and sent[#sent].payload.applied == true)
    node.handle_message({ v = 1, id = "c.2", src = "M", dst = "N1", type = "cmd", payload = { cmd = "ota_chunk", update_id = "u", path = "src/x.lua", index = 1, total = 1, data = "x" } })
    local ack
    for _, m in ipairs(sent) do if m.type == "ack" and m.payload.ack_id == "c.2" then ack = m end end
    assert(ack and ack.payload.applied == nil, "a delivered chunk is not an applied update")
  end
}
