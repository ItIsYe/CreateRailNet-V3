--[[
Purpose: Prints or writes the acceptance report (docs/ABNAHME.md) from tests/acceptance/matrix.lua, and checks the matrix.
Public API: lua scripts/acceptance_report.lua [--write] [--check] [--stage]
  no flag: print the report   --write: write docs/ABNAHME.md   --check: exit 1 when the matrix has problems or docs/ABNAHME.md is out of date   --stage: print the release stage reached
Notes: a development tool (not installed on the computers in the game).
]]

package.path = "./?.lua;" .. package.path

local matrix = dofile("tests/acceptance/matrix.lua")
local lib = dofile("tests/acceptance/lib.lua")

local function read(path)
  local fh = io.open(path, "r")
  if not fh then return nil end
  local body = fh:read("*a")
  fh:close()
  return body
end

local mode = arg and arg[1]
local text = lib.report(matrix)
if mode == "--write" then
  local fh = assert(io.open("docs/ABNAHME.md", "w"))
  fh:write(text)
  fh:close()
  print("wrote docs/ABNAHME.md")
elseif mode == "--check" then
  local problems = lib.validate(matrix, read)
  if read("docs/ABNAHME.md") ~= text then problems[#problems + 1] = "docs/ABNAHME.md is out of date: run lua scripts/acceptance_report.lua --write" end
  for _, p in ipairs(problems) do print("acceptance: " .. p) end
  if #problems > 0 then os.exit(1) end
  print("acceptance matrix ok")
elseif mode == "--stage" then
  local stage, why = lib.stage(matrix)
  print(stage .. ": " .. why)
else
  print(text)
end
