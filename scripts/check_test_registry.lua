--[[
Purpose: Fail when a tests/test_*.lua file is not listed in the test runner, is listed twice, or a listed file is gone.
Usage: lua scripts/check_test_registry.lua (needs io.popen; prints SKIP and succeeds inside CC:Tweaked)
Notes: The runner executes an explicit list. A test file missing from it silently never runs.
]]

if not (io and io.popen) then
  print("SKIP test registry check: io.popen unavailable")
  return
end

local function read_all(path)
  local fh = io.open(path, "r")
  if not fh then error("cannot read " .. path) end
  local body = fh:read("*a")
  fh:close()
  return body
end

local duplicates = {}

local function listed(body)
  local set = {}
  for path in body:gmatch('"(tests/test_[%w_]+%.lua)"') do
    if set[path] then duplicates[#duplicates + 1] = path end
    set[path] = true
  end
  return set
end

local on_disk = {}
local pipe = io.popen("ls tests/test_*.lua")
for line in pipe:lines() do on_disk[line] = true end
pipe:close()

local sources = {
  ["tests/harness/runner.lua"] = listed(read_all("tests/harness/runner.lua"))
}

local failed = 0
for name, set in pairs(sources) do
  for path in pairs(on_disk) do
    if not set[path] then failed = failed + 1; print("FAIL " .. path .. " is not listed in " .. name) end
  end
  for path in pairs(set) do
    if not on_disk[path] then failed = failed + 1; print("FAIL " .. name .. " lists missing file " .. path) end
  end
end

for _, path in ipairs(duplicates) do failed = failed + 1; print("FAIL " .. path .. " is listed twice (its tests would run twice)") end

local count = 0
for _ in pairs(on_disk) do count = count + 1 end
print(string.format("test registry: %d test files, %d problems", count, failed))
if failed ~= 0 then error("test registry check failed") end
