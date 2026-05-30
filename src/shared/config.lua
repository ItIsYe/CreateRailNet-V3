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

function config.load(path)
  local content = read_file(path)
  local data = json.decode(content)
  local ok, errors = validate.validate_config(data)
  if not ok then
    error("config validation failed:\n- " .. table.concat(errors, "\n- "))
  end
  return data
end

return config
