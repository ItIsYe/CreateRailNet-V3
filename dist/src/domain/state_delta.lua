








local state_delta={}

local MAP_KEYS={blocks=true,trains=true,active_conflicts=true}

local function copy(value)
if type(value)~="table" then return value end
local out={}
for k,v in pairs(value)do out[k]=copy(v)end
return out
end
state_delta.copy=copy

local function equal(a,b)
if a==b then return true end
if type(a)~="table" or type(b)~="table" then return false end
for k,v in pairs(a)do if not equal(v,b[k])then return false end end
for k in pairs(b)do if a[k]==nil then return false end end
return true
end
state_delta.equal=equal

function state_delta.diff(old,new)
old,new=old or{},new or{}
local delta={map={},whole={},removed={}}
local changed=false
for key,value in pairs(new)do
local before=old[key]
if MAP_KEYS[key] and type(value)=="table" and type(before)=="table" then
local set,del={},{}
local any=false
for id,record in pairs(value)do
if not equal(before[id],record)then set[id]=copy(record);any=true end
end
for id in pairs(before)do
if value[id]==nil then del[#del+1]=id;any=true end
end
if any then
table.sort(del)
delta.map[key]={set=set,del=del}
changed=true
end
elseif not equal(before,value)then
delta.whole[key]=copy(value)
changed=true
end
end
for key in pairs(old)do
if new[key]==nil then delta.removed[#delta.removed+1]=key;changed=true end
end
if not changed then return nil end
table.sort(delta.removed)
return delta
end

function state_delta.apply(base,delta)
local out={}
for key,value in pairs(base or{})do out[key]=value end
for _,key in ipairs(delta.removed or{})do out[key]=nil end
for key,value in pairs(delta.whole or{})do out[key]=copy(value)end
for key,change in pairs(delta.map or{})do
local records={}
for id,record in pairs(out[key] or{})do records[id]=record end
for _,id in ipairs(change.del or{})do records[id]=nil end
for id,record in pairs(change.set or{})do records[id]=copy(record)end
out[key]=records
end
return out
end

return state_delta
