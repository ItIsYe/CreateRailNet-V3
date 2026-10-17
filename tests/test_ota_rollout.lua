--[[
Purpose: Whole OTA rollout: a master-side manager and several real nodes (common_node + updater on in-memory filesystems)
  over the lossy link harness. Files arrive complete or not at all, nodes recover from bad updates, rollouts stay small.
Public API: returns table of tests.
]]

pcall(dofile, "tests/harness/cc_bootstrap.lua")

local net = require("src.shared.net")
local time = require("src.shared.time")
local common_node = require("src.nodes.common_node")
local ota_manager = require("src.master.ota_manager")
local ota_recovery = require("src.shared.ota_recovery")
local checksum = require("src.shared.checksum")
local prng = require("tests.harness.prng")
local lossy_link = require("tests.harness.lossy_link")
local memfs = require("tests.harness.memfs")

local function quiet_logger()
  local function noop() end
  return { info = noop, warn = noop, error = noop, debug = noop }
end

local function body(label, size)
  local line = label .. " ............................................................\n"
  return string.rep(line, math.ceil(size / #line)):sub(1, size)
end

local OLD = {
  ["src/shared/net.lua"] = body("net v1", 2500),
  ["src/shared/util.lua"] = body("util v1", 600),
  ["src/nodes/signal_node.lua"] = body("signal v1", 4000),
  ["src/nodes/sensor_node.lua"] = body("sensor v1", 1500),
  ["crn_version.txt"] = "v1"
}

local function new_files()
  return {
    { path = "src/shared/net.lua", content = body("net v2", 3100) },
    { path = "src/shared/util.lua", content = OLD["src/shared/util.lua"] },
    { path = "src/nodes/signal_node.lua", content = body("signal v2", 4200) },
    { path = "src/nodes/sensor_node.lua", content = OLD["src/nodes/sensor_node.lua"] },
    { path = "src/domain/ota_extra.lua", content = body("extra v2", 900) }
  }
end

local function expected_after(files)
  local out = { ["crn_version.txt"] = "v2" }
  for _, f in ipairs(files) do out[f.path] = f.content end
  return out
end

-- builds the master side and `count` nodes on one link; returns the world
local function build(seed, count, link_opts, manager_opts)
  local rng = prng.new(seed)
  local link = lossy_link.new(rng, link_opts)
  local w = { link = link, nodes = {}, order = {}, chunks_sent = 0, max_active = 0 }
  w.network = net.new(link.modem("M"), 1, "M", quiet_logger(), time)
  local original_send = w.network.send_reliable
  w.network.send_reliable = function(kind, dst, payload)
    if payload and payload.cmd == "ota_chunk" then w.chunks_sent = w.chunks_sent + 1 end
    return original_send(kind, dst, payload)
  end
  local mo = { now_ms = function() return link.now() end, chunk_size = 1000, window = 3, max_parallel = 4, offer_timeout_ms = 1500, stall_timeout_ms = 20000, result_timeout_ms = 10000 }
  for k, v in pairs(manager_opts or {}) do mo[k] = v end
  w.manager = ota_manager.new(w.network, nil, quiet_logger(), mo)

  link.set_receiver("M", function(msg)
    local status = w.network.receive(msg)
    if (status == "ok" or status == "duplicate") and msg.type == "event" and type(msg.payload) == "table" then
      if status == "ok" then
        local kind = msg.payload.type
        if kind == "ota_need" then w.manager.on_need(msg)
        elseif kind == "ota_result" then w.manager.on_result(msg)
        elseif kind == "ota_confirmed" then w.manager.on_confirmed(msg) end
      end
      w.network.ack_for(msg)
    end
  end)

  for i = 1, count do
    local id = "NODE-" .. i
    local state = { id = id, fs = memfs.new(), rebooted = false, quiesced = 0, boots = 0 }
    for path, content in pairs(OLD) do state.fs.set(path, content) end
    state.node = common_node.new({
      id = id, role = "signal", config = { channel = 1, master_id = "M" }, modem = link.modem(id), logger = quiet_logger(),
      ota = { fs = state.fs, reboot = function() state.rebooted = true end, sleep = function() end },
      handlers = { on_quiesce = function() state.quiesced = state.quiesced + 1; return true end, on_cmd = function() return true end }
    })
    link.set_receiver(id, function(msg) state.node.handle_event({ "modem_message", "side", 1, 1, msg }) end)
    w.nodes[id] = state
    w.order[#w.order + 1] = id
  end
  return w
end

-- a node that rebooted comes up again: startup recovery first, then the program (which confirms a good first boot)
local function boot(state, crash_before_confirm)
  state.rebooted = false
  state.boots = state.boots + 1
  state.last_recovery = ota_recovery.recover(state.fs)
  if not crash_before_confirm then
    -- startup.lua ran recovery with the real fs; the node confirms through its own updater, which holds this fs
    state.node.start()
  end
end

local function run(w, steps, hooks)
  for _ = 1, steps do
    w.link.advance(50)
    w.manager.tick()
    w.network.tick()
    local active = 0
    for _, status in ipairs(w.manager.status()) do if status.state == "OFFERED" or status.state == "SENDING" or status.state == "COMMITTING" then active = active + 1 end end
    if active > w.max_active then w.max_active = active end
    for _, id in ipairs(w.order) do
      local state = w.nodes[id]
      state.node.handle_event({ "peripheral", "tick" })
      if state.rebooted then
        if hooks and hooks.on_reboot then hooks.on_reboot(state) else boot(state) end
      end
    end
    if w.manager.finished() then return end
  end
end

local function snapshot_matches(state, expected)
  for path, content in pairs(expected) do if state.fs.files[path] ~= content then return false end end
  return true
end

local function states(w)
  local out = {}
  for _, s in ipairs(w.manager.status()) do out[s.node_id] = s end
  return out
end

return {
  test_clean_rollout_updates_every_node_and_sends_only_what_differs = function()
    local w = build(1, 3, { drop = 0, duplicate = 0, delay_max_ms = 0 })
    local files = new_files()
    local update = assert(w.manager.start(files, { nodes = w.order, version = "v2" }))
    run(w, 600)
    local expected = expected_after(files)
    for _, id in ipairs(w.order) do
      assert(w.nodes[id].fs.files["crn_version.txt"] == "v2", id .. " version")
      assert(snapshot_matches(w.nodes[id], expected), id .. " files")
      assert(states(w)[id].state == "CONFIRMED", id .. " state " .. states(w)[id].state)
      assert(w.nodes[id].quiesced == 1 and w.nodes[id].boots == 1)
      assert(w.nodes[id].fs.files[ota_recovery.JOURNAL] == nil, "journal is cleaned up after the confirmed boot")
    end
    -- net v2 (3100 bytes) = 4 chunks, signal v2 (4200) = 5, extra (900) = 1; the unchanged files are never sent
    assert(w.chunks_sent == 3 * 10, "chunks sent: " .. w.chunks_sent)
    assert(update.id)
  end,

  test_rollout_survives_loss_duplication_and_delay_without_a_mixed_state = function()
    for seed = 21, 26 do
      local w = build(seed, 4, { drop = 0.15, duplicate = 0.3, delay_max_ms = 300 })
      local files = new_files()
      assert(w.manager.start(files, { nodes = w.order, version = "v2" }))
      run(w, 4000)
      local expected = expected_after(files)
      for _, id in ipairs(w.order) do
        local state = w.nodes[id]
        local is_new, is_old = snapshot_matches(state, expected), snapshot_matches(state, OLD)
        assert(is_new or is_old, string.format("seed %d %s ended with a mixed file set", seed, id))
        assert(states(w)[id].state == "CONFIRMED" and is_new, string.format("seed %d %s is %s (%s)", seed, id, states(w)[id].state, tostring(states(w)[id].error)))
      end
    end
  end,

  test_damaged_chunk_is_requested_again = function()
    local w = build(2, 1, { drop = 0, duplicate = 0, delay_max_ms = 0 })
    -- the first big chunk arrives with a flipped byte
    local damaged = false
    local original = w.link.receivers["NODE-1"]
    w.link.set_receiver("NODE-1", function(msg)
      if not damaged and msg.payload and msg.payload.cmd == "ota_chunk" and msg.payload.index == 2 then
        damaged = true
        msg = { v = msg.v, id = msg.id, type = msg.type, src = msg.src, dst = msg.dst, ts = msg.ts, payload = { cmd = "ota_chunk", type = "ota_chunk", update_id = msg.payload.update_id, path = msg.payload.path, index = 2, total = msg.payload.total, data = msg.payload.data:gsub("%.", "!", 1) } }
      end
      original(msg)
    end)
    local files = new_files()
    assert(w.manager.start(files, { nodes = w.order, version = "v2" }))
    run(w, 800)
    assert(damaged)
    assert(states(w)["NODE-1"].state == "CONFIRMED")
    assert(snapshot_matches(w.nodes["NODE-1"], expected_after(files)))
  end,

  test_silent_node_fails_alone_and_does_not_block_the_others = function()
    local w = build(3, 3, { drop = 0, duplicate = 0, delay_max_ms = 0 })
    w.link.set_receiver("NODE-2", nil)
    local files = new_files()
    assert(w.manager.start(files, { nodes = w.order, version = "v2" }))
    run(w, 1500)
    local s = states(w)
    assert(s["NODE-2"].state == "FAILED" and tostring(s["NODE-2"].error):find("no answer"), tostring(s["NODE-2"].error))
    assert(s["NODE-1"].state == "CONFIRMED" and s["NODE-3"].state == "CONFIRMED")
    assert(w.manager.is_updating("NODE-2") == false)
    assert(snapshot_matches(w.nodes["NODE-2"], OLD))
  end,

  test_only_max_parallel_nodes_transfer_at_once = function()
    local w = build(4, 7, { drop = 0, duplicate = 0, delay_max_ms = 100 }, { max_parallel = 2 })
    local files = new_files()
    assert(w.manager.start(files, { nodes = w.order, version = "v2" }))
    run(w, 3000)
    assert(w.max_active <= 2, "up to " .. w.max_active .. " nodes were active at once")
    for _, id in ipairs(w.order) do assert(states(w)[id].state == "CONFIRMED", id) end
  end,

  test_update_that_never_confirms_is_rolled_back_by_the_node = function()
    local w = build(5, 1, { drop = 0, duplicate = 0, delay_max_ms = 0 })
    local files = new_files()
    assert(w.manager.start(files, { nodes = w.order, version = "v2" }))
    local crashes = 0
    run(w, 600, { on_reboot = function(state)
      -- the new code dies before it reaches its main loop: no confirm, the computer is started again
      crashes = crashes + 1
      boot(state, true)
      if crashes == 1 then boot(state, true) end
    end })
    local state = w.nodes["NODE-1"]
    assert(state.last_recovery == "rolled_back", tostring(state.last_recovery))
    assert(snapshot_matches(state, OLD), "the node must be back on its previous version")
    assert(state.fs.files["src/domain/ota_extra.lua"] == nil)
  end,

  test_nodes_refuse_an_update_from_an_unknown_sender = function()
    local w = build(6, 2, { drop = 0, duplicate = 0, delay_max_ms = 0 })
    local rogue_net = net.new(w.link.modem("EVIL"), 1, "EVIL", quiet_logger(), time)
    local rogue = ota_manager.new(rogue_net, nil, quiet_logger(), { now_ms = function() return w.link.now() end, chunk_size = 1000 })
    local files = new_files()
    assert(rogue.start(files, { nodes = w.order, version = "evil" }))
    for _ = 1, 400 do
      w.link.advance(50)
      rogue.tick(); rogue_net.tick()
      for _, id in ipairs(w.order) do w.nodes[id].node.handle_event({ "peripheral", "tick" }) end
    end
    for _, id in ipairs(w.order) do
      assert(snapshot_matches(w.nodes[id], OLD), id .. " accepted an update from EVIL")
      assert(w.nodes[id].quiesced == 0 and w.nodes[id].fs.files[ota_recovery.JOURNAL] == nil)
    end
  end,

  test_second_start_is_refused_while_nodes_are_busy = function()
    local w = build(7, 1, { drop = 0, duplicate = 0, delay_max_ms = 0 })
    assert(w.manager.start(new_files(), { nodes = w.order, version = "v2" }))
    local again, err = w.manager.start(new_files(), { nodes = w.order, version = "v3" })
    assert(again == nil and tostring(err):find("still running"))
  end,

  test_manager_rejects_paths_that_nodes_would_refuse = function()
    local w = build(8, 1, { drop = 0, duplicate = 0, delay_max_ms = 0 })
    local update, err = w.manager.start({ { path = "startup.lua", content = "x" }, { path = "../x.lua", content = "y" } }, { nodes = w.order })
    assert(update == nil and tostring(err):find("path not allowed"))
  end,

  test_updating_node_is_not_timed_out_and_a_finished_one_is_released_after_the_grace_period = function()
    local w = build(9, 1, { drop = 0, duplicate = 0, delay_max_ms = 0 }, { reboot_grace_ms = 2000 })
    assert(w.manager.start(new_files(), { nodes = w.order, version = "v2" }))
    assert(w.manager.is_updating("NODE-1"))
    run(w, 600)
    assert(states(w)["NODE-1"].state == "CONFIRMED")
    assert(w.manager.is_updating("NODE-1") == false)
    assert(w.manager.is_updating("UNKNOWN") == false)
  end,

  test_discover_mode_finds_nodes_that_answer_the_broadcast = function()
    local w = build(10, 3, { drop = 0, duplicate = 0, delay_max_ms = 0 })
    -- broadcast offers reach every node: the link addresses receivers by dst, so route "broadcast" to all of them
    local original_modem = w.link.modem("M")
    w.network.modem = {
      send = original_modem.send,
      broadcast = function(_, _, msg) for _, id in ipairs(w.order) do local copy = {}; for k, v in pairs(msg) do copy[k] = v end; copy.dst = id; original_modem.send(nil, 1, id, copy) end; return true end
    }
    local files = new_files()
    assert(w.manager.start(files, { discover = true, discover_ms = 6000, version = "v2" }))
    run(w, 800)
    for _, id in ipairs(w.order) do
      assert(states(w)[id] and states(w)[id].state == "CONFIRMED", id)
      assert(snapshot_matches(w.nodes[id], expected_after(files)))
    end
  end
}
