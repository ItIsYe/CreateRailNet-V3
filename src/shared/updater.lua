--[[
Purpose: Node side of the over-the-air (OTA) update: offer/need/chunk/commit transfer, verification, swap with rollback.
Public API:
  new(network, node_id, logger, opts) -> updater
    opts: verify_package(package, offer) -> true | false, code, detail (optional: src/shared/update_package.lua), fs, sources (list of allowed sender ids), quiesce() -> ok, err, reboot(), sleep(seconds), max_files, max_bytes
  updater.offer(payload, src)    manifest of the new version -> true | false, err; answers with ota_need (or ota_result when current)
  updater.chunk(payload, src)    one piece of a needed file -> true | false, err (a damaged file is answered with ota_need, true)
  updater.commit(payload, src)   all pieces staged: quiesce, swap, trial boot journal, reboot -> true | false, err
  updater.abort(payload, src)    drop the session and its staged files
  updater.apply(payload, src)    single-message update with {path, content} entries (older senders)
  updater.confirm_boot()         the new code started fine: drop backups and journal
  updater.valid_path(path) -> boolean
  updater.recover is src/shared/ota_recovery.lua, called from startup.lua before anything else is loaded.

Protocol (master or OTA tool -> node, all reliable):
  ota_offer  { update_id, version, files = { {path, size, adler} } }         node answers event ota_need { update_id, need = {paths} }
  ota_chunk  { update_id, path, index, total, data }                          acked per chunk
  ota_commit { update_id }                                                    node answers event ota_result { update_id, success, errors }
  ota_abort  { update_id }
Only files that differ (size or Adler-32) are requested, so a rollout moves only what changed. A node never swaps files
before every needed file arrived, verified, and was staged as <path>.ota_new. Swap order per file: backup <path>.ota_bak,
delete, move. A journal (ota_journal.txt) lets src/shared/ota_recovery.lua undo a half-done swap after a crash, and undo a
whole update whose first boot never confirmed.
]]

local checksum = require("src.shared.checksum")
local safe_write = require("src.shared.safe_write")
local ota_recovery = require("src.shared.ota_recovery")
local sleep_guard = require("src.shared.sleep_guard")

local updater = {}

local MAX_FILES = 400
local MAX_FILE_BYTES = 200000
local MAX_TOTAL_BYTES = 3000000
local MAX_PARTS = 64
local VERSION_FILE = "crn_version.txt"

local ALLOWED_PREFIXES = { "src/", "scripts/", "configs/templates/" }
-- startup.lua is not listed: it holds the role, id and config of each computer and must never be replaced remotely
local ALLOWED_FILES = {}

