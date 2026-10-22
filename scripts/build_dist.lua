--[[
Purpose: Writes or checks dist/, the minified copy of every file the installer puts on a computer (a CC:Tweaked computer holds 1 000 000 bytes; the commented source would not fit).
Usage: lua scripts/build_dist.lua --write   after changing any runtime file (run before scripts/manifest_sync.lua --write)
       lua scripts/build_dist.lua --check   CI: fails when dist/ differs from what the sources produce (missing, stale or stray files)
Notes: dev tool, runs outside the game from the repository root. The installer downloads dist/<path>; install/manifest.lua holds size and Adler-32 of these files.
]]

package.path = table.concat({ "./?.lua", "./?/init.lua", package.path or "" }, ";")

local json = require("src.shared.json")
local manifest_builder = require("src.tools.manifest_builder")

local function read(path)
  local fh = io.open(path, "rb")
  if not fh then return nil end
  local body = fh:read("*a")
  fh:close()
  return body
end

local mode = (arg and arg[1]) or "--check"
local runtime_manifest = json.decode(read("configs/install/runtime_manifest.json") or "{}")
local manifest, problems = manifest_builder.build(read, runtime_manifest)
if #problems > 0 then
  for _, text in ipairs(problems) do print("PROBLEM " .. text) end
  os.exit(1)
end

local wanted = {}
for path in pairs(manifest.files) do wanted["dist/" .. path] = manifest_builder.shipped(path, read(path)) end

local function list_dist()
  local out = {}
  local pipe = io.popen("find dist -type f 2>/dev/null")
  if pipe then
    for line in pipe:lines() do out[#out + 1] = line end
    pipe:close()
  end
  return out
end

local function ensure_dir(path)
  local dir = path:match("^(.*)/[^/]+$")
  if dir then os.execute("mkdir -p '" .. dir .. "'") end
end

if mode == "--write" then
  for _, path in ipairs(list_dist()) do
    if wanted[path] == nil then os.remove(path) end
  end
  local count = 0
  for path, body in pairs(wanted) do
    if read(path) ~= body then
      ensure_dir(path)
      local fh = assert(io.open(path, "wb"))
      fh:write(body)
      fh:close()
    end
    count = count + 1
  end
  print("dist/ written (" .. count .. " files)")
elseif mode == "--check" then
  local bad = 0
  for path, body in pairs(wanted) do
    if read(path) ~= body then print("dist out of date: " .. path); bad = bad + 1 end
  end
  for _, path in ipairs(list_dist()) do
    if wanted[path] == nil then print("stray file in dist: " .. path); bad = bad + 1 end
  end
  if bad > 0 then
    print("Run: lua scripts/build_dist.lua --write")
    os.exit(1)
  end
  print("dist/ is current")
else
  print("usage: lua scripts/build_dist.lua --write | --check")
  os.exit(2)
end
