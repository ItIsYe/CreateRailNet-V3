--[[
Purpose: Validate a CreateRailNet config ingame or in tests.
Usage: require("src.tools.check_config").run({ config = "configs/templates/network.full.example.json" })
]]

local config = require("src.shared.config")
local validate = require("src.shared.validate")

local check_config = {}

function check_config.check(path)
  local cfg = config.load(path or "configs/templates/network.full.example.json")
  local ok, errors = validate.validate_config(cfg)
  return ok, errors, cfg
end

function check_config.run(args)
  local path = args and args.config or args and args[1] or "configs/templates/network.full.example.json"
  print("CreateRailNet config check: " .. tostring(path))
  local ok, errors = check_config.check(path)
  if ok then
    print("OK")
    return true
  end
  print("FAILED")
  for _, err in ipairs(errors or {}) do print("- " .. tostring(err)) end
  return false
end

local raw = {...}
if #raw > 0 then check_config.run({ config = raw[1] }) end

return check_config
