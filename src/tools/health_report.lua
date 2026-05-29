--[[
Purpose: Print a static config-oriented health report before runtime.
Usage: require("src.tools.health_report").run({ config = "configs/templates/network.full.example.json" })
]]

local config = require("src.shared.config")
local validate = require("src.shared.validate")

local health_report = {}

local function count_array(t)
  local n = 0
  for _ in ipairs(t or {}) do n = n + 1 end
  return n
end

local function role_counts(nodes)
  local out = {}
  for _, node in ipairs(nodes or {}) do
    local role = node.role or "unknown"
    out[role] = (out[role] or 0) + 1
  end
  return out
end

function health_report.build(path)
  local cfg = config.load(path or "configs/templates/network.full.example.json")
  local ok, errors = validate.validate_config(cfg)
  return {
    ok = ok,
    errors = errors or {},
    counts = {
      nodes = count_array(cfg.nodes),
      blocks = count_array(cfg.blocks),
      routes = count_array(cfg.routes),
      service_plans = count_array(cfg.service_plans or cfg.schedules)
    },
    roles = role_counts(cfg.nodes),
    channel = cfg.channel,
    master_id = cfg.master_id
  }
end

function health_report.run(args)
  local path = args and args.config or args and args[1] or "configs/templates/network.full.example.json"
  local report = health_report.build(path)
  print("CreateRailNet Health Report")
  print("ok=" .. tostring(report.ok))
  print("master=" .. tostring(report.master_id) .. " channel=" .. tostring(report.channel))
  print("nodes=" .. report.counts.nodes .. " blocks=" .. report.counts.blocks .. " routes=" .. report.counts.routes .. " service_plans=" .. report.counts.service_plans)
  print("roles:")
  for role, n in pairs(report.roles) do print("  " .. role .. "=" .. tostring(n)) end
  if not report.ok then
    print("errors:")
    for _, err in ipairs(report.errors) do print("  - " .. tostring(err)) end
  end
  return report.ok, report
end

local raw = {...}
if #raw > 0 then health_report.run({ config = raw[1] }) end

return health_report
