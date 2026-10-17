--[[
Purpose: Persistent master state store for dispatcher recovery snapshots.
Public API: new(path) -> store with save(snapshot), load(), clear(), exists().
Notes: Stores JSON only; callers decide when a snapshot is safe to save.
  Writes go through shared.safe_write (verify, .prev backup, rollback). load() falls back to path.prev when the
  primary file is missing or corrupt, and reports which copy was used in payload.loaded_from.
]]

local time = require("src.shared.time")
local json = require("src.shared.json")
local safe_write = require("src.shared.safe_write")

local master_state_store = {}

local DEFAULT_PATH = "state/master_state.json"

local function delete_file(path)
  if fs and fs.delete then
    if fs.exists and fs.exists(path) then fs.delete(path) end
    return true
  end
  if os and os.remove then os.remove(path); return true end
  return false, "no delete API available"
end

local function file_exists(path)
  if fs and fs.exists then return fs.exists(path) end
  if io and io.open then local fh = io.open(path, "r"); if fh then fh:close(); return true end end
  return false
end

local function decode(body)
  local ok, decoded = pcall(json.decode, body)
  if not ok then return nil, decoded end
  if type(decoded) ~= "table" then return nil, "invalid master state" end
  return decoded
end

function master_state_store.new(path)
  local self = { path = path or DEFAULT_PATH }

  function self.exists()
    return file_exists(self.path) or file_exists(safe_write.backup_path(self.path))
  end

  function self.save(snapshot)
    local payload = { version = 1, saved_at = os.time and time.now_s() or 0, dispatcher = snapshot }
    return safe_write.write(self.path, json.encode(payload))
  end

  function self.load()
    local body, read_err = safe_write.read(self.path)
    local decoded, decode_err
    if body then
      decoded, decode_err = decode(body)
      if decoded then decoded.loaded_from = "primary" end
    end
    if not decoded then
      local prev = safe_write.read(safe_write.backup_path(self.path))
      if prev then
        decoded = decode(prev)
        if decoded then decoded.loaded_from = "backup" end
      end
    end
    if not decoded then return nil, decode_err or read_err end
    return decoded.dispatcher, decoded
  end

  function self.clear()
    delete_file(safe_write.backup_path(self.path))
    delete_file(self.path .. ".tmp")
    return delete_file(self.path)
  end

  return self
end

master_state_store.DEFAULT_PATH = DEFAULT_PATH

return master_state_store
