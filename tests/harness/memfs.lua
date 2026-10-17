--[[
Purpose: In-memory filesystem with CC:Tweaked semantics (fs.move onto an existing file fails) and crash injection.
Public API: new() -> fs with open/exists/delete/move/makeDir plus files, ops, crash_at, fail, snapshot(), set(path, body).
Notes: crash_at = n raises "crash" instead of performing the n-th mutating operation (a write that crashes leaves half
  the content behind). fail.move_for = path makes the next fs.move to that destination silently do nothing (one shot).
]]

local memfs = {}

function memfs.new()
  local f = { files = {}, ops = 0, crash_at = nil, fail = {} }

  local function mutate(partial)
    f.ops = f.ops + 1
    if f.crash_at and f.ops == f.crash_at then
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

  function f.set(path, body) f.files[path] = body end

  function f.snapshot()
    local copy = {}
    for path, body in pairs(f.files) do copy[path] = body end
    return copy
  end

  return f
end

return memfs
