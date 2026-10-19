--[[
Purpose: The check before a version tag (dev tool, runs outside the game from the repository root): the checks of the CI, the state of git, and --
  only when all of it is green -- the commands that set the tag. It does not set a tag and does not push; docs/RELEASE.md says how a release goes.
Usage: lua scripts/release_check.lua                        run the checks only
       lua scripts/release_check.lua --version v1.0.0       ... and print the tag commands when everything is green
       lua scripts/release_check.lua --lua51 /path/to/lua5.1 --lua /path/to/lua5.4     interpreters that are not on the PATH
Notes: exit code 0 = everything green, 1 = something is not. The checks take as long as the test suite does, twice.
]]

package.path = table.concat({ "./?.lua", "./?/init.lua", package.path or "" }, ";")

local release_check = require("src.tools.release_check")

local options = {}
do
  local argv = arg or {}
  local i = 1
  while i <= #argv do
    local token = argv[i]
    if token == "--version" or token == "--lua" or token == "--lua51" then
      if not argv[i + 1] then io.stderr:write("Zu " .. token .. " fehlt der Wert.\n"); os.exit(2) end
      options[token:sub(3)] = argv[i + 1]
      i = i + 2
    else
      io.stderr:write("Unbekannte Option: " .. tostring(token) .. " (erlaubt: --version --lua --lua51)\n")
      os.exit(2)
    end
  end
end

-- the exit status of os.execute: Lua 5.1 gives a number, 5.2+ gives true / nil, "exit" / "signal", code
local function succeeded(a, _, c)
  if type(a) == "number" then return a == 0, a end
  return a == true, c
end

local function run(cmd)
  io.write("  ... " .. cmd .. "\n")
  io.flush()
  local ok, code = succeeded(os.execute(cmd .. " > /dev/null 2>&1"))
  -- 127: the shell did not find the program
  return ok, code and ("Code " .. tostring(code)) or nil, code == 127
end

local function git(args)
  local pipe = io.popen("git " .. args .. " 2>/dev/null")
  if not pipe then return nil end
  local text = pipe:read("*a")
  local ok = pipe:close()
  if ok == nil or ok == false then return nil end
  return text
end

local report = release_check.run({ version = options.version, lua = options.lua, lua51 = options.lua51, run = run, git = git })
print("")
for _, text in ipairs(report.lines) do print(text) end
os.exit(report.ok and 0 or 1)
