









local startup_template=require("src.shared.startup_template")
local safe_write=require("src.shared.safe_write")

local startup_guard={}

function startup_guard.ensure(opts)
local o=opts or{}
local logger=o.logger
local function note(level,text,data)if logger and logger[level] then pcall(logger[level],text,data)end end
if o.enabled==false then return "skipped","disabled" end
local path=o.path or "startup.lua"
local fs_opts={fs=o.fs}

local ok,status,detail=pcall(function()
local text,read_err=safe_write.read(path,fs_opts)
if not text then return "skipped",read_err or "no startup.lua" end
local upgraded,result=startup_template.upgrade(text)
if not upgraded then return "unrecognized",result end
if result=="current" then return "current" end
local written,write_err=safe_write.write(path,upgraded,fs_opts)
if not written then return "error",write_err end
return "upgraded"
end)
if not ok then
note("warn","startup.lua check failed",{error=tostring(status)})
return "error",tostring(status)
end
if status=="upgraded" then note("info","startup.lua got the OTA recovery block (old copy: startup.lua.prev); active from the next boot")
elseif status=="unrecognized" then note("warn","startup.lua has no OTA recovery and was not changed: " .. tostring(detail).. " (see docs/OTA.md)")
elseif status=="error" then note("warn","startup.lua could not be upgraded",{error=tostring(detail)})end
return status,detail
end

return startup_guard
