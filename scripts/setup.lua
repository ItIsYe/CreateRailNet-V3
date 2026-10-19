--[[
Purpose: First-time setup of a CreateRailNet computer. A step-by-step wizard (role, network plan, name, hardware, summary) that
  writes startup.lua and, when needed, configs/network.json. All logic lives in src/setup/wizard.lua.
Usage: shell.run("scripts/setup.lua")                 asks for everything
       shell.run("scripts/setup.lua", "--role", "sensor")   role chosen already (the installer does this)
       shell.run("scripts/setup.lua", "--check")             is configs/network.json valid? (or --check <file>); changes nothing
       shell.run("scripts/setup.lua", "--doctor")            is this computer ready? plan, devices, modem, monitor, space; says what to do;
                                                              changes nothing but the record of the result (crn_status.lua)
       shell.run("scripts/setup.lua", "--fetch-plan")        station / depot: fetch the network plan from the master (platforms, tracks);
                                                              writes it only after a yes, the old file stays as .prev
       shell.run("scripts/setup.lua", "--test")              guided function test: reads freely, switches a signal / turnout only after a yes
                                                              and puts it back (signal RED, turnout straight); the result goes to the master
       shell.run("scripts/setup.lua", "--linktest")          how good is the link to the master? answers, time, largest message that gets
                                                              through; asks only, switches and writes nothing
       shell.run("scripts/setup.lua", "--export")            writes crn_diag.txt: version, check result, own entry, devices, files, free space
                                                              (to send in with `pastebin put crn_diag.txt`); reads only
Notes: Enter takes the suggestion in [ ], ? explains the question, < goes one step back. Nothing is written before the summary is confirmed.
]]

-- CC:Tweaked resolves relative require paths against the directory of the running program (scripts/); the modules live in /src.
package.path = "/?.lua;/?/init.lua;" .. (package.path or "")

local wizard = require("src.setup.wizard")
local link = require("src.setup.link")
local plan_fetch = require("src.setup.plan_fetch")

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
    host = _HOST,
    link = link.probe,
    fetch = plan_fetch.fetch,
    sleep = sleep,
    redstone = redstone,
  },
})

if result.aborted then
  print("")
  print("Abgebrochen. Es wurde nichts geaendert.")
end
