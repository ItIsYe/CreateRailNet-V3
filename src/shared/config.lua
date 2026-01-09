--[[
Purpose: Load and validate JSON configuration.
Public API: load(path) -> config.
]]

local json = require("src.shared.json")
local validate = require("src.shared.validate")

local config = {}

function config.load(path)
  local fh = io.open(path, "r")
  if not fh then
    error("config load failed: cannot open " .. path)
  end
  local content = fh:read("*a")
  fh:close()
  local data = json.decode(content)
  local ok, errors = validate.validate_config(data)
  if not ok then
    error("config validation failed:\n- " .. table.concat(errors, "\n- "))
  end
  return data
end

return config
