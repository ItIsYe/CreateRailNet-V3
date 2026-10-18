--[[
Purpose: In-memory filesystem with CC:Tweaked semantics (fs.move onto an existing file fails) and crash injection.
Public API: new() -> fs with open/exists/delete/move/makeDir/getFreeSpace plus files, ops, crash_at, fail, capacity, snapshot(), set(path, body).
Notes: crash_at = n raises "crash" instead of performing the n-th mutating operation (a write that crashes leaves half
  the content behind). With sticky_crash every later mutating operation raises too, even where code catches the error, until
  the test sets crashed = false (the reboot). fail.move_for = path makes the next fs.move to that destination silently do nothing (one shot).
]]

local memfs = {}

function memfs.new()
  local f = { files = {}, ops = 0, crash_at = nil, fail = {} }

  local function mutate(partial)
    -- sticky_crash: once the computer crashed it stays dead until the test reboots it (f.crashed = false)
    if f.crashed then error("crash", 0) end
    f.ops = f.ops + 1
    if f.crash_at and f.ops == f.crash_at then
      if f.sticky_crash then f.crashed = true end
      if partial then partial() end
      error("crash", 0)
    end
  end

  f.exists = function(path) return f.files[path] ~= nil end

  f.open = function(path, mode)
    if mode == "r" then
      if f.files[path] == nil then return nil end
      return { readAll = function() return f.files[path] end, readLine = function() return (f.files[path] or ""):match("^[^\n]*") end, close = function() end }
    end
    if f.fail.open == path then return nil end
    local buffer = {}
    return {
      write = function(text) buffer[#buffer + 1] = tostring(text) end,
      close = function()
        local body = table.concat(buffer)
        local previous = f.files[path] and #f.files[path] or 0
        if f.capacity and used() - previous + #body > f.capacity then error("Out of space", 0) end
        mutate(function() f.files[path] = body:sub(1, math.floor(#body / 2)) end)
        if f.fail.truncate then body = body:sub(1, f.fail.truncate) end
        f.files[path] = body
      end
    }
  end

  f.delete = function(path)
    mutate()
    f.files[path] = nil
  end

  f.move = function(src, dst)
    mutate()
    if f.fail.move_for == dst then f.fail.move_for = nil; return end
    if f.files[src] == nil then error("No such file", 0) end
    if f.files[dst] ~= nil then error("Destination exists", 0) end
    f.files[dst] = f.files[src]
    f.files[src] = nil
  end

  f.makeDir = function() end

  -- capacity (bytes) nil = no limit; a write that does not fit raises like CC:Tweaked does and stores nothing
  local function used()
    local total = 0
    for _, body in pairs(f.files) do total = total + #body end
    return total
  end
  f.used = used
  f.getFreeSpace = function()
    if not f.capacity then return "unlimited" end
    return math.max(0, f.capacity - used())
  end

  function f.set(path, body) f.files[path] = body end

  function f.snapshot()
    local copy = {}
    for path, body in pairs(f.files) do copy[path] = body end
    return copy
  end

  return f
end

return memfs
