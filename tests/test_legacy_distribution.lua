--[[
Purpose: Nodes that were set up before the verified over-the-air update get there: their startup.lua is upgraded by the node
  itself, and the master has a single-message "legacy" push for the first distribution of the new files.
Public API: returns table of tests.
]]

pcall(dofile, "tests/harness/cc_bootstrap.lua")

local template = require("src.shared.startup_template")
local startup_guard = require("src.shared.startup_guard")
local ota_manager = require("src.master.ota_manager")
local memfs = require("tests.harness.memfs")

local function compile(text)
  local loader = loadstring or load
  return loader(text, "=startup")
end

local function read_all(path)
  local fh = io.open(path, "r")
  local body = fh:read("*a")
  fh:close()
  return body
end

-- startup.lua as the first setup.lua wrote it: the current template without the recovery block
local function setup_v1_text()
  local text = template.render({ role = "sensor", id = "SEN-7", config = "configs/network.json" })
  local from = text:find("-- Undo a half-done", 1, true)
  local to = text:find("local entrypoint = role_entrypoints", 1, true)
  return text:sub(1, from - 1) .. text:sub(to)
end

-- the repository's startup.lua before the recovery existed (taken from the first version of this project)
local REPO_STARTUP_V1 = [==[
--[[
CreateRailNet-V3 CC:Tweaked startup entrypoint.
]]

local CRN_ROLE = "master"
local CRN_ID = "MASTER-1"
local CRN_CONFIG = "configs/templates/network.full.example.json"

local role_entrypoints = {
  master = "src.master.main",
  sensor = "src.nodes.sensor_node"
}

local entrypoint = role_entrypoints[CRN_ROLE]
if not entrypoint then error("Unknown CRN_ROLE: " .. tostring(CRN_ROLE)) end
local mod = require(entrypoint)
]==]

-- startup.lua exactly as it stood on the main branch before the recovery existed
local REPO_STARTUP_MAIN = [==[--[[
CreateRailNet-V3 CC:Tweaked startup entrypoint.
Edit CRN_ROLE, CRN_ID, and CRN_CONFIG on each computer.
]]

local CRN_ROLE = "master"
local CRN_ID = "MASTER-1"
local CRN_CONFIG = "configs/templates/network.full.example.json"

local role_entrypoints = {
  master = "src.master.main",
  signal = "src.nodes.signal_node",
  sensor = "src.nodes.sensor_node",
  switch = "src.nodes.switch_node",
  train = "src.nodes.train_node",
  station = "src.nodes.station_node",
  depot = "src.nodes.depot_node",
  panel = "src.nodes.panel_node"
}

local entrypoint = role_entrypoints[CRN_ROLE]
if not entrypoint then error("Unknown CRN_ROLE: " .. tostring(CRN_ROLE)) end

-- Read version from version file if it exists (written by OTA push)
local function read_version()
  if fs and fs.exists and fs.exists("crn_version.txt") then
    local fh = fs.open("crn_version.txt", "r")
    if fh then local v = fh.readLine(); fh.close(); return v end
  end
  return "unknown"
end
local CRN_VERSION = read_version()
print("CreateRailNet v" .. CRN_VERSION .. "  role=" .. CRN_ROLE .. "  id=" .. CRN_ID)
local mod = require(entrypoint)
if mod and mod.new_runtime then
  mod.new_runtime({ id = CRN_ID, config = CRN_CONFIG }).run()
elseif mod and mod.run then
  mod.run({ id = CRN_ID, config = CRN_CONFIG })
else
  shell.run("run", entrypoint, "--id", CRN_ID, "--config", CRN_CONFIG)
end
]==]

