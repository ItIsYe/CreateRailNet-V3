












local offline={}

local ALWAYS={read=true,edit_draft=true}
local ONLINE_ONLY={publish=true,control=true,maintenance=true}

function offline.new(opts)
opts=opts or{}
local now=opts.now or function()return 0 end
local timeout=opts.timeout_s or 10
local stale_after=opts.stale_after_s or 30
local self={}
local state="OFFLINE"
local last_heard
local was_online=false
local wishes={}
local bases={}
local local_topology
local conflicts={}
local pending_master
local epoch

function self.state()return state end

function self.set_base(what,version)bases[what]=version end
function self.set_topology(version)local_topology=version end
function self.master_epoch()return epoch end

function self.heard(info,o)
if type(info)~="table" or info.authenticated~=true then return end
if o and o.expected_master and info.id~=o.expected_master then return end
last_heard=now()
if state=="OFFLINE" then
if was_online or#wishes>0 or next(bases)~=nil then
state="RECONCILING"
else
state="ONLINE"
epoch=info.epoch
end
end
end

function self.tick()
if state~="OFFLINE" and last_heard and(now()- last_heard)>timeout then
state="OFFLINE"
was_online=true
conflicts,pending_master={},nil
end
end

function self.may(kind)
if ALWAYS[kind] then return true end
if ONLINE_ONLY[kind] then
if state=="ONLINE" then return true end
return false,"the panel is offline or not yet reconciled with the master: " .. kind .. " is not possible"
end
return false,"unknown kind " .. tostring(kind)
end

function self.wish(action,send)
if state=="ONLINE" and send then return send(action)==true end
wishes[#wishes+1]=action
return false
end

function self.wishes()
local out={}
for i,w in ipairs(wishes)do out[i]=w end
return out
end

function self.begin_reconcile(master_info,local_versions)
local result={conflicts={},discarded_wishes=self.wishes()}
wishes={}
local versions=local_versions or bases
local theirs=master_info.versions or{}
local kinds={}
for what in pairs(versions)do kinds[#kinds+1]=what end
table.sort(kinds)
for _,what in ipairs(kinds)do
if theirs[what]~=nil and versions[what]~=theirs[what] then
result.conflicts[#result.conflicts+1]={what=what,local_version=versions[what],master_version=theirs[what],resolved=false}
end
end
if local_topology~=nil and master_info.topology_version~=nil and local_topology~=master_info.topology_version then
result.conflicts[#result.conflicts+1]={what="topology",local_version=local_topology,master_version=master_info.topology_version,resolved=false}
end
conflicts,pending_master=result.conflicts,master_info
state="RECONCILING"
return result
end

function self.resolve(what,choice)
for _,conflict in ipairs(conflicts)do
if conflict.what==what then conflict.resolved,conflict.choice=true,choice;return true end
end
return false
end

function self.finish(confirmation,permission_check)
if not pending_master then return false,"reconcile first" end
for _,conflict in ipairs(conflicts)do
if not conflict.resolved then return false,"conflict about " .. conflict.what .. " is not resolved" end
end
if not(type(confirmation)=="table" and confirmation.confirmed==true)then return false,"the operator has to confirm anew" end
local ok,why=permission_check()
if not ok then return false,tostring(why or "permission check failed")end
epoch=pending_master.epoch
state,conflicts,pending_master="ONLINE",{},nil
last_heard=now()
return true
end

function self.freshness(age)
if age==nil then return{stale=true,label="Alter unbekannt",proof=false}end
if age<=stale_after then return{stale=false,label="aktuell",proof=false}end
return{stale=true,label="veraltet (" .. tostring(age).. " s)",proof=false}
end

return self
end

return offline
