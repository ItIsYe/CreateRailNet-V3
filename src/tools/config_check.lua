--[[
Purpose: CLI helper to validate a CreateRailNet config ingame.
Usage: require("src.tools.config_check").run("configs/templates/network.full.example.json")
]]

local config = require("src.shared.config")
local validate = require("src.shared.validate")

local config_check = {}

function config_check.run(path)
  local cfg_path = path or "configs/templates/network.full.example.json"
  print("Validating " .. cfg_path)
  local ok_load, cfg_or_err = pcall(config.load, cfg_path)
  if not ok_load then
    print("LOAD FAIL: " .. tostring(cfg_or_err))
    return false
  end
  local ok, errors = validate.validate_config(cfg_or_err)
  if ok then
    print("CONFIG OK")
    return true
  end
  print("CONFIG FAIL")
  for _, err in ipairs(errors or {}) do print("- " .. tostring(err)) end
  return false, errors
end

local args = {...}
if #args > 0 then config_check.run(args[1]) end

return config_check
