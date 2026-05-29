--[[
Purpose: Ingame helper to inspect CC:Tweaked peripherals and method names.
Usage: require("src.tools.peripheral_inspector").run({ side = "left" }) or execute as script.
]]

local inspector = {}

local function print_line(text)
  print(tostring(text))
end

local function list_names()
  if peripheral and peripheral.getNames then return peripheral.getNames() end
  local names = {}
  for _, side in ipairs({ "left", "right", "top", "bottom", "front", "back" }) do
    if peripheral and peripheral.isPresent and peripheral.isPresent(side) then table.insert(names, side) end
  end
  return names
end

local function safe_methods(name)
  if not peripheral or not peripheral.getMethods then return {} end
  local ok, methods = pcall(peripheral.getMethods, name)
  if ok and type(methods) == "table" then return methods end
  return {}
end

function inspector.inspect(name)
  local wrapped = peripheral and peripheral.wrap and peripheral.wrap(name)
  local ptype = peripheral and peripheral.getType and peripheral.getType(name) or "unknown"
  return { name = name, type = ptype, methods = safe_methods(name), present = wrapped ~= nil }
end

function inspector.run(args)
  local options = args or {}
  local names = options.side and { options.side } or list_names()
  print_line("CreateRailNet Peripheral Inspector")
  for _, name in ipairs(names) do
    local info = inspector.inspect(name)
    print_line("- " .. tostring(info.name) .. " type=" .. tostring(info.type) .. " present=" .. tostring(info.present))
    for _, method in ipairs(info.methods) do print_line("  ." .. tostring(method)) end
  end
end

local args = {...}
if args and #args > 0 then inspector.run({ side = args[1] }) end

return inspector
