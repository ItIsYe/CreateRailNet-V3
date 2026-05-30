--[[
Purpose: Read-only redstone side report for signal/sensor/switch bindings.
Public API: build(config_path), run(args).
]]

local config = require("src.shared.config")

local redstone_report = {}

local SIDES = { "left", "right", "top", "bottom", "front", "back" }
local SIDE_SET = { left = true, right = true, top = true, bottom = true, front = true, back = true }

local function read_side(side)
  local input = nil
  local output = nil
  if redstone and redstone.getInput then
    local ok, value = pcall(redstone.getInput, side)
    if ok then input = value end
  end
  if redstone and redstone.getOutput then
    local ok, value = pcall(redstone.getOutput, side)
    if ok then output = value end
  end
  return input, output
end

function redstone_report.build(config_path)
  local cfg = config.load(config_path or "configs/templates/network.full.example.json")
  local rows = {}
  for _, node in ipairs(cfg.nodes or {}) do
    if node.adapter == "redstone" or SIDE_SET[node.side] then
      local input, output = read_side(node.side)
      table.insert(rows, { id = node.id, role = node.role, side = node.side, side_valid = SIDE_SET[node.side] == true, input = input, output = output })
    end
  end
  return { config = config_path, rows = rows }
end

function redstone_report.run(args)
  local path = args and args.config or args and args[1] or "configs/templates/network.full.example.json"
  local built = redstone_report.build(path)
  print("CreateRailNet Redstone Side Report")
  for _, row in ipairs(built.rows) do print(tostring(row.id) .. " role=" .. tostring(row.role) .. " side=" .. tostring(row.side or "-") .. " valid=" .. tostring(row.side_valid) .. " in=" .. tostring(row.input) .. " out=" .. tostring(row.output)) end
  print("Known sides: " .. table.concat(SIDES, ", "))
  return built
end

return redstone_report
