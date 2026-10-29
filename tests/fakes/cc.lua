--[[
Purpose: Strenge Fakes fuer CC:Tweaked: Dateisystem (feste Kapazitaet 1 000 000 Byte, jede Datei zaehlt mindestens 500, move scheitert bei vorhandenem Ziel, Absturz an der n-ten Aenderung mit Merker _state.crashed und beschaedigtes Schreiben einstellbar) und HTTP (Antworten aus einer Tabelle). Sie bilden nur nach, was das Spiel auch tut.
API: cc.fs(opts) -> fs; cc.http(routes) -> http; cc.env(fs, http) -> env mit gesammelten Ausgaben
]]

local M = {}

local function norm(path)
  local parts = {}
  for part in tostring(path):gmatch("[^/]+") do
    if part == ".." then parts[#parts] = nil elseif part ~= "." then parts[#parts + 1] = part end
  end
  return table.concat(parts, "/")
end

function M.fs(opts)
  opts = opts or {}
  local fake = { files = {}, dirs = { [""] = true }, ops = 0, crash_at = opts.crash_at, capacity = opts.capacity or 1000000, corrupt = opts.corrupt }

  local function parent(p) return (p:match("^(.*)/[^/]+$")) or "" end

  local function mutate(kind)
    fake.ops = fake.ops + 1
    -- ab dem eingestellten Abbruch ist der Computer "aus": jede weitere Aenderung scheitert, auch wenn der Aufrufer Fehler abfaengt
    if fake.crash_at and (fake.crashed or fake.ops == fake.crash_at) then
      fake.crashed = true
      error("CRASH bei Aenderung " .. fake.ops .. " (" .. kind .. ")", 0)
    end
  end

  local function used()
    local sum = 0
    for _, text in pairs(fake.files) do sum = sum + math.max(#text, 500) end
    return sum
  end

  local api = {}
  function api.exists(p) p = norm(p); return fake.files[p] ~= nil or fake.dirs[p] == true end
  function api.isDir(p) return fake.dirs[norm(p)] == true end
  function api.getDir(p) return parent(norm(p)) end
  function api.getFreeSpace() return fake.capacity - used() end
  function api.getSize(p) p = norm(p); return fake.files[p] and #fake.files[p] or 0 end
  function api.makeDir(p)
    p = norm(p)
    mutate("makeDir")
    if fake.files[p] then error("File exists", 0) end
    local cur = ""
    for part in p:gmatch("[^/]+") do
      cur = (cur == "") and part or (cur .. "/" .. part)
      fake.dirs[cur] = true
    end
  end
  function api.delete(p)
    p = norm(p)
    mutate("delete")
    fake.files[p] = nil
    if fake.dirs[p] then
      local prefix = p .. "/"
      for f in pairs(fake.files) do if f:sub(1, #prefix) == prefix then fake.files[f] = nil end end
      for d in pairs(fake.dirs) do if d == p or d:sub(1, #prefix) == prefix then fake.dirs[d] = nil end end
    end
  end
  function api.move(from, to)
    from, to = norm(from), norm(to)
    mutate("move")
    if not (fake.files[from] or fake.dirs[from]) then error("No such file", 0) end
    if fake.files[to] or fake.dirs[to] then error("Destination exists", 0) end
    if not fake.dirs[parent(to)] then error("Destination directory missing", 0) end
    if fake.files[from] then
      fake.files[to] = fake.files[from]; fake.files[from] = nil
      return
    end
    local prefix = from .. "/"
    local moved_files, moved_dirs = {}, {}
    for f, text in pairs(fake.files) do if f:sub(1, #prefix) == prefix then moved_files[f] = text end end
    for d in pairs(fake.dirs) do if d == from or d:sub(1, #prefix) == prefix then moved_dirs[#moved_dirs + 1] = d end end
    for f, text in pairs(moved_files) do fake.files[f] = nil; fake.files[to .. "/" .. f:sub(#prefix + 1)] = text end
    for _, d in ipairs(moved_dirs) do fake.dirs[d] = nil; fake.dirs[to .. d:sub(#from + 1)] = true end
  end
  function api.open(p, mode)
    p = norm(p)
    if mode == "r" or mode == "rb" then
      local text = fake.files[p]
      if not text then return nil, "No such file" end
      return { readAll = function() return text end, close = function() end }
    end
    if fake.dirs[p] or not fake.dirs[parent(p)] then return nil, "Cannot open" end
    local buffer = {}
    if mode == "a" or mode == "ab" then buffer[1] = fake.files[p] or "" end
    local handle = {}
    function handle.write(text) buffer[#buffer + 1] = text end
    function handle.close()
      mutate("write")
      local text = table.concat(buffer)
      local old = fake.files[p]
      fake.files[p] = nil
      if used() + math.max(#text, 500) > fake.capacity then
        fake.files[p] = old
        error("Out of space", 0)
      end
      fake.files[p] = fake.corrupt and fake.corrupt(p, text) or text
    end
    return handle
  end
  function api.list(p)
    p = norm(p)
    local out, prefix = {}, (p == "") and "" or (p .. "/")
    local seen = {}
    for name in pairs(fake.files) do
      if name:sub(1, #prefix) == prefix then seen[name:sub(#prefix + 1):match("^[^/]+")] = true end
    end
    for name in pairs(fake.dirs) do
      if name ~= "" and name:sub(1, #prefix) == prefix then seen[name:sub(#prefix + 1):match("^[^/]+")] = true end
    end
    for name in pairs(seen) do out[#out + 1] = name end
    table.sort(out)
    return out
  end
  api._state = fake
  return api
end

function M.http(routes)
  local api = { requests = {}, routes = routes }
  function api.get(url, headers, binary)
    api.requests[#api.requests + 1] = url
    local body = api.routes[url]
    if body == nil then return nil, "404" end
    return { readAll = function() return body end, close = function() end }
  end
  return api
end

function M.env(fs, http)
  local env = { fs = fs, http = http, lines = {}, since = {}, reads = 0, started = 0 }
  local function out(text)
    env.lines[#env.lines + 1] = tostring(text)
    env.since[#env.since + 1] = tostring(text)
  end
  env.print = out
  env.write = out
  -- Antworten: entweder eine Liste (env.answers) oder eine Funktion (env.responder), die den Bildschirm seit der letzten Eingabe bekommt
  env.read = function()
    env.reads = env.reads + 1
    if env.reads > 300 then error("zu viele Eingaben: Endlosschleife im Dialog?", 0) end
    local screen = table.concat(env.since, "\n")
    env.since = {}
    if env.answers then return table.remove(env.answers, 1) end
    if env.responder then return env.responder(screen) end
    return ""
  end
  env.clear = function() env.cleared = (env.cleared or 0) + 1 end
  env.start = function() env.started = env.started + 1 end
  function env.output() return table.concat(env.lines, "\n") end
  return env
end

return M
