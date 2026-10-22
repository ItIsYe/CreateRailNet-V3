--[[
Purpose: Bind the signals of a multi-signal node one by one (docs/SIGNAL_NODES.md). The logic lives in src/setup/signal_tool.lua.
Usage: shell.run("scripts/bind_signals.lua", "bind", "S-A")    connect ONE signal, see it go red, confirm, give track and direction
       shell.run("scripts/bind_signals.lua", "check")          compare bindings, devices and plan (changes nothing)
       shell.run("scripts/bind_signals.lua")                    prints all commands
Notes: the computer id is read from the plan of this computer (configs/network.json, node with role signal); --id <ID> names it.
]]

-- CC:Tweaked resolves relative require paths against the directory of the running program (scripts/); the modules live in /src.
package.path = "/?.lua;/?/init.lua;" .. (package.path or "")

local signal_tool = require("src.setup.signal_tool")
local config_module = require("src.shared.config")

local args = { ... }
local id
local rest = {}
local i = 1
while i <= #args do
  if args[i] == "--id" then id = args[i + 1]; i = i + 2 else rest[#rest + 1] = args[i]; i = i + 1 end
end

local cfg
if fs and fs.exists and fs.exists("configs/network.json") then
  local ok, loaded = pcall(config_module.load, "configs/network.json")
  if ok then cfg = loaded end
end
if not id and cfg then
  for _, node in ipairs(cfg.nodes or {}) do
    if node.role == "signal" and type(node.signals) == "table" then id = id or node.id end
  end
end

local code = signal_tool.run(rest, {
  fs = fs, peripheral = peripheral, config = cfg, id = id,
  say = print,
  ask = function(prompt) write(prompt); return read() end,
  now = function() return os.epoch and math.floor(os.epoch("utc") / 1000) or os.time() end
})
if code ~= 0 then error("", 0) end
