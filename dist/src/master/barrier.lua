













local barrier={}

local PERMISSIVE_CMDS={set_position=true,depart_authorized=true,set_schedule=true,set_destination=true,dispatch_train=true}

function barrier.permissive_cmd(payload)
if type(payload)~="table" then return false end
local cmd=payload.cmd
if PERMISSIVE_CMDS[cmd] then return true end
if cmd=="set_aspect" then return payload.aspect~="RED" and payload.aspect~="STOP" and payload.aspect~=false end
return false
end

function barrier.new(opts)
opts=opts or{}
local now_ms=opts.now_ms or function()return 0 end
local logger=opts.logger
local max_items=opts.max_items or 400
local self={}
local items={}
local tag_counter=0

local function remove_key(key)
local removed=0
local kept={}
for _,item in ipairs(items)do
if item.key==key then removed=removed+1 else kept[#kept+1]=item end
end
items=kept
return removed
end

function self.hold(key,run,meta)
remove_key(key)
if#items>=max_items then

table.remove(items,1)
if logger then logger.warn("commit barrier: the queue is full, the oldest actuation was dropped",{max=max_items})end
end
items[#items+1]={key=key,run=run,meta=meta,at=now_ms()}
return true
end

function self.cancel(key)return remove_key(key)end

function self.tag(idx)
tag_counter=0
for _,item in ipairs(items)do
if item.need==nil then
item.need=idx
tag_counter=tag_counter+1
if item.meta and type(item.meta.payload)=="table" then item.meta.payload.command_id=tostring(idx).. "." .. tag_counter end
end
end
end

function self.release(confirmed)
local done=0
while items[1] and items[1].need~=nil and confirmed(items[1].need)do
local item=table.remove(items,1)
local ok,err=pcall(item.run)
if not ok and logger then logger.warn("commit barrier: an actuation failed",{key=item.key,error=tostring(err)})end
done=done+1
end
return done
end

function self.discard(reason)
local n=#items
items={}
if n>0 and logger then logger.warn("commit barrier: waiting actuations dropped",{count=n,reason=reason})end
return n
end

function self.count()return#items end

function self.oldest_age_ms()
if not items[1] then return 0 end
return now_ms()- items[1].at
end

return self
end

return barrier
