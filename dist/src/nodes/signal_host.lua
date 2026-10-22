











local create_signals=require("src.adapter.create_signals")

local signal_host={}

local function sorted_keys(t)
local keys={}
for key in pairs(t or{})do keys[#keys+1]=key end
table.sort(keys,function(a,b)return tostring(a)<tostring(b)end)
return keys
end

function signal_host.new(opts)
local bindings,per,logger=opts.bindings,opts.peripherals,opts.logger
local self={}
local last={}

local resolver={
adapter=function()return "peripheral" end,
target=function(id)return bindings.resolve(id)or id end,
side=function()return nil end
}
local adapter=create_signals.new(per,{hardware=resolver})

local function present()
local out={}
for _,name in ipairs(per.list()or{})do out[name]=per.get_type(name)or "unknown" end
return out
end

local function expected_set()
if not opts.expected then return nil end
local set={}
for _,id in ipairs(opts.expected)do set[id]=true end
return set
end


local function state_of(id,seen,expected)
if expected and not expected[id] then return "UNKNOWN","the master does not know signal " .. id end
local usable,why=bindings.is_usable(id,seen)
if usable then return "OK" end
if why:find("missing",1,true)then return "MISSING",why end
return "TYPE",why
end

function self.set_aspect(logical_id,aspect)
local expected=expected_set()
if not bindings.resolve(logical_id)then
if logger then logger.warn("signal command for a signal that is not bound",{signal=logical_id})end
return false,"signal " .. tostring(logical_id).. " is not bound on this node"
end
local state,why=state_of(logical_id,present(),expected)
if state~="OK" then
last[logical_id]=nil
if state=="UNKNOWN" then return false,"the master does not know this signal: " .. tostring(why)end
return false,tostring(why)
end
local ok,ok_or_err,err=pcall(adapter.setAspect,logical_id,aspect)
if not ok then last[logical_id]=nil;return false,tostring(ok_or_err)end
if ok_or_err==false then last[logical_id]=nil;return false,tostring(err)end
last[logical_id]=aspect
return true
end

function self.all_red()
local failed={}
for _,record in ipairs(bindings.list())do
local ok=self.set_aspect(record.logical_id,"RED")
if not ok then failed[#failed+1]=record.logical_id end
end
return#failed==0,failed
end

function self.status()
local seen,expected=present(),expected_set()
local report=bindings.verify(seen)
local status={ok=report.ok,signals={},unbound=report.unbound}
for _,record in ipairs(bindings.list())do
local state,why=state_of(record.logical_id,seen,expected)
if state~="OK" then last[record.logical_id]=nil;status.ok=false end
status.signals[record.logical_id]={state=state,last=last[record.logical_id],peripheral=record.peripheral,reason=why}
end
if opts.expected then
status.topology=bindings.compare_topology(opts.expected)
if not status.topology.ok then status.ok=false end
end
return status
end

function self.brief()
local status=self.status()
local out={}
for id,entry in pairs(status.signals)do out[id]=entry.state end
if status.topology then for _,id in ipairs(status.topology.unbound)do out[id]="UNBOUND" end end
return out
end

return self
end

return signal_host
