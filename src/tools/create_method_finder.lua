--[[
Purpose: Find likely Create/Train/Schedule peripheral methods safely.
Public API: run(args), find(args).
]]

local inspector = require("src.tools.peripheral_inspector")

local finder = {}

local DEFAULT_PATTERNS = { "train", "schedule", "station", "destination", "speed", "stop", "start", "assemble", "disassemble", "track", "signal", "switch" }

function finder.find(args)
  local patterns = args and args.patterns or DEFAULT_PATTERNS
  return inspector.find_methods(patterns)
end

function finder.run(args)
  local matches = finder.find(args or {})
  print("CreateRailNet Create Method Finder")
  if #matches == 0 then print("No matching methods found") end
  for _, match in ipairs(matches) do print(tostring(match.name) .. " type=" .. tostring(match.type) .. " ." .. tostring(match.method)) end
  return matches
end

return finder
