--[[
Purpose: The panel gets the topology of the master while it runs: in parts, checked, and drawn only when it is the topology the master runs (Gesamtkonzept Kap. 11.3, 13).
Public API: returns table of tests.
]]

local topology_sync = require("src.panel.topology_sync")
local plan_service = require("src.master.plan_service")
local json = require("src.shared.json")
local memfs = require("tests.harness.memfs")
local safety_graph = require("src.domain.safety_graph")
local netplan = require("src.setup.netplan")

local function plan(extra_blocks)
  local cfg = { v = 1, channel = 5, master_id = "M", nodes = { { id = "M", role = "master" }, { id = "PANEL-1", role = "panel" } }, blocks = {}, routes = {} }
  for i = 1, 3 + (extra_blocks or 0) do
    cfg.blocks[i] = { id = "B" .. i, entry_signal = "S" .. i, exit_signal = "X" .. i, sensors = { "SEN-" .. i } }
    cfg.nodes[#cfg.nodes + 1] = { id = "S" .. i, role = "signal", adapter = "redstone", side = "left" }
    cfg.nodes[#cfg.nodes + 1] = { id = "X" .. i, role = "signal", adapter = "redstone", side = "left" }
    cfg.nodes[#cfg.nodes + 1] = { id = "SEN-" .. i, role = "sensor", adapter = "redstone", side = "left" }
  end
  cfg.routes[1] = { id = "R1", from = "A", to = "B", blocks = { "B1", "B2", "B3" } }
  return cfg
end

local function world(cfg, chunk)
  local fs = memfs.new()
  local text = netplan.encode(cfg)
  fs.set("plan.json", text)
  local service = plan_service.new({ plan_path = "plan.json", fs = { exists = fs.exists, open = fs.open }, chunk_size = chunk or 200, now_s = function() return 1 end })
  local w = { fs = fs, sent = {}, clock = 10, service = service }
  w.network = { send_reliable = function(kind, dst, payload) w.seq = (w.seq or 0) + 1; local msg = { id = "q" .. w.seq, payload = payload }; w.sent[#w.sent + 1] = msg; return msg end }
  w.sync = topology_sync.new({ network = w.network, master_id = "M", panel_id = "PANEL-1", now = function() return w.clock end, fs = fs, path = "state/panel_topology.json", wait_s = 5 })
  -- the master answers the last question
  function w.answer()
    local question = w.sent[#w.sent]
    local reply = service.part(question.payload.index, question.payload.version)
    reply.question = question.id
    return w.sync.on_part(reply)
  end
  w.version = safety_graph.build(cfg).version
  return w
end

return {
  test_a_new_topology_version_starts_a_transfer_that_ends_in_the_graph_of_the_master = function()
    local w = world(plan())
    w.sync.announce(w.version)
    assert(w.sync.state() == "WAITING")
    w.sync.tick()
    local last = w.sent[#w.sent].payload
    assert(last.type == "plan_get" and last.role == "panel" and last.index == 1)
    local steps = 0
    while w.sync.state() == "WAITING" and steps < 80 do w.answer(); steps = steps + 1 end
    assert(steps > 1, "the plan came in several parts")
    assert(w.sync.state() == "READY" and w.sync.graph().version == w.version)
    assert(w.sync.graph().blocks.B2 ~= nil)
  end,

  test_a_plan_that_is_not_the_topology_the_master_runs_is_not_drawn = function()
    local w = world(plan(2))
    w.sync.announce(safety_graph.build(plan()).version)
    w.sync.tick()
    local steps = 0
    while w.sync.state() == "WAITING" and steps < 80 do w.answer(); steps = steps + 1 end
    local state, reason = w.sync.state()
    assert(state == "MISMATCH" and w.sync.graph() == nil and reason:find("not the topology", 1, true))
  end,

  test_a_part_that_is_late_is_asked_for_again_and_a_wrong_answer_is_ignored = function()
    local w = world(plan())
    w.sync.announce(w.version)
    w.sync.tick()
    local count = #w.sent
    w.sync.tick()
    assert(#w.sent == count, "not asked again before the time is up")
    w.clock = w.clock + 6
    w.sync.tick()
    assert(#w.sent == count + 1, "asked again")
    assert(w.sync.on_part({ ok = true, index = 1, total = 2, version = "00000000", size = 5, data = "x", question = "other" }) == false)
    assert(w.sync.on_part({ ok = true, index = 2, total = 2, version = "00000000", size = 5, data = "x", question = w.sent[#w.sent].id }) == false, "wrong index")
    assert(w.sync.state() == "WAITING")
  end,

  test_a_damaged_transfer_is_failed_even_when_it_would_still_read_and_junk_is_ignored = function()
    local w = world(plan(), 100000)
    w.sync.announce(w.version)
    w.sync.tick()
    local question = w.sent[#w.sent]
    local reply = w.service.part(1, nil)
    reply.question = question.id
    -- one character changed, the text is still a plan: only the checksum can tell
    local damaged = reply.data:gsub('"B1"', '"BX"', 1)
    assert(#damaged == #reply.data and damaged ~= reply.data)
    reply.data = damaged
    assert(w.sync.on_part(reply) == false)
    local state, why = w.sync.state()
    assert(state == "FAILED" and why:find("damaged", 1, true), tostring(why))
    assert(w.sync.on_part("junk") == false and w.sync.on_part(nil) == false)
  end,

  test_a_refusal_ends_the_transfer_with_the_reason = function()
    local w = world(plan())
    w.sync.announce(w.version)
    w.sync.tick()
    assert(w.sync.on_part({ ok = false, state = "refused", reason = "role", question = w.sent[#w.sent].id }) == false)
    local state, reason = w.sync.state()
    assert(state == "FAILED" and reason == "role")
  end,

  test_after_a_restart_the_copy_on_disk_is_used_only_for_the_announced_version = function()
    local w = world(plan())
    w.sync.announce(w.version); w.sync.tick()
    while w.sync.state() == "WAITING" do w.answer() end
    assert(w.sync.state() == "READY")
    local again = topology_sync.new({ network = w.network, master_id = "M", panel_id = "PANEL-1", now = function() return w.clock end, fs = w.fs, path = "state/panel_topology.json" })
    again.announce(w.version)
    assert(again.state() == "READY" and again.graph().version == w.version, "no transfer needed")
    local other = topology_sync.new({ network = w.network, master_id = "M", panel_id = "PANEL-1", now = function() return w.clock end, fs = w.fs, path = "state/panel_topology.json" })
    other.announce("deadbeef")
    assert(other.state() == "WAITING" and other.graph() == nil, "a copy of another version is not drawn")
  end
}
