--[[
Purpose: Master side of the over-the-air update. Rolls a new file set out to many nodes in small, verified steps.
Public API:
  new(network, registry, logger, opts) -> manager
    opts: sign_package(node_id, update) -> package | nil (src/shared/update_trust.lua), now_ms(), chunk_size (8192), window (chunks in flight per node, 4), max_parallel (nodes at once, 4),
          offer_timeout_ms (8000), offer_retries (3), stall_timeout_ms (30000), result_timeout_ms (30000),
          confirm_timeout_ms (120000), reboot_grace_ms (60000), read_file(path) -> body, list_runtime_files() -> paths
  manager.start(files, { nodes, version, discover }) -> update | nil, err      files = { {path, content} }
  manager.push_runtime(opts) -> results, err    reads the runtime files from disk; results[node_id] = { ok, error }
  manager.push(files, opts) / manager.push_to(node_id, files, version)       same as start, older call style
  manager.push_legacy(opts) -> results, err    for nodes that still run the code from before the verified OTA: one single-message
                                               update with the files a node needs to boot (opts.nodes is required)
  manager.on_heartbeat(msg)                    a legacy node that answers with protocol revision 2 has booted the new code
  manager.on_need(msg) / on_result(msg) / on_confirmed(msg)                   events sent by nodes
  manager.on_drop(msg)                                                        a reliable message ran out of retries
  manager.tick()                                                              drives offers, windows, commits, timeouts
  manager.is_updating(node_id) -> boolean      true while a node transfers, swaps or reboots (no timeout handling then)
  manager.status() -> list of { node_id, state, sent, total, error, version }
  manager.finished(include_done) -> boolean
Per node: QUEUED -> OFFERED -> SENDING -> COMMITTING -> DONE -> CONFIRMED, or FAILED / UNCONFIRMED.
Only files that differ are sent (the node compares size and Adler-32 from the offer), at most `window` chunks of
`chunk_size` bytes per node and `max_parallel` nodes at a time, so a rollout to many nodes does not flood the channel.
]]

local time = require("src.shared.time")
local checksum = require("src.shared.checksum")
local updater = require("src.shared.updater")
local require_scan = require("src.shared.require_scan")

local ota_manager = {}

local RUNTIME_DIRS = { "src/shared/", "src/domain/", "src/adapter/", "src/master/", "src/nodes/", "scripts/" }

-- What a node loads at start: the role entry points (startup.lua picks one) and the recovery startup.lua runs first.
local NODE_ENTRYPOINTS = {
  "src.nodes.signal_node", "src.nodes.sensor_node", "src.nodes.switch_node", "src.nodes.train_node",
  "src.nodes.station_node", "src.nodes.depot_node", "src.nodes.panel_node", "src.shared.ota_recovery"
}

local ACTIVE = { OFFERED = true, SENDING = true, COMMITTING = true }
local TERMINAL = { CONFIRMED = true, FAILED = true, UNCONFIRMED = true }

local function read_file(path)
  if fs and fs.open then
    if fs.exists and not fs.exists(path) then return nil, "not found: " .. path end
    local fh = fs.open(path, "r")
    if not fh then return nil, "cannot open: " .. path end
    local content = fh.readAll()
    fh.close()
    return content
  elseif io and io.open then
    local fh = io.open(path, "r")
    if not fh then return nil, "cannot open: " .. path end
    local content = fh:read("*a")
    fh:close()
    return content
  end
  return nil, "no file API"
end

