--[[
Purpose: First-time setup of a CreateRailNet computer. A step-by-step wizard (role, network plan, name, hardware, summary) that
  writes startup.lua and, when needed, configs/network.json. All logic lives in src/setup/wizard.lua.
Usage: shell.run("scripts/setup.lua")                 asks for everything
       shell.run("scripts/setup.lua", "--role", "sensor")   role chosen already (the installer does this)
       shell.run("scripts/setup.lua", "--check")             is configs/network.json valid? (or --check <file>); changes nothing
       shell.run("scripts/setup.lua", "--doctor")            is this computer ready? plan, devices, modem, monitor, space; says what to do;
                                                              changes nothing but the record of the result (crn_status.lua)
Notes: Enter takes the suggestion in [ ], ? explains the question, < goes one step back. Nothing is written before the summary is confirmed.
]]

-- CC:Tweaked resolves relative require paths against the directory of the running program (scripts/); the modules live in /src.
package.path = "/?.lua;/?/init.lua;" .. (package.path or "")

local wizard = require("src.setup.wizard")

local result = wizard.run({
  args = { ... },
  env = {
    print = print,
    write = write or io.write,
    read = read or function() return io.read() end,
    term = term,
    colors = colors,
    fs = fs,
    peripheral = peripheral,
    os = os,
  },
})

if result.aborted then
  print("")
  print("Abgebrochen. Es wurde nichts geaendert.")
end
