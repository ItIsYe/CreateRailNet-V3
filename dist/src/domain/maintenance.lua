





local json=require("src.shared.json")
local safe_write=require("src.shared.safe_write")

local time=require("src.shared.time")

local maintenance={}

function maintenance.new(opts)
opts=opts or{}
local io_opts={fs=opts.fs}
local state={
enabled=false,
reason=nil,
changed_by=nil,
changed_at=nil
}
local self={}

local function persist()
if not opts.path then return true end
local ok,err=safe_write.write(opts.path,json.encode({v=1,enabled=state.enabled,reason=state.reason,changed_by=state.changed_by,changed_at=state.changed_at}),io_opts)
return ok,err
end

function self.load()
if not opts.path then return "memory" end
local body,err=safe_write.read_with_backup(opts.path,io_opts)
if not body then
if err=="missing" then return "empty" end
state.enabled,state.reason=true,"Sperrdatei nicht lesbar"
return "corrupt",err
end
local ok,decoded=pcall(json.decode,body)
if not ok or type(decoded)~="table" then
state.enabled,state.reason=true,"Sperrdatei nicht lesbar"
return "corrupt","not valid json"
end
state.enabled,state.reason,state.changed_by,state.changed_at=decoded.enabled==true,decoded.reason,decoded.changed_by,decoded.changed_at
return "loaded"
end

function self.enable(reason,actor)
state.enabled=true
state.reason=reason or "maintenance"
state.changed_by=actor
state.changed_at=time.now_s()
return persist()
end

function self.disable(actor)
state.enabled=false
state.reason=nil
state.changed_by=actor
state.changed_at=time.now_s()
return persist()
end

function self.is_locked()
return state.enabled
end

function self.status()
return{
enabled=state.enabled,
reason=state.reason,
changed_by=state.changed_by,
changed_at=state.changed_at
}
end

return self
end

return maintenance
