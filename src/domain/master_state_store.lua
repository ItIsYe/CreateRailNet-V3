--[[
Purpose: Persistent master state store for dispatcher recovery snapshots.
Public API: new(path) -> store with save(snapshot), load(), clear(), exists().
Notes: Stores JSON only; callers decide when a snapshot is safe to save.
]]

local time = require("src.shared.time")

local json = require("src.shared.json")

local master_state_store = {}

local DEFAULT_PATH = "state/master_state.json"

local function dirname(path)
  local dir = tostring(path or ""):match("^(.*)/[^/]+$")
  if dir == "" then return nil end
  return dir
end

local function ensure_dir(path)
  local dir = dirname(path)
  if not dir then return true end
  if fs and fs.exists and fs.makeDir then
    if not fs.exists(dir) then fs.makeDir(dir) end
  end
  return true
end

local function read_file(path)
  if fs and fs.open then
    if fs.exists and not fs.exists(path) then return nil, "missing" end
    local fh = fs.open(path, "r")
    if not fh then return nil, "cannot open " .. tostring(path) end
    local body = fh.readAll()
    fh.close()
    return body
  end
  if io and io.open then
    local fh = io.open(path, "r")
    if not fh then return nil, "missing" end
    local body = fh:read("*a")
    fh:close()
    return body
  end
  return nil, "no file API available"
end

local function write_file(path, body)
  ensure_dir(path)
  -- Atomic write: write to temp file first, then rename/replace
  -- This prevents corruption if the computer crashes mid-write
  local tmp = path .. ".tmp"
  if fs and fs.open then
    local fh = fs.open(tmp, "w")
    if not fh then return false, "cannot open tmp " .. tostring(tmp) end
    fh.write(body)
    fh.close()
    if fs.exists and fs.exists(path) then fs.delete(path) end
    fs.move(tmp, path)
    return true
  end
  if io and io.open then
    local fh = io.open(tmp, "w")
    if not fh then return false, "cannot open tmp " .. tostring(tmp) end
    fh:write(body)
    fh:close()
    os.rename(tmp, path)
    return true
  end
  return false, "no file API available"
end

local function delete_file(path)
  if fs and fs.delete then
    if fs.exists and fs.exists(path) then fs.delete(path) end
    return true
  end
  if os and os.remove then os.remove(path); return true end
  return false, "no delete API available"
end

function master_state_store.new(path)
  local self = { path = path or DEFAULT_PATH }

  function self.exists()
    if fs and fs.exists then return fs.exists(self.path) end
    if io and io.open then local fh = io.open(self.path, "r"); if fh then fh:close(); return true end end
    return false
  end

  function self.save(snapshot)
    local payload = { version = 1, saved_at = os.time and time.now_s() or 0, dispatcher = snapshot }
    local body = json.encode(payload)
    return write_file(self.path, body)
  end

  function self.load()
    local body, err = read_file(self.path)
    if not body then return nil, err end
    local ok, decoded = pcall(json.decode, body)
    if not ok then return nil, decoded end
    if type(decoded) ~= "table" then return nil, "invalid master state" end
    return decoded.dispatcher, decoded
  end

  function self.clear()
    return delete_file(self.path)
  end

  return self
end

master_state_store.DEFAULT_PATH = DEFAULT_PATH

return master_state_store

