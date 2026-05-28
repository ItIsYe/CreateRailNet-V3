--[[
Purpose: Shared bootstrap for node role entrypoints.
Public API: create_context(argv, role) -> context table.
]]

local shared_args = require("src.shared.args")
local config = require("src.shared.config")
local log = require("src.shared.log")
local peripherals = require("src.adapter.peripherals")
local hardware_config = require("src.adapter.hardware_config")
local cc_modem = require("src.adapter.cc_modem")

local bootstrap = {}

function bootstrap.create_context(argv, role)
  local parsed = shared_args.parse(argv or {}, { config = {}, id = {} })
  if not parsed.id or parsed.id == "" then
    error("missing required --id for " .. tostring(role) .. " node")
  end

  local cfg = config.load(parsed.config or "configs/templates/network.example.json")
  local logger = log.new("INFO", 200)
  local peri = peripherals.new()
  local hw = hardware_config.new(cfg)
  local modem = cc_modem.new({ channel = cfg.channel })

  return {
    args = parsed,
    id = parsed.id,
    role = role,
    config = cfg,
    logger = logger,
    peripherals = peri,
    hardware = hw,
    modem = modem
  }
end

return bootstrap
