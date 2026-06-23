--[[
Purpose: Master-side OTA update manager. Reads source files and pushes them to
         all or specific nodes via reliable modem messages.

Public API:
  new(network, registry, logger) -> manager
  manager.push(files, opts)         -> {node_id -> {ok, errors}}
  manager.push_to(node_id, files)   -> ok, err
  manager.push_runtime(opts)        -> {node_id -> {ok, errors}}
    opts.nodes     = list of node_ids (nil = all registered)
    opts.version   = version string (default = timestamp)
    opts.files     = explicit file list (nil = auto from manifest)
]]

local time = require("src.shared.time")

local ota_manager = {}

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

local RUNTIME_DIRS = {
  "src/shared/",
  "src/domain/",
  "src/adapter/",
  "src/master/",
  "src/nodes/",
}

local function collect_lua_files(dirs)
  local files = {}
  if not fs then return files, "no fs API" end
  for _, dir in ipairs(dirs) do
    if fs.exists and fs.exists(dir) then
      local function scan(d)
        for _, name in ipairs(fs.list and fs.list(d) or {}) do
          local full = d .. name
          if fs.isDir and fs.isDir(full) then
            scan(full .. "/")
          elseif name:match("%.lua$") then
            table.insert(files, full)
          end
        end
      end
      scan(dir)
    end
  end
  return files
end

function ota_manager.new(network, registry, logger)
  local self = {}

  -- Push a list of {path, content} file entries to a single node.
  function self.push_to(node_id, file_entries, version)
    if not network then return false, "no network" end
    local ver = version or tostring(time.now_s())
    local msg = network.send_reliable("cmd", node_id, {
      cmd = "ota_update",
      type = "ota_update",
      files = file_entries,
      version = ver,
      file_count = #file_entries
    })
    if not msg then return false, "send failed" end
    if logger then
      logger.info("OTA push sent", {
        dst = node_id,
        files = #file_entries,
        version = ver
      })
    end
    return true
  end

  -- Push to multiple nodes. nodes = list of node_ids or nil for all registered.
  function self.push(file_entries, opts)
    local options = opts or {}
    local version = options.version or tostring(time.now_s())
    local results = {}

    local targets = options.nodes
    if not targets then
      targets = {}
      if registry and registry.all then
        for node_id, _ in pairs(registry.all()) do
          table.insert(targets, node_id)
        end
      end
    end

    if logger then
      logger.info("OTA push starting", {
        nodes = #targets,
        files = #file_entries,
        version = version
      })
    end

    for _, node_id in ipairs(targets) do
      local ok, err = self.push_to(node_id, file_entries, version)
      results[node_id] = { ok = ok, error = err }
    end

    return results
  end

  -- Convenience: read runtime src/ files from disk and push to nodes.
  function self.push_runtime(opts)
    local options = opts or {}
    local version = options.version or tostring(time.now_s())

    -- Collect files
    local paths = options.files
    if not paths then
      local errs = {}
      paths, errs = collect_lua_files(RUNTIME_DIRS)
      if logger and errs and errs ~= {} then
        logger.warn("OTA collect errors", { error = tostring(errs) })
      end
    end

    -- Also include scripts/
    if not options.no_scripts and fs and fs.exists and fs.exists("scripts/") then
      for _, name in ipairs(fs.list and fs.list("scripts/") or {}) do
        if name:match("%.lua$") then
          table.insert(paths, "scripts/" .. name)
        end
      end
    end

    -- Read all file contents
    local file_entries = {}
    local read_errors = {}
    for _, path in ipairs(paths) do
      local content, err = read_file(path)
      if content then
        table.insert(file_entries, { path = path, content = content })
      else
        table.insert(read_errors, path .. ": " .. tostring(err))
      end
    end

    if #read_errors > 0 and logger then
      logger.warn("OTA read errors", { errors = read_errors })
    end

    if #file_entries == 0 then
      return {}, "no files to push"
    end

    return self.push(file_entries, {
      nodes = options.nodes,
      version = version
    })
  end

  return self
end

return ota_manager