local function quiet_logger()
  local seen = { info = {}, warn = {} }
  local logger = { seen = seen, error = function() end, debug = function() end }
  logger.info = function(text) seen.info[#seen.info + 1] = text end
  logger.warn = function(text) seen.warn[#seen.warn + 1] = text end
  return logger
end

-- a fake network that records what the manager sends
local function fake_network()
  local net = { sent = {} }
  net.send_reliable = function(kind, dst, payload) net.sent[#net.sent + 1] = { kind = kind, dst = dst, payload = payload }; return { id = #net.sent } end
  net.send = net.send_reliable
  return net
end

local function legacy_manager(clock, extra)
  local net = fake_network()
  local options = {
    now_ms = function() return clock.now end,
    read_file = function(path) return "-- body of " .. path .. "\n" end,
    no_drop_hook = true
  }
  for k, v in pairs(extra or {}) do options[k] = v end
  return ota_manager.new(net, nil, nil, options), net
end

local function files(n)
  local out = {}
  for i = 1, n do out[i] = { path = "src/shared/f" .. i .. ".lua", content = "return " .. i .. "\n" } end
  return out
end

return {
  -- startup.lua -----------------------------------------------------------------------------------------------

  test_setup_v1_startup_gets_the_recovery_in_front_of_the_entry_point = function()
    local old = setup_v1_text()
    assert(not old:find("ota_recovery", 1, true))
    local upgraded, status = template.upgrade(old)
    assert(status == "upgraded" and upgraded, tostring(status))
    assert(compile(upgraded), "still loads")
    local recovery_at = upgraded:find("src.shared.ota_recovery", 1, true)
    local entry_at = upgraded:find("local entrypoint = role_entrypoints", 1, true)
    assert(recovery_at and entry_at and recovery_at < entry_at, "recovery runs before the role is picked")
    assert(upgraded:find('CRN_ID     = "SEN-7"', 1, true), "id and role stay")
    -- the same file a fresh setup would write
    assert(upgraded == template.render({ role = "sensor", id = "SEN-7", config = "configs/network.json" }))
  end,

  test_repository_startup_of_the_first_version_is_upgraded = function()
    local upgraded, status = template.upgrade(REPO_STARTUP_V1)
    assert(status == "upgraded" and compile(upgraded))
    assert(upgraded:find("recovery.recover", 1, true))
    local real = template.upgrade(REPO_STARTUP_MAIN)
    assert(real and compile(real), "the real old startup.lua too")
    assert(real:find("recovery.recover", 1, true) < real:find("local entrypoint", 1, true))
  end,

  test_upgrade_is_idempotent_and_leaves_current_files_alone = function()
    local current = template.render({ role = "panel", id = "P-1", config = "c.json" })
    local text, status = template.upgrade(current)
    assert(status == "current" and text == current)
    local once = template.upgrade(setup_v1_text())
    local again, status2 = template.upgrade(once)
    assert(status2 == "current" and again == once)
  end,

  test_unknown_layouts_are_refused = function()
    local text, why = template.upgrade("print('my own startup')\nshell.run('x')\n")
    assert(text == nil and why:find("not recognised", 1, true))
    local twice = setup_v1_text() .. "\n-- local entrypoint = role_entrypoints[CRN_ROLE]\n"
    -- the anchor appears in a comment too: ambiguous, so nothing is guessed
    local result = template.upgrade(twice)
    assert(result == nil)
    assert(template.upgrade(nil) == nil)
  end,

  test_guard_rewrites_startup_and_keeps_the_old_copy = function()
    local fs = memfs.new()
    fs.set("startup.lua", setup_v1_text())
    local logger = quiet_logger()
    local status = startup_guard.ensure({ fs = fs, logger = logger })
    assert(status == "upgraded", tostring(status))
    assert(fs.files["startup.lua"]:find("ota_recovery", 1, true))
    assert(fs.files["startup.lua.prev"] == setup_v1_text(), "the old file is kept")
    assert(logger.seen.info[1]:find("startup.lua", 1, true))
    assert(startup_guard.ensure({ fs = fs, logger = logger }) == "current")
    assert(#logger.seen.info == 1, "said once")
  end,

  test_guard_leaves_unknown_files_alone_and_says_so = function()
    local fs = memfs.new()
    fs.set("startup.lua", "print('mine')\n")
    local logger = quiet_logger()
    local status, detail = startup_guard.ensure({ fs = fs, logger = logger })
    assert(status == "unrecognized" and detail:find("not recognised", 1, true))
    assert(fs.files["startup.lua"] == "print('mine')\n" and fs.files["startup.lua.prev"] == nil)
    assert(#logger.seen.warn == 1)
  end,

  test_guard_can_be_switched_off_and_never_raises = function()
    local fs = memfs.new()
    fs.set("startup.lua", setup_v1_text())
    assert(startup_guard.ensure({ fs = fs, enabled = false }) == "skipped")
    assert(not fs.files["startup.lua"]:find("ota_recovery", 1, true))
    assert(startup_guard.ensure({ fs = memfs.new() }) == "skipped", "no startup.lua at all")
    -- a disk that dies in the middle of the write
    local broken = memfs.new()
    broken.set("startup.lua", setup_v1_text())
    broken.crash_at = 1
    local status = startup_guard.ensure({ fs = broken })
    assert(status == "error", tostring(status))
  end,

  -- legacy push ----------------------------------------------------------------------------------------------

  test_node_closure_is_what_a_node_loads_and_nothing_of_the_master = function()
    local paths = ota_manager.node_closure(function(path)
      local fh = io.open(path, "r")
      if not fh then return nil end
      local body = fh:read("*a")
      fh:close()
      return body
    end)
    local set = {}
    for _, path in ipairs(paths) do set[path] = true end
    for _, must in ipairs({ "src/nodes/signal_node.lua", "src/nodes/panel_node.lua", "src/nodes/common_node.lua", "src/shared/net.lua",
      "src/shared/updater.lua", "src/shared/ota_recovery.lua", "src/shared/checksum.lua", "src/shared/safe_write.lua", "src/shared/startup_guard.lua",
      "src/shared/ticker.lua" }) do
      assert(set[must], "missing " .. must)
    end
    for _, path in ipairs(paths) do
      assert(not path:find("^src/master/") and not path:find("^src/tools/") and not path:find("^scripts/"), "does not belong on a node: " .. path)
    end
    assert(#paths < 80, #paths)
    -- closed: everything a listed file requires is listed too
    for _, path in ipairs(paths) do
      local body = read_all(path)
      for dep in body:gmatch('require%s*%(%s*"([%w_%.]+)"') do
        assert(set[dep:gsub("%.", "/") .. ".lua"], path .. " needs " .. dep)
      end
    end
  end,

  test_legacy_push_sends_one_ota_update_message_per_node = function()
    local clock = { now = 0 }
    local manager, net = legacy_manager(clock)
    local results, err = manager.push(files(3), { nodes = { "N-1", "N-2" }, version = "v9", legacy = true })
    assert(err == nil and results["N-1"].ok and results["N-2"].ok)
    assert(#net.sent == 2)
    local m = net.sent[1]
    assert(m.kind == "cmd" and m.dst == "N-1" and m.payload.cmd == "ota_update" and m.payload.version == "v9")
    assert(m.payload.file_count == 3 and #m.payload.files == 3)
    assert(m.payload.files[1].path == "src/shared/f1.lua" and m.payload.files[1].content == "return 1\n" and type(m.payload.files[1].adler) == "number")
    assert(manager.status()[1].state == "COMMITTING")
  end,

  test_legacy_needs_a_list_of_nodes = function()
    local manager = legacy_manager({ now = 0 })
    local r1, e1 = manager.push(files(1), { legacy = true })
    assert(next(r1) == nil and e1:find("list of nodes", 1, true))
    local r2, e2 = manager.push(files(1), { legacy = true, discover = true })
    assert(e2 and next(r2) == nil)
  end,

  test_legacy_push_reads_the_closure_when_no_files_are_given = function()
    local manager, net = legacy_manager({ now = 0 }, { read_file = function(path)
      local fh = io.open(path, "r")
      if not fh then return nil, "missing" end
      local body = fh:read("*a")
      fh:close()
      return body
    end })
    local results = manager.push_legacy({ nodes = { "N-1" }, version = "v10" })
    assert(results["N-1"].ok)
    local sent = net.sent[1].payload
    assert(sent.file_count > 20 and sent.cmd == "ota_update")
    local has_net = false
    for _, f in ipairs(sent.files) do if f.path == "src/shared/net.lua" then has_net = true end end
    assert(has_net)
  end,

  test_legacy_node_result_and_first_new_heartbeat_confirm = function()
    local clock = { now = 0 }
    local manager = legacy_manager(clock)
    manager.push(files(2), { nodes = { "N-1" }, version = "v9", legacy = true })
    -- an old node answers without an update id
    assert(manager.on_result({ src = "N-1", payload = { type = "ota_result", node_id = "N-1", success = true, files = 2, version = "v9" } }))
    assert(manager.status()[1].state == "DONE")
    assert(manager.is_updating("N-1"), "silent on purpose while it reboots")
    assert(manager.on_heartbeat({ src = "N-1", pv = 1 }) == false, "the old code heartbeats too")
    assert(manager.status()[1].state == "DONE")
    assert(manager.on_heartbeat({ src = "N-1", pv = 2 }))
    assert(manager.status()[1].state == "CONFIRMED")
    assert(manager.finished())
  end,

  test_legacy_failure_and_silence_are_reported = function()
    local clock = { now = 0 }
    local manager = legacy_manager(clock)
    manager.push(files(2), { nodes = { "N-1", "N-2" }, version = "v9", legacy = true })
    manager.on_result({ src = "N-1", payload = { type = "ota_result", node_id = "N-1", success = false, errors = { "write failed: src/shared/f1.lua" } } })
    local states = {}
    for _, s in ipairs(manager.status()) do states[s.node_id] = s end
    assert(states["N-1"].state == "FAILED" and states["N-1"].error:find("write failed", 1, true))
    clock.now = 31000
    manager.tick()
    states = {}
    for _, s in ipairs(manager.status()) do states[s.node_id] = s end
    assert(states["N-2"].state == "FAILED" and states["N-2"].error:find("no result", 1, true))
    assert(manager.finished())
  end,

  test_legacy_rollout_respects_max_parallel = function()
    local clock = { now = 0 }
    local manager, net = legacy_manager(clock, { max_parallel = 2 })
    manager.push(files(1), { nodes = { "N-1", "N-2", "N-3", "N-4" }, version = "v9", legacy = true })
    assert(#net.sent == 2, "two at a time: " .. #net.sent)
    manager.on_result({ src = "N-1", payload = { type = "ota_result", success = true, version = "v9" } })
    manager.tick()
    assert(#net.sent == 3, "the next one starts when a slot is free: " .. #net.sent)
  end
}
