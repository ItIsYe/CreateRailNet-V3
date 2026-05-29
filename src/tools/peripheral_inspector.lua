--[[
Purpose: Ingame helper to inspect CC:Tweaked peripherals and method names safely.
Public API: inspect(name), scan(), find_methods(patterns), write_report(path, report), run(args).
]]

local json = require("src.shared.json")

local inspector = {}

local DEFAULT_SIDES = { "left", "right", "top", "bottom", "front", "back" }
local CREATE_HINTS = { "train", "schedule", "station", "track", "signal", "switch", "speed", "destination", "assemble" }

local function print_line(text)
  print(tostring(text))
end

local function sort_list(list)
  table.sort(list, function(a, b) return tostring(a) < tostring(b) end)
  return list
end

local function list_names()
  if peripheral and peripheral.getNames then return sort_list(peripheral.getNames()) end
  local names = {}
  for _, side in ipairs(DEFAULT_SIDES) do
    if peripheral and peripheral.isPresent and peripheral.isPresent(side) then table.insert(names, side) end
  end
  return names
end

local function safe_methods(name)
  if not peripheral or not peripheral.getMethods then return {} end
  local ok, methods = pcall(peripheral.getMethods, name)
  if ok and type(methods) == "table" then return sort_list(methods) end
  return {}
end

local function safe_type(name)
  if not peripheral or not peripheral.getType then return "unknown" end
  local ok, ptype = pcall(peripheral.getType, name)
  if ok then return ptype or "unknown" end
  return "unknown"
end

local function contains_any(text, patterns)
  local lower = string.lower(tostring(text or ""))
  for _, pattern in ipairs(patterns or {}) do
    if string.find(lower, string.lower(pattern), 1, true) then return true end
  end
  return false
end

function inspector.inspect(name)
  local wrapped = peripheral and peripheral.wrap and peripheral.wrap(name)
  local methods = safe_methods(name)
  local hints = {}
  for _, method in ipairs(methods) do
    if contains_any(method, CREATE_HINTS) then table.insert(hints, method) end
  end
  return {
    name = name,
    type = safe_type(name),
    present = wrapped ~= nil,
    method_count = #methods,
    methods = methods,
    create_hints = hints
  }
end

function inspector.scan()
  local report = { generated_at = os.clock(), peripherals = {} }
  for _, name in ipairs(list_names()) do
    table.insert(report.peripherals, inspector.inspect(name))
  end
  return report
end

function inspector.find_methods(patterns)
  local matches = {}
  for _, info in ipairs(inspector.scan().peripherals) do
    for _, method in ipairs(info.methods or {}) do
      if contains_any(method, patterns or CREATE_HINTS) then
        table.insert(matches, { name = info.name, type = info.type, method = method })
      end
    end
  end
  return matches
end

function inspector.write_report(path, report)
  local target = path or "crn_peripheral_report.json"
  local body = json.encode(report or inspector.scan())
  if fs and fs.open then
    local fh = fs.open(target, "w")
    fh.write(body)
    fh.close()
    return true, target
  end
  if io and io.open then
    local fh = io.open(target, "w")
    if not fh then return false, "cannot open " .. tostring(target) end
    fh:write(body)
    fh:close()
    return true, target
  end
  return false, "no file API available"
end

function inspector.run(args)
  local options = args or {}
  local report
  if options.side then
    report = { generated_at = os.clock(), peripherals = { inspector.inspect(options.side) } }
  else
    report = inspector.scan()
  end

  print_line("CreateRailNet Peripheral Inspector")
  for _, info in ipairs(report.peripherals) do
    print_line("- " .. tostring(info.name) .. " type=" .. tostring(info.type) .. " present=" .. tostring(info.present) .. " methods=" .. tostring(info.method_count))
    for _, method in ipairs(info.methods) do print_line("  ." .. tostring(method)) end
    if #info.create_hints > 0 then print_line("  hints: " .. table.concat(info.create_hints, ", ")) end
  end

  if options.write then
    local ok, result = inspector.write_report(options.write, report)
    print_line((ok and "written: " or "write failed: ") .. tostring(result))
  end
  return report
end

local raw = {...}
if raw and #raw > 0 then
  inspector.run({ side = raw[1], write = raw[2] })
end

return inspector
