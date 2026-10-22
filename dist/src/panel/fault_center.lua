






local fault_center={}

local SEVERITY_RANK={RED=1,YELLOW=2,INFO=3}

function fault_center.new(opts)
opts=opts or{}
local now=opts.now or function()return 0 end
local items={}
local self={}

function self.raise(key,info)
if type(key)~="string" or key=="" then return false,"key missing" end
info=info or{}
local item=items[key]
if item and item.state~="RESOLVED" then
item.count=item.count+1
item.last=now()
if info.message then item.message=info.message end
return true,item
end
local severity=SEVERITY_RANK[info.severity] and info.severity or "YELLOW"
items[key]={key=key,severity=severity,message=info.message or key,source=info.source,state="ACTIVE",count=1,first=now(),last=now()}
return true,items[key]
end

function self.ack(key,who)
local item=items[key]
if not item or item.state=="RESOLVED" then return false,"no open entry " .. tostring(key)end
if item.state=="ACTIVE" then
item.state="ACTIVE_SEEN"
item.acked_by,item.acked_at=who,now()
end
return true
end

function self.resolve(key,proof)
local item=items[key]
if not item or item.state=="RESOLVED" then return false,"no open entry " .. tostring(key)end
if type(proof)~="table" or type(proof.kind)~="string" or type(proof.source)~="string" then
return false,"a cause is only cleared by a proof (kind and source), not by a click"
end
item.state,item.proof,item.resolved_at="RESOLVED",proof,now()
return true
end



function self.sync(master_list)
local present={}
for _,entry in ipairs(master_list or{})do
if type(entry)=="table" and type(entry.key)=="string" then
present[entry.key]=true
self.raise(entry.key,{severity=entry.severity,message=entry.text or entry.message,source="master"})
if entry.acked then self.ack(entry.key,entry.acked_by)end
end
end
for key,item in pairs(items)do
if item.state~="RESOLVED" and not present[key] then self.resolve(key,{kind="master_cleared_cause",source="master"})end
end
end

function self.get(key)return items[key] end
function self.is_open(key)return items[key]~=nil and items[key].state~="RESOLVED" end

function self.list(opts2)
local out={}
for _,item in pairs(items)do
if item.state~="RESOLVED" or(opts2 and opts2.include_resolved)then out[#out+1]=item end
end
table.sort(out,function(a,b)
if a.severity~=b.severity then return SEVERITY_RANK[a.severity]<SEVERITY_RANK[b.severity] end
if a.state~=b.state then return a.state=="ACTIVE" end
return a.key<b.key
end)
return out
end

function self.counts()
local c={open=0,unseen=0,red=0}
for _,item in pairs(items)do
if item.state~="RESOLVED" then
c.open=c.open+1
if item.state=="ACTIVE" then c.unseen=c.unseen+1 end
if item.severity=="RED" then c.red=c.red+1 end
end
end
return c
end

return self
end

return fault_center
