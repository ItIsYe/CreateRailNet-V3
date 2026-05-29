--[[
Purpose: Produce a readable diagnosis report for a CreateRailNet config.
Usage: require("src.tools.diagnose_config").run({ config = "configs/templates/network.full.example.json" })
]]

local config = require("src.shared.config")
local validate = require("src.shared.validate")

local diagnose = {}

local function count(items)
  local n = 0
  for _ in ipairs(items or {}) do n = n + 1 end
  return n
end

local function role_counts(nodes)
  local out = {}
  for _, node in ipairs(nodes or {}) do out[node.role or "unknown"] = (out[node.role or "unknown"] or 0) + 1 end
  return out
end

function diagnose.build(path)
  local cfg = config.load(path or "configs/templates/network.full.example.json")
  local ok, errors = validate.validate_config(cfg)
  local roles = role_counts(cfg.nodes)
  local lines = {}
  table.insert(lines, "CreateRailNet Diagnosis")
  table.insert(lines, "Config valid: " .. tostring(ok))
  table.insert(lines, "Nodes: " .. tostring(count(cfg.nodes)))
  table.insert(lines, "Blocks: " .. tostring(count(cfg.blocks)))
  table.insert(lines, "Routes: " .. tostring(count(cfg.routes)))
  table.insert(lines, "Service plans: " .. tostring(count(cfg.service_plans or cfg.schedules)))
  table.insert(lines, "Roles:")
  for role, n in pairs(roles) do table.insert(lines, "  " .. tostring(role) .. ": " .. tostring(n)) end
  if not ok then
    table.insert(lines, "Errors:")
    for _, err in ipairs(errors or {}) do table.insert(lines, "  - " .. tostring(err)) end
  end
  table.insert(lines, "Hints:")
  table.insert(lines, "  - Run peripheral_inspector on every computer before binding Create hardware.")
  table.insert(lines, "  - Verify all redstone sides match the physical computer orientation.")
  table.insert(lines, "  - Keep one shared channel across all nodes in one rail network.")
  return lines, ok
end

function diagnose.run(args)
  local path = args and args.config or args and args[1] or "configs/templates/network.full.example.json"
  local lines = diagnose.build(path)
  for _, line in ipairs(lines) do print(line) end
end

local raw = {...}
if #raw > 0 then diagnose.run({ config = raw[1] }) end

return diagnose
