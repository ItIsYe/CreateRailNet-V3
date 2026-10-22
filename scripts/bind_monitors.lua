--[[
Purpose: Bind the monitors of a panel computer (docs/PANEL.md). The logic lives in src/setup/monitor_tool.lua.
Usage: shell.run("scripts/bind_monitors.lua", "bind", "LEIT-1")     show a big number on each free monitor, pick one, confirm
       shell.run("scripts/bind_monitors.lua", "list")               monitors, bindings, views, groups
       shell.run("scripts/bind_monitors.lua", "check")              compare bindings and attached monitors (changes nothing)
       shell.run("scripts/bind_monitors.lua")                       prints all commands
Notes: the computer id is read from the plan of this computer (configs/network.json, node with role panel); --id <ID> names it.
]]

-- CC:Tweaked resolves relative require paths against the directory of the running program (scripts/); the modules live in /src.
package.path = "/?.lua;/?/init.lua;" .. (package.path or "")

local monitor_tool = require("src.setup.monitor_tool")
local config_module = require("src.shared.config")

local args = { ... }
local id
local rest = {}
local i = 1
while i <= #args do
  if args[i] == "--id" then id = args[i + 1]; i = i + 2 else rest[#rest + 1] = args[i]; i = i + 1 end
end

if not id and fs and fs.exists and fs.exists("configs/network.json") then
  local ok, cfg = pcall(config_module.load, "configs/network.json")
  if ok then
    for _, node in ipairs(cfg.nodes or {}) do
      if node.role == "panel" then id = id or node.id end
    end
  end
end

local code = monitor_tool.run(rest, {
  fs = fs, peripheral = peripheral, id = id,
  say = print,
  ask = function(prompt) write(prompt); return read() end
})
if code ~= 0 then error("", 0) end
