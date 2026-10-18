--[[
Purpose: A fake CC:Tweaked computer for the installer: in-memory filesystem, a GitHub that serves the files of this repository,
  a shell, and the installer script run inside it.
Public API:
  new(opts) -> world       opts: ref (default "main"), capacity (bytes of disk), serve (path -> body overrides)
  world.run(argv, answers) -> ok, result_or_error    runs the real `installer` file with those arguments; answers feed read()
  world.set_version(overrides) -> manifest           serves a new version: overrides path -> body (nil removes), manifest rebuilt
  world.fs, world.requests (urls), world.printed, world.shell_runs, world.rebooted, world.sleeps
  world.fail_next(path, count, kind)                 kind "corrupt" | "html" | "error" | "stale"
Notes: the installer chunk gets its own global environment, so nothing of the test process leaks into it and the other way round.
]]

local memfs = require("tests.harness.memfs")
local manifest_builder = require("src.tools.manifest_builder")

local installer_world = {}

local function read_disk(path)
  local fh = io.open(path, "rb")
  if not fh then return nil end
  local body = fh:read("*a")
  fh:close()
  return body
end

local function compile_with_env(text, name, env)
  if setfenv then
    local fn, err = loadstring(text, "=" .. name)
    if fn then setfenv(fn, env) end
    return fn, err
  end
  return load(text, "=" .. name, "t", env)
end
installer_world.compile_with_env = compile_with_env

function installer_world.new(opts)
  local o = opts or {}
  local world = {
    ref = o.ref or "main",
    fs = memfs.new(),
    served = {},
    requests = {},
    printed = {},
    shell_runs = {},
    sleeps = {},
    rebooted = 0,
    failures = {},
  }
  world.fs.capacity = o.capacity
  world.installer_text = read_disk("installer")

  -- the repository as GitHub would serve it: every runtime file, the installer modules and the manifest
  local function served_body(path)
    if world.served[path] ~= nil then return world.served[path] or nil end
    return read_disk(path)
  end
  for path, body in pairs(o.serve or {}) do world.served[path] = body end

  local base = "https://raw.githubusercontent.com/ItIsYe/CreateRailNet-V3/" .. world.ref .. "/"

  local fake_http = {}
  function fake_http.get(url)
    world.requests[#world.requests + 1] = url
    local clean = url:gsub("%?.*$", "")
    if clean:sub(1, #base) ~= base then return nil, "wrong host" end
    local path = clean:sub(#base + 1)
    local failure = world.failures[path]
    if failure and failure.count > 0 then
      failure.count = failure.count - 1
      if failure.kind == "error" then return nil, "connection refused" end
      if failure.kind == "html" then
        return { readAll = function() return "<!DOCTYPE html><html><body>Bad gateway</body></html>" end, close = function() end }
      end
      local body = served_body(path)
      if failure.kind == "corrupt" and body then
        body = body:sub(1, #body - 1) .. string.char((body:byte(#body) + 1) % 256)
        return { readAll = function() return body end, close = function() end }
      end
      if failure.kind == "stale" and body then
        body = body .. "\n-- old version still in the CDN cache\n"
        return { readAll = function() return body end, close = function() end }
      end
    end
    local body = served_body(path)
    if not body then
      return { readAll = function() return "404: Not Found" end, getResponseCode = function() return 404 end, close = function() end }
    end
    return { readAll = function() return body end, getResponseCode = function() return 200 end, close = function() end }
  end

  function world.fail_next(path, count, kind) world.failures[path] = { count = count, kind = kind or "error" } end

  function world.set_version(overrides)
    for path, body in pairs(overrides or {}) do world.served[path] = body or false end
    local manifest = manifest_builder.build(function(path) return served_body(path) end, nil)
    world.served["install/manifest.lua"] = manifest_builder.render(manifest)
    return manifest
  end

  world.shell = {
    run = function(...) world.shell_runs[#world.shell_runs + 1] = table.concat({ ... }, " "); return true end,
  }

  function world.run(argv, answers)
    local queue = {}
    for _, a in ipairs(answers or {}) do queue[#queue + 1] = a end
    local fake_os = {
      sleep = function(seconds) world.sleeps[#world.sleeps + 1] = seconds end,
      reboot = function() world.rebooted = world.rebooted + 1 end,
      epoch = function() return 1700000000000 + #world.requests end,
      time = os.time, clock = os.clock, date = os.date, remove = os.remove, rename = os.rename,
    }
    local env = setmetatable({
      fs = world.fs, http = fake_http, shell = world.shell, os = fake_os,
      print = function(text) world.printed[#world.printed + 1] = tostring(text) end,
      write = function(text) world.printed[#world.printed + 1] = tostring(text) end,
      read = function() return table.remove(queue, 1) end,
    }, { __index = _G })
    local chunk, err = compile_with_env(world.installer_text, "installer", env)
    if not chunk then return false, "installer does not compile: " .. tostring(err) end
    local unpack_fn = table.unpack or unpack
    local ok, result = pcall(chunk, unpack_fn(argv or {}))
    return ok, result
  end

  function world.requests_for(path)
    local count = 0
    for _, url in ipairs(world.requests) do
      if url:gsub("%?.*$", ""):sub(-#path) == path then count = count + 1 end
    end
    return count
  end

  function world.output() return table.concat(world.printed, "\n") end

  return world
end

return installer_world