local function list_runtime_files()
  local files = {}
  if not (fs and fs.exists and fs.list) then return files end
  local function scan(dir)
    for _, name in ipairs(fs.list(dir)) do
      local full = dir .. name
      if fs.isDir and fs.isDir(full) then scan(full .. "/")
      elseif name:match("%.lua$") then files[#files + 1] = full end
    end
  end
  for _, dir in ipairs(RUNTIME_DIRS) do
    if fs.exists(dir) then scan(dir) end
  end
  table.sort(files)
  return files
end

-- The files a node needs to boot the new code: every module the node entry points require, found by reading the source
-- (src/shared/require_scan.lua). Smaller than the whole runtime, so the old single-message update of a node that has no
-- verified OTA yet fits next to the files it replaces. read_body(path) -> body | nil
function ota_manager.node_closure(read_body)
  local paths = require_scan.closure(NODE_ENTRYPOINTS, read_body)
  return paths
end

function ota_manager.new(network, registry, logger, opts)
  local options = opts or {}
  local now_ms = options.now_ms or time.now_ms
  local chunk_size = options.chunk_size or 8192
  local window = options.window or 4
  local max_parallel = options.max_parallel or 4
  local offer_timeout = options.offer_timeout_ms or 8000
  local offer_retries = options.offer_retries or 3
  local stall_timeout = options.stall_timeout_ms or 30000
  local result_timeout = options.result_timeout_ms or 30000
  local confirm_timeout = options.confirm_timeout_ms or 120000
  local reboot_grace = options.reboot_grace_ms or 60000
  local read = options.read_file or read_file
  local list_files = options.list_runtime_files or list_runtime_files

  local self = { update = nil }
  local sequence = 0

  local function log(level, text, data)
    if logger and logger[level] then logger[level](text, data) end
  end

  local function send_cmd(dst, cmd, payload)
    payload.cmd = cmd
    payload.type = cmd
    if network.send_reliable then return network.send_reliable("cmd", dst, payload) end
    return network.send("cmd", dst, payload)
  end

  local function fail(session, reason)
    session.state = "FAILED"
    session.error = reason
    session.inflight, session.inflight_count = {}, 0
    log("warn", "OTA node failed", { node_id = session.node_id, error = reason })
  end

  local function chunks_of(update, path)
    local size = update.files[path].size
    return math.max(1, math.ceil(size / chunk_size))
  end

  local function plan_transfer(update, session, need)
    session.need = {}
    session.total = 0
    for _, path in ipairs(need) do
      if update.files[path] then
        session.need[#session.need + 1] = path
        session.total = session.total + chunks_of(update, path)
      end
    end
    table.sort(session.need)
    session.cursor_file, session.cursor_chunk = 1, 1
    session.sent, session.acked = 0, 0
    session.inflight, session.inflight_count = {}, 0
  end

  local function new_session(node_id)
    return { node_id = node_id, state = "QUEUED", tries = 0, need = {}, total = 0, sent = 0, acked = 0, inflight = {}, inflight_count = 0 }
  end

  local function offer(update, session, now)
    -- with keys: the package is signed for this node (src/shared/update_package.lua), so the node can tell that the content comes from this master and is whole
    local package = options.sign_package and options.sign_package(session.node_id, update) or nil
    local msg = send_cmd(session.node_id, "ota_offer", { update_id = update.id, version = update.version, files = update.manifest, package = package })
    session.state = "OFFERED"
    session.offered_at = now
    session.tries = session.tries + 1
    session.progress_at = now
    if not msg then fail(session, "offer could not be sent") end
  end

  local function send_next_chunks(update, session, now)
    while session.inflight_count < window and session.cursor_file <= #session.need do
      local path = session.need[session.cursor_file]
      local file = update.files[path]
      local total = chunks_of(update, path)
      local index = session.cursor_chunk
      local data = file.content:sub((index - 1) * chunk_size + 1, index * chunk_size)
      local msg = send_cmd(session.node_id, "ota_chunk", { update_id = update.id, path = path, index = index, total = total, data = data })
      if not msg then fail(session, "chunk could not be sent"); return end
      session.inflight[msg.id] = true
      session.inflight_count = session.inflight_count + 1
      session.sent = session.sent + 1
      if index >= total then session.cursor_file, session.cursor_chunk = session.cursor_file + 1, 1 else session.cursor_chunk = index + 1 end
    end
  end

  local function collect_acks(session, now)
    local pending = network.pending or {}
    for id in pairs(session.inflight) do
      if not pending[id] then
        session.inflight[id] = nil
        session.inflight_count = session.inflight_count - 1
        session.acked = session.acked + 1
        session.progress_at = now
      end
    end
  end

  -- the old way: everything in one message, applied by the old node without a chance to roll back
  local function send_legacy(update, session, now)
    if not update.legacy_files then
      update.legacy_files = {}
      for _, item in ipairs(update.manifest) do
        update.legacy_files[#update.legacy_files + 1] = { path = item.path, content = update.files[item.path].content, adler = item.adler }
      end
    end
    session.total = #update.legacy_files
    local msg = send_cmd(session.node_id, "ota_update", { update_id = update.id, version = update.version, files = update.legacy_files, file_count = #update.legacy_files })
    if msg then
      session.state = "COMMITTING"
      session.commit_at = now
      session.progress_at = now
      session.legacy = true
    else
      fail(session, "update could not be sent")
    end
  end

  function self.start(files, start_opts)
    local o = start_opts or {}
    if self.update then
      for _, session in pairs(self.update.sessions) do
        if ACTIVE[session.state] then return nil, "an update is still running" end
      end
    end
    local map, manifest, errors = {}, {}, {}
    for _, entry in ipairs(files or {}) do
      if type(entry.path) ~= "string" or type(entry.content) ~= "string" then
        errors[#errors + 1] = "entry without path or content"
      elseif not updater.valid_path(entry.path) then
        errors[#errors + 1] = "path not allowed: " .. entry.path
      elseif not map[entry.path] then
        map[entry.path] = { content = entry.content, size = #entry.content, adler = checksum.adler32(entry.content) }
        manifest[#manifest + 1] = { path = entry.path, size = #entry.content, adler = map[entry.path].adler }
      end
    end
    if #errors > 0 then return nil, table.concat(errors, "; ") end
    if #manifest == 0 then return nil, "no files to push" end
    table.sort(manifest, function(a, b) return a.path < b.path end)

    sequence = sequence + 1
    local version = tostring(o.version or ("ota-" .. tostring(time.now_s())))
    if o.legacy and (o.discover or not o.nodes) then return nil, "a legacy update needs the list of nodes" end
    local update = { id = string.format("%s-%d-%d", version, now_ms(), sequence), version = version, files = map, manifest = manifest, sessions = {}, order = {}, discover = o.discover == true, legacy = o.legacy == true }
    self.update = update

    local targets = o.nodes
    if not targets and not o.discover then
      targets = {}
      if registry and registry.all then for node_id in pairs(registry.all()) do targets[#targets + 1] = node_id end end
      table.sort(targets)
    end
    for _, node_id in ipairs(targets or {}) do
      update.sessions[node_id] = new_session(node_id)
      update.order[#update.order + 1] = node_id
    end
    if o.discover then
      update.discover_until = now_ms() + (o.discover_ms or 15000)
      update.next_broadcast = now_ms()
    end
    log("info", "OTA update started", { update_id = update.id, version = version, nodes = #update.order, files = #manifest, discover = update.discover })
    self.tick()
    return update
  end

  local function find_session(msg, create)
    local update = self.update
    if not update then return nil end
    local session = update.sessions[msg.src]
    if not session and create and update.discover then
      session = new_session(msg.src)
      session.state = "OFFERED"
      session.offered_at = now_ms()
      session.progress_at = session.offered_at
      update.sessions[msg.src] = session
      update.order[#update.order + 1] = msg.src
    end
    return session
  end

  function self.on_need(msg)
    local update, payload = self.update, msg and msg.payload or {}
    if not update or payload.update_id ~= update.id then return false end
    local session = find_session(msg, true)
    if not session or TERMINAL[session.state] or session.state == "DONE" then return false end
    if payload.reason then log("warn", "OTA node asks again", { node_id = msg.src, reason = payload.reason }) end
    plan_transfer(update, session, payload.need or {})
    session.state = "SENDING"
    session.progress_at = now_ms()
    if #session.need == 0 then fail(session, "node asked for files this update does not contain") end
    return true
  end

  function self.on_result(msg)
    local update, payload = self.update, msg and msg.payload or {}
    if not update then return false end
    if payload.update_id ~= nil and payload.update_id ~= update.id then return false end
    local session = find_session(msg, payload.update_id ~= nil)
    if not session then return false end
    -- the confirmation of the new boot can overtake the result that was sent just before the reboot
    if session.state == "CONFIRMED" then return true end
    local now = now_ms()
    if payload.success then
      session.version = payload.version or update.version
      session.result_at = now
      session.state = payload.up_to_date and "CONFIRMED" or "DONE"
    else
      fail(session, table.concat(payload.errors or { "node reported failure" }, "; "))
    end
    return true
  end

  function self.on_confirmed(msg)
    local update = self.update
    if not update then return false end
    local session = update.sessions[msg.src]
    if not session or session.state == "FAILED" then return false end
    session.state = "CONFIRMED"
    session.confirmed_at = now_ms()
    return true
  end

  -- a node that took the old single-message update never confirms itself: it counts once it answers with the new protocol
  function self.on_heartbeat(msg)
    local update = self.update
    local session = update and msg and update.sessions[msg.src]
    if session and session.legacy and session.state == "DONE" and (msg.pv or 1) >= 2 then
      session.state = "CONFIRMED"
      session.confirmed_at = now_ms()
      return true
    end
    return false
  end

  function self.on_drop(msg)
    local update = self.update
    if not update or not msg or not msg.dst then return end
    local session = update.sessions[msg.dst]
    local payload = msg.payload or {}
    if session and ACTIVE[session.state] and payload.update_id == update.id then
      fail(session, "no answer from node (" .. tostring(payload.cmd) .. " dropped after retries)")
    end
  end

  function self.tick()
    local update = self.update
    if not update then return end
    local now = now_ms()

    if update.discover and update.next_broadcast and now >= update.next_broadcast and now < update.discover_until then
      send_cmd("broadcast", "ota_offer", { update_id = update.id, version = update.version, files = update.manifest })
      update.next_broadcast = now + 3000
    end

    local active = 0
    for _, id in ipairs(update.order) do if ACTIVE[update.sessions[id].state] then active = active + 1 end end
    for _, id in ipairs(update.order) do
      local session = update.sessions[id]
      if session.state == "QUEUED" and active < max_parallel then
        if update.legacy then send_legacy(update, session, now) else offer(update, session, now) end
        if ACTIVE[session.state] then active = active + 1 end
      end
    end

    for _, id in ipairs(update.order) do
      local session = update.sessions[id]
      if session.state == "OFFERED" then
        if now - session.offered_at > offer_timeout and not update.discover then
          if session.tries < offer_retries then offer(update, session, now) else fail(session, "no answer to the offer") end
        end
      elseif session.state == "SENDING" then
        collect_acks(session, now)
        send_next_chunks(update, session, now)
        if session.state == "SENDING" and session.cursor_file > #session.need and session.inflight_count == 0 then
          local msg = send_cmd(session.node_id, "ota_commit", { update_id = update.id })
          if msg then session.state = "COMMITTING"; session.commit_at = now; session.progress_at = now else fail(session, "commit could not be sent") end
        elseif session.state == "SENDING" and now - session.progress_at > stall_timeout then
          fail(session, "transfer stalled")
        end
      elseif session.state == "COMMITTING" then
        if now - session.commit_at > result_timeout then fail(session, "no result after commit") end
      elseif session.state == "DONE" then
        if now - session.result_at > confirm_timeout then session.state = "UNCONFIRMED" end
      end
    end
  end

  function self.is_updating(node_id)
    local update = self.update
    local session = update and update.sessions[node_id]
    if not session then return false end
    if ACTIVE[session.state] then return true end
    if session.state == "DONE" or session.state == "UNCONFIRMED" then return now_ms() - (session.result_at or 0) <= reboot_grace end
    return false
  end

  -- include_done: a node that swapped its files (DONE) counts as finished; the master waits for the confirmation
  function self.finished(include_done)
    local update = self.update
    if not update then return true end
    if update.discover and now_ms() < (update.discover_until or 0) then return false end
    for _, id in ipairs(update.order) do
      local state = update.sessions[id].state
      if not (TERMINAL[state] or (include_done and state == "DONE")) then return false end
    end
    return true
  end

  function self.status()
    local out = {}
    local update = self.update
    if not update then return out end
    for _, id in ipairs(update.order) do
      local s = update.sessions[id]
      out[#out + 1] = { node_id = id, state = s.state, sent = s.sent or 0, acked = s.acked or 0, total = s.total or 0, error = s.error, version = s.version or update.version }
    end
    return out
  end

  function self.push_runtime(push_opts)
    local o = push_opts or {}
    local paths = o.files or list_files()
    local entries, read_errors = {}, {}
    for _, path in ipairs(paths) do
      local content, err = read(path)
      if content then entries[#entries + 1] = { path = path, content = content } else read_errors[#read_errors + 1] = path .. ": " .. tostring(err) end
    end
    if #read_errors > 0 then log("warn", "OTA read errors", { errors = read_errors }) end
    return self.push(entries, o)
  end

  function self.push_legacy(push_opts)
    local o = push_opts or {}
    local paths = o.files or ota_manager.node_closure(function(path) return (read(path)) end)
    local entries = {}
    for _, path in ipairs(paths) do
      local content = read(path)
      if content then entries[#entries + 1] = { path = path, content = content } end
    end
    local legacy_opts = {}
    for k, v in pairs(o) do legacy_opts[k] = v end
    legacy_opts.legacy = true
    return self.push(entries, legacy_opts)
  end

  function self.push(files, push_opts)
    local update, err = self.start(files, push_opts)
    local results = {}
    if not update then return results, err end
    for _, id in ipairs(update.order) do results[id] = { ok = update.sessions[id].state ~= "FAILED", error = update.sessions[id].error } end
    return results
  end

  function self.push_to(node_id, files, version)
    local update, err = self.start(files, { nodes = { node_id }, version = version })
    if not update then return false, err end
    return true
  end

  -- a reliable message that ran out of retries is reported to the manager as well as to whoever owned the callback before
  if network and not options.no_drop_hook then
    local previous = network.on_drop
    network.on_drop = function(msg)
      self.on_drop(msg)
      if previous then previous(msg) end
    end
  end

  return self
end

return ota_manager
