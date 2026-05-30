--[[
Purpose: Validate all maintained example configs.
Usage: lua scripts/check_configs.lua or shell.run("scripts/check_configs.lua")
]]

package.path = table.concat({ "./?.lua", "./?/init.lua", package.path or "" }, ";")
pcall(dofile, "tests/harness/cc_bootstrap.lua")

local config = require("src.shared.config")

local configs = {
  "configs/templates/network.full.example.json",
  "configs/templates/network.create.example.json",
  "configs/templates/network.mixed.example.json",
  "configs/templates/network.service_plan.example.json"
}

local failed = 0
for _, path in ipairs(configs) do
  local ok, result = pcall(function() return config.load(path) end)
  if ok then
    print("PASS config " .. path)
  else
    failed = failed + 1
    print("FAIL config " .. path .. ": " .. tostring(result))
  end
end

if failed ~= 0 then error("config checks failed") end
print("config checks passed")