function updater.valid_path(path)
  if type(path) ~= "string" or #path == 0 or #path > 120 then return false end
  if not path:match("^[%w_%-%./]+$") then return false end
  if path:find("..", 1, true) or path:find("//", 1, true) or path:sub(1, 1) == "/" or path:sub(-1) == "/" then return false end
  if not (path:match("%.lua$") or path:match("%.json$")) then return false end
  if path:match("%.ota_") then return false end
  if ALLOWED_FILES[path] then return true end
  for _, prefix in ipairs(ALLOWED_PREFIXES) do
    if path:sub(1, #prefix) == prefix then return true end
  end
  return false
end

local function validate_manifest(files, max_files, max_bytes)
  if type(files) ~= "table" or #files == 0 then return nil, "manifest is empty" end
  if #files > max_files then return nil, "too many files: " .. #files end
  local manifest, total = {}, 0
  for i, entry in ipairs(files) do
    if type(entry) ~= "table" or not updater.valid_path(entry.path) then return nil, "entry " .. i .. ": path not allowed: " .. tostring(entry and entry.path) end
    if manifest[entry.path] then return nil, "entry " .. i .. ": duplicate path " .. entry.path end
    if type(entry.size) ~= "number" or entry.size < 0 or entry.size > MAX_FILE_BYTES or entry.size % 1 ~= 0 then return nil, entry.path .. ": bad size" end
    if type(entry.adler) ~= "number" or entry.adler < 0 or entry.adler > 4294967295 or entry.adler % 1 ~= 0 then return nil, entry.path .. ": bad checksum" end
    total = total + entry.size
    if total > max_bytes then return nil, "update too large" end
    manifest[entry.path] = { size = entry.size, adler = entry.adler }
  end
  return manifest
end

function updater.new(network, node_id, logger, opts)
  local options = opts or {}
  local fsys = options.fs or _G.fs
  local self = {}
  local session = nil

  local max_files = options.max_files or MAX_FILES
  local max_bytes = options.max_bytes or MAX_TOTAL_BYTES
  local sleep = options.sleep or function(seconds) if os.sleep then sleep_guard.sleep(seconds) end end
  local reboot = options.reboot or function() if os.reboot then os.reboot() end end

  local function log(level, text, data)
    if logger and logger[level] then logger[level](text, data) end
  end

  local function allowed_source(src)
    if not options.sources or #options.sources == 0 then return true end
    for _, id in ipairs(options.sources) do if id == src then return true end end
    return false
  end

  local function read(path)
    if not fsys.exists(path) then return nil end
    local fh = fsys.open(path, "r")
    if not fh then return nil end
    local body = fh.readAll()
    fh.close()
    return body
  end

  local function exists(path) return fsys.exists(path) end
  local function remove(path) if fsys.exists(path) then fsys.delete(path) end end

  local function staged_path(path) return path .. ota_recovery.NEW_SUFFIX end

  local function drop_session()
    if not session then return end
    for path in pairs(session.manifest) do
      remove(staged_path(path)); remove(staged_path(path) .. ".tmp")
    end
    remove(staged_path(VERSION_FILE)); remove(staged_path(VERSION_FILE) .. ".tmp")
    remove(ota_recovery.STAGE_LIST)
    session = nil
  end

  local function send(src, event_type, payload)
    payload.type = event_type
    payload.node_id = node_id
    if network then return network.send_reliable("event", src, payload) end
  end

  local function fail(src, update_id, errors)
    log("warn", "OTA failed", { update_id = update_id, errors = errors })
    send(src, "ota_result", { update_id = update_id, success = false, errors = errors })
  end

  -- true when the journal of an earlier update is still there: its first boot never confirmed or a swap is unfinished
  local function update_pending()
    return ota_recovery.read_journal(fsys) ~= nil
  end

  function self.session_id() return session and session.id or nil end

  function self.offer(payload, src)
    if not allowed_source(src) then return false, "source not allowed: " .. tostring(src) end
    if type(payload) ~= "table" or type(payload.update_id) ~= "string" then return false, "missing update_id" end
    if session and session.id ~= payload.update_id then drop_session() end
    if update_pending() then
      fail(src, payload.update_id, { "an earlier update is not confirmed yet" })
      return false, "earlier update pending"
    end
    local manifest, err = validate_manifest(payload.files, max_files, max_bytes)
    if not manifest then
      fail(src, payload.update_id, { err })
      return false, err
    end
    -- a node that holds the release key checks the origin proof, role, protocol, schema and space of the package before it asks for a single file
    if options.verify_package then
      local package_ok, code, detail = options.verify_package(payload.package, payload)
      if not package_ok then
        fail(src, payload.update_id, { "package refused: " .. tostring(code) .. (detail and (" (" .. tostring(detail) .. ")") or "") })
        return false, "package refused: " .. tostring(code)
      end
    end

    local need = {}
    for path, want in pairs(manifest) do
      local current = read(path)
      if not (current and #current == want.size and checksum.adler32(current) == want.adler) then need[#need + 1] = path end
    end
    table.sort(need)

    if #need == 0 then
      session = nil
      send(src, "ota_result", { update_id = payload.update_id, success = true, up_to_date = true, version = payload.version, files = 0 })
      return true
    end

    session = { id = payload.update_id, version = tostring(payload.version or "unknown"), src = src, manifest = manifest, need = need, staged = {}, parts = {} }
    for _, path in ipairs(need) do session.staged[path] = false end
    local listed = {}
    for _, path in ipairs(need) do listed[#listed + 1] = path end
    listed[#listed + 1] = VERSION_FILE
    ota_recovery.write_stage_list(fsys, listed)
    send(src, "ota_need", { update_id = payload.update_id, need = need })
    return true
  end

  local function missing_paths()
    local missing = {}
    for _, path in ipairs(session.need) do if not session.staged[path] then missing[#missing + 1] = path end end
    return missing
  end

  function self.chunk(payload, src)
    if not allowed_source(src) then return false, "source not allowed: " .. tostring(src) end
    if not session or type(payload) ~= "table" or payload.update_id ~= session.id then return false, "no such update" end
    local want = session.manifest[payload.path]
    if not want or session.staged[payload.path] == nil then return false, "file not requested: " .. tostring(payload.path) end
    local index, total = payload.index, payload.total
    if type(index) ~= "number" or type(total) ~= "number" or total < 1 or total > MAX_PARTS or index < 1 or index > total or type(payload.data) ~= "string" then
      return false, "bad chunk"
    end
    if session.staged[payload.path] then return true end

    local parts = session.parts[payload.path]
    if not parts or parts.total ~= total then parts = { total = total, count = 0, data = {} }; session.parts[payload.path] = parts end
    if not parts.data[index] then parts.data[index] = payload.data; parts.count = parts.count + 1 end
    if parts.count < parts.total then return true end

    local body = table.concat(parts.data, "", 1, parts.total)
    session.parts[payload.path] = nil
    if #body ~= want.size or checksum.adler32(body) ~= want.adler then
      -- damaged on the way: ask for the file again
      send(session.src, "ota_need", { update_id = session.id, need = missing_paths(), reason = "checksum mismatch for " .. payload.path })
      return true, "damaged, asked again: " .. payload.path
    end
    local ok, err = safe_write.write(staged_path(payload.path), body, { fs = fsys, keep_backup = false })
    if not ok then return false, "staging failed for " .. payload.path .. ": " .. tostring(err) end
    session.staged[payload.path] = true
    return true
  end

  -- backup, delete, move for every staged file; the journal lets recovery undo any prefix of this
  local function swap(entries, version)
    local journal = { state = "applying", boots = 0, version = version, files = entries.meta }
    local ok, err = ota_recovery.write_journal(fsys, journal)
    if not ok then return false, err end
    for _, path in ipairs(entries.paths) do
      if exists(path) then
        local old = read(path)
        local saved, save_err = safe_write.write(path .. ota_recovery.BACKUP_SUFFIX, old, { fs = fsys, keep_backup = false })
        if not saved then return false, "backup failed for " .. path .. ": " .. tostring(save_err) end
        fsys.delete(path)
      end
      fsys.move(staged_path(path), path)
      if not exists(path) then return false, "move failed for " .. path end
    end
    journal.state = "trial"
    local trial_ok, trial_err = ota_recovery.write_journal(fsys, journal)
    if not trial_ok then return false, trial_err end
    return true
  end

  -- files: path -> body already staged as <path>.ota_new, version: text for crn_version.txt
  local function run_commit(src, update_id, paths, version)
    local ok_quiesce, quiesce_err = true, nil
    if options.quiesce then ok_quiesce, quiesce_err = options.quiesce() end
    if ok_quiesce == false then
      drop_session()
      fail(src, update_id, { "quiesce failed: " .. tostring(quiesce_err) })
      return false, "quiesce failed"
    end

    local version_staged = safe_write.write(staged_path(VERSION_FILE), tostring(version), { fs = fsys, keep_backup = false })
    if not version_staged then
      drop_session()
      fail(src, update_id, { "cannot stage version file" })
      return false, "version staging failed"
    end

    local entries = { paths = {}, meta = {} }
    for _, path in ipairs(paths) do entries.paths[#entries.paths + 1] = path end
    entries.paths[#entries.paths + 1] = VERSION_FILE
    for _, path in ipairs(entries.paths) do
      local old = read(path)
      entries.meta[#entries.meta + 1] = { path = path, had_old = old ~= nil, old_size = old and #old or 0, old_adler = old and checksum.adler32(old) or 0 }
    end

    local ran, swapped, swap_err = pcall(swap, entries, tostring(version))
    if not (ran and swapped) then
      local reason = ran and tostring(swap_err) or tostring(swapped)
      local action, detail = ota_recovery.recover(fsys)
      log("error", "OTA swap failed, rolled back", { reason = reason, recovery = action, detail = detail })
      drop_session()
      fail(src, update_id, { "swap failed: " .. reason, "recovery: " .. tostring(action) })
      return false, "swap failed"
    end

    session = nil
    log("info", "OTA applied, rebooting", { version = version, files = #paths })
    send(src, "ota_result", { update_id = update_id, success = true, version = version, files = #paths })
    sleep(0.5)
    reboot()
    return true
  end

  function self.commit(payload, src)
    if not allowed_source(src) then return false, "source not allowed: " .. tostring(src) end
    if not session or type(payload) ~= "table" or payload.update_id ~= session.id then return false, "no such update" end
    local missing = missing_paths()
    if #missing > 0 then
      send(session.src, "ota_need", { update_id = session.id, need = missing, reason = "commit before all files arrived" })
      return false, "incomplete: " .. #missing .. " files missing"
    end
    return run_commit(session.src, session.id, session.need, session.version)
  end

  function self.abort(payload, src)
    if not allowed_source(src) then return false, "source not allowed: " .. tostring(src) end
    if session and (type(payload) ~= "table" or payload.update_id == session.id) then drop_session() end
    return true
  end

  -- single-message update: payload.files = { {path, content, adler?} }
  function self.apply(payload, src)
    if not allowed_source(src) then return false, "source not allowed: " .. tostring(src) end
    if type(payload) ~= "table" or type(payload.files) ~= "table" then return false, "invalid payload: missing files table" end
    local update_id = tostring(payload.update_id or "single")
    local manifest_list, contents = {}, {}
    for i, entry in ipairs(payload.files) do
      if type(entry) ~= "table" or type(entry.path) ~= "string" or type(entry.content) ~= "string" then
        fail(src, update_id, { "entry " .. i .. ": missing path or content" })
        return false, "entry " .. i .. ": missing path or content"
      end
      local adler = checksum.adler32(entry.content)
      if entry.adler and entry.adler ~= adler then
        fail(src, update_id, { entry.path .. ": checksum mismatch" })
        return false, "checksum mismatch"
      end
      manifest_list[i] = { path = entry.path, size = #entry.content, adler = adler }
      contents[entry.path] = entry.content
    end
    local manifest, err = validate_manifest(manifest_list, max_files, max_bytes)
    if not manifest then fail(src, update_id, { err }); return false, err end
    if update_pending() then fail(src, update_id, { "an earlier update is not confirmed yet" }); return false, "earlier update pending" end

    if session then drop_session() end
    session = { id = update_id, version = tostring(payload.version or "unknown"), src = src, manifest = manifest, need = {}, staged = {}, parts = {} }
    local listed = { VERSION_FILE }
    for _, item in ipairs(manifest_list) do listed[#listed + 1] = item.path end
    ota_recovery.write_stage_list(fsys, listed)
    for _, item in ipairs(manifest_list) do
      local ok, stage_err = safe_write.write(staged_path(item.path), contents[item.path], { fs = fsys, keep_backup = false })
      if not ok then drop_session(); fail(src, update_id, { "staging failed for " .. item.path .. ": " .. tostring(stage_err) }); return false, "staging failed" end
      session.need[#session.need + 1] = item.path
      session.staged[item.path] = true
    end
    return run_commit(src, update_id, session.need, session.version)
  end

  function self.confirm_boot()
    return ota_recovery.confirm(fsys)
  end

  return self
end

return updater
