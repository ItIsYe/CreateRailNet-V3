--[[
Purpose: Load and validate JSON configuration.
Public API: load(path) -> config.
]]

local json = require("src.shared.json")
local validate = require("src.shared.validate")

local config = {}

local function read_file(path)
  if io and io.open then
    local fh = io.open(path, "r")
    if fh then
      local content = fh:read("*a")
      fh:close()
      return content
    end
  end

  if fs and fs.open then
    if fs.exists and not fs.exists(path) then
      error("config load failed: cannot open " .. tostring(path))
    end
    local ok, fh = pcall(fs.open, path, "r")
    if ok and fh then
      local content = fh.readAll and fh.readAll() or fh.read and fh.read("*a")
      fh.close()
      return content
    end
  end

  error("config load failed: cannot open " .. tostring(path))
end

-- load: returns config or raises error (use pcall for graceful handling)
-- Also available: config.try_load(path) -> ok, data_or_errors
function config.load(path)
  local ok_read, content = pcall(read_file, path)
  if not ok_read then
    error("config load failed: " .. tostring(content))
  end
  local ok_json, data = pcall(json.decode, content)
  if not ok_json then
    error("config JSON parse failed: " .. tostring(data))
  end
  local ok_valid, errors = validate.validate_config(data)
  if not ok_valid then
    error("config validation failed:\n- " .. table.concat(errors, "\n- "))
  end
  return data
end

function config.try_load(path)
  local ok, result = pcall(config.load, path)
  if ok then return true, result end
  return false, result
end

return config
