--[[
Purpose: Minimal CC:Tweaked compatibility layer for running tests outside Minecraft.
Public API: install() -> true.
]]

local bootstrap = {}

local function install_fs()
  if _G.fs then return end
  _G.fs = {
    open = function(path, mode)
      local fh = assert(io.open(path, mode == "w" and "w" or "r"))
      return {
        readAll = function() return fh:read("*a") end,
        read = function(_, fmt) return fh:read(fmt or "*a") end,
        write = function(_, text) fh:write(text) end,
        close = function() fh:close() end
      }
    end,
    exists = function(path)
      local fh = io.open(path, "r")
      if fh then fh:close(); return true end
      return false
    end,
    combine = function(a, b)
      if not a or a == "" then return b end
      if not b or b == "" then return a end
      if string.sub(a, -1) == "/" then return a .. b end
      return a .. "/" .. b
    end
  }
end

local function install_textutils()
  if _G.textutils then return end
  _G.textutils = {
    serialize = function(value)
      if type(value) == "table" then return "<table>" end
      return tostring(value)
    end,
    unserializeJSON = function()
      return nil
    end,
    serializeJSON = function(value)
      return tostring(value)
    end
  }
end

local function install_peripheral()
  if _G.peripheral then return end
  _G.peripheral = {
    getNames = function() return {} end,
    isPresent = function() return false end,
    getType = function() return nil end,
    getMethods = function() return {} end,
    wrap = function() return nil end
  }
end

local function install_os()
  _G.os = _G.os or {}
  _G.os.clock = _G.os.clock or function() return 0 end
  _G.os.startTimer = _G.os.startTimer or function() return 0 end
  _G.os.pullEvent = _G.os.pullEvent or function() return "terminate" end
end

local function install_shell()
  if _G.shell then return end
  _G.shell = { run = function() return true end }
end

function bootstrap.install()
  install_os()
  install_fs()
  install_textutils()
  install_peripheral()
  install_shell()
  return true
end

bootstrap.install()

return bootstrap
