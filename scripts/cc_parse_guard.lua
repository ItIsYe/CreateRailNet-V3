--[[
Purpose: Repository-wide CC:Tweaked compatibility guard that finds its files itself instead of using a list.
Usage: lua5.1 scripts/cc_parse_guard.lua (also runs on luajit/lua5.4; needs io.popen, skipped inside CC:Tweaked)
Checks per .lua file under src, scripts, tests and startup.lua:
  1. it parses with the running interpreter (run it with lua5.1 or luajit to get the CC dialect and its limits)
  2. src and scripts files start with a "Purpose:" header comment (AGENTS.md)
  3. no library calls that do not exist in CC:Tweaked's Lua 5.1 (utf8, bit32, string.pack, table.move, ...)
  4. no accidental globals in src/scripts/startup (bytecode listing via luac5.1 or luajit, skipped when neither exists)
]]

if not (io and io.popen) then
  print("SKIP cc parse guard: io.popen unavailable")
  return
end

local BANNED = { "utf8%.", "bit32%.", "string%.pack", "string%.unpack", "table%.move", "math%.tointeger", "math%.type" }

local function list_files()
  local files = {}
  local pipe = io.popen("find src scripts tests -name '*.lua' | sort")
  for line in pipe:lines() do files[#files + 1] = line end
  pipe:close()
  files[#files + 1] = "startup.lua"
  return files
end

local function read_all(path)
  local fh = io.open(path, "r")
  if not fh then return nil end
  local body = fh:read("*a")
  fh:close()
  return body
end

-- drop comments and string literals well enough for a banned-call scan
local function strip(body)
  body = body:gsub("%-%-%[(=*)%[.-%]%1%]", "")
  body = body:gsub("%-%-[^\n]*", "")
  body = body:gsub('"[^"\n]*"', '""')
  body = body:gsub("'[^'\n]*'", "''")
  return body
end

-- returns command template and a Lua pattern that matches the "set a global" opcode column only
local function global_tool()
  local function has(cmd)
    local ok = os.execute(cmd .. " >/dev/null 2>&1")
    return ok == 0 or ok == true
  end
  if has("command -v luac5.1") then return "luac5.1 -l -p %s", "%[%d+%]%s+SETGLOBAL%s" end
  if has("command -v luajit") then return "luajit -bl %s", "%d%d%d%d%s+GSET%s+%d" end
  return nil
end

local files = list_files()
local tool, marker = global_tool()
if not tool then print("NOTE no luac5.1 or luajit: global check skipped") end

local failed = 0
local function fail(path, text) failed = failed + 1; print("FAIL " .. path .. ": " .. text) end

for _, path in ipairs(files) do
  local body = read_all(path)
  if not body then
    fail(path, "unreadable")
  else
    local chunk, err = loadfile(path)
    if not chunk then fail(path, "parse error: " .. tostring(err)) end

    local enforced = path:match("^src/") or path:match("^scripts/") or path == "startup.lua"
    if (path:match("^src/") or path:match("^scripts/")) and not body:sub(1, 600):find("Purpose", 1, true) then
      fail(path, "missing Purpose header comment")
    end

    if chunk then
      local code = strip(body)
      for _, pattern in ipairs(BANNED) do
        if code:find(pattern) then fail(path, "uses " .. pattern:gsub("%%", "") .. " which plain Lua 5.1 (the offline test interpreter) lacks") end
      end
    end

    if enforced and tool and chunk then
      local pipe = io.popen(string.format(tool, path) .. " 2>&1")
      local listing = pipe:read("*a")
      pipe:close()
      local line = listing:match("[^\n]*" .. marker .. "[^\n]*")
      if line then fail(path, "sets a global: " .. (line:gsub("%s+", " "))) end
    end
  end
end

print(string.format("cc parse guard: %d files, %d problems", #files, failed))
if failed ~= 0 then error("cc parse guard failed") end
