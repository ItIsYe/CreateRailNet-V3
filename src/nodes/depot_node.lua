--[[
Purpose: Depot node stub for future expansion.
Public API: none (script).
]]

local config = require("src.shared.config")

local function parse_args(argv)
  local args = {}
  for i = 1, #argv do
    if argv[i] == "--config" then
      args.config = argv[i + 1]
    elseif argv[i] == "--id" then
      args.id = argv[i + 1]
    end
  end
  return args
end

local args = parse_args({...})
config.load(args.config or "configs/templates/network.example.json")

-- Stub: depot logic will be added post-MVP.
