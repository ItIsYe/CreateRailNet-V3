--[[
Purpose: Compare config hardware bindings against visible CC peripherals without changing outputs.
Public API: build(config_path), run(args).
]]

local config = require("src.shared.config")
local inspector = require("src.tools.peripheral_inspector")

local report = {}

local SIDES = { left = true, right = true, top = true, bottom = true, front = true, back = true }

local function node_binding(node)
  return node.peripheral or node.side or node.monitor or node.modem
end

local function present_names()
  local out = {}
  if peripheral and peripheral.getNames then
    for _, name in ipairs(peripheral.getNames()) do out[name] = true end
  else
    for side in pairs(SIDES) do
      if peripheral and peripheral.isPresent and peripheral.isPresent(side) then out[side] = true end
    end
  end
  return out
end

function report.build(config_path)
  local cfg = config.load(config_path or "configs/templates/network.full.example.json")
  local present = present_names()
  local rows = {}
  for _, node in ipairs(cfg.nodes or {}) do
    local binding = node_binding(node)
    local exists = binding and (SIDES[binding] or present[binding]) or false
    local info = binding and inspector.inspect(binding) or nil
    table.insert(rows, {
      id = node.id,
      role = node.role,
      binding = binding,
      exists = exists == true,
      type = info and info.type or nil,
      method_count = info and info.method_count or nil,
      warning = binding and nil or "no binding field"
    })
  end
  return { config = config_path, rows = rows }
end

function report.run(args)
  local path = args and args.config or args and args[1] or "configs/templates/network.full.example.json"
  local built = report.build(path)
  print("CreateRailNet Hardware Binding Report")
  for _, row in ipairs(built.rows) do
    print(tostring(row.id) .. " role=" .. tostring(row.role) .. " binding=" .. tostring(row.binding or "-") .. " exists=" .. tostring(row.exists) .. " type=" .. tostring(row.type or "-"))
    if row.warning then print("  warn: " .. row.warning) end
  end
  return built
end

local raw = {...}
if raw and #raw > 0 then report.run({ config = raw[1] }) end

return report
