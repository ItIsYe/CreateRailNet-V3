--[[
Purpose: Build a runtime-only file list from configs/install/runtime_manifest.json.
Public API: load_manifest(path), matches(pattern, path), should_include(manifest, path), filter_files(manifest, files), run(args).
Notes: This is an offline packaging helper. It does not install files by itself.
]]

local json = require("src.shared.json")

local runtime_packager = {}

local DEFAULT_MANIFEST = "configs/install/runtime_manifest.json"

local function read_file(path)
  if io and io.open then
    local fh = io.open(path, "r")
    if fh then local body = fh:read("*a"); fh:close(); return body end
  end
  if fs and fs.open then
    local fh = fs.open(path, "r")
    if fh then local body = fh.readAll(); fh.close(); return body end
  end
  return nil, "cannot open " .. tostring(path)
end

local function write_file(path, body)
  if io and io.open then
    local fh = io.open(path, "w")
    if fh then fh:write(body); fh:close(); return true end
  end
  if fs and fs.open then
    local fh = fs.open(path, "w")
    if fh then fh.write(body); fh.close(); return true end
  end
  return false, "cannot write " .. tostring(path)
end

local function escape_lua_pattern(text)
  return (tostring(text):gsub("([%%%^%$%(%)%.%[%]%+%-%?])", "%%%1"))
end

function runtime_packager.load_manifest(path)
  local body, err = read_file(path or DEFAULT_MANIFEST)
  if not body then return nil, err end
  return json.decode(body)
end

function runtime_packager.matches(pattern, path)
  local p = tostring(pattern or "")
  local target = tostring(path or "")
  if p == target then return true end
  if string.sub(p, -3) == "/**" then
    local prefix = string.sub(p, 1, #p - 3)
    return target == prefix or string.sub(target, 1, #prefix + 1) == prefix .. "/"
  end
  if string.find(p, "*", 1, true) then
    local expr = "^" .. escape_lua_pattern(p):gsub("%%%*%%%*", ".*"):gsub("%%%*", "[^/]*") .. "$"
    return string.match(target, expr) ~= nil
  end
  return false
end

function runtime_packager.should_include(manifest, path)
  for _, exclude in ipairs((manifest and manifest.exclude) or {}) do
    if runtime_packager.matches(exclude, path) then return false, "excluded by " .. tostring(exclude) end
  end
  for _, include in ipairs((manifest and manifest.include) or {}) do
    if runtime_packager.matches(include, path) then return true, "included by " .. tostring(include) end
  end
  return false, "not included"
end

function runtime_packager.filter_files(manifest, files)
  local included = {}
  local excluded = {}
  for _, path in ipairs(files or {}) do
    local ok, reason = runtime_packager.should_include(manifest, path)
    if ok then table.insert(included, path) else table.insert(excluded, { path = path, reason = reason }) end
  end
  table.sort(included)
  table.sort(excluded, function(a, b) return a.path < b.path end)
  return included, excluded
end

function runtime_packager.write_file_list(path, files)
  return write_file(path, table.concat(files or {}, "\n") .. "\n")
end

function runtime_packager.run(args)
  local options = args or {}
  local manifest, err = runtime_packager.load_manifest(options.manifest or DEFAULT_MANIFEST)
  if not manifest then print("manifest load failed: " .. tostring(err)); return false, err end
  local files = options.files or {}
  local included, excluded = runtime_packager.filter_files(manifest, files)
  print("CreateRailNet Runtime Packager")
  print("included=" .. tostring(#included) .. " excluded=" .. tostring(#excluded))
  for _, path in ipairs(included) do print("IN  " .. path) end
  for _, row in ipairs(excluded) do print("OUT " .. row.path .. " # " .. row.reason) end
  if options.write then runtime_packager.write_file_list(options.write, included) end
  return true, included, excluded
end

return runtime_packager
