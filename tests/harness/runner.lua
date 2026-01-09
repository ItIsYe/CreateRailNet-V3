--[[
Purpose: Test runner for CreateRailNet-V3.
Public API: none (script).
]]

local tests = {
  "tests/test_config.lua",
  "tests/test_net.lua",
  "tests/test_dispatcher.lua"
}

local total = 0
local passed = 0

for _, path in ipairs(tests) do
  local ok, mod = pcall(dofile, path)
  if not ok then
    print("FAIL " .. path .. ": " .. tostring(mod))
  else
    for name, fn in pairs(mod) do
      total = total + 1
      local ok_test, err = pcall(fn)
      if ok_test then
        passed = passed + 1
        print("PASS " .. name)
      else
        print("FAIL " .. name .. ": " .. tostring(err))
      end
    end
  end
end

print(string.format("%d/%d PASS", passed, total))
if passed ~= total then
  error("tests failed")
end
