










local json=require("src.shared.json")
local safe_write=require("src.shared.safe_write")

local monitor_registry={}

monitor_registry.DEFAULT_PATH="state/panel_monitors.json"
monitor_registry.VIEWS={overview=true,gleisbild=true,trains=true,train_detail=true,trip_assistant=true,stations=true,depots=true,timetable=true,cargo=true,fault_center=true,nodes=true,maintenance=true,audit=true}
local SELECTION_KEYS={train=true,station=true,section=true}

local function sorted_keys(t)
local keys={}
for key in pairs(t or{})do keys[#keys+1]=key end
table.sort(keys,function(a,b)return tostring(a)<tostring(b)end)
return keys
end

local function copy(record)
local out={}
for k,v in pairs(record)do out[k]=v end
return out
end

function monitor_registry.new(opts)
opts=opts or{}
local self={}
local path=opts.path or monitor_registry.DEFAULT_PATH
local io_opts={fs=opts.fs}
local api=opts.peripheral
local records,groups,selections,by_peripheral={},{},{},{}

local function rebuild()
by_peripheral={}
for id,record in pairs(records)do by_peripheral[record.peripheral]=id end
end

local function persist(rec,grp)
local list={}
for _,id in ipairs(sorted_keys(rec))do list[#list+1]=rec[id] end
return safe_write.write(path,json.encode({v=1,node_id=opts.node_id,monitors=list,groups=grp,selections=selections}),io_opts)
end

local function change(modify)
local rec,grp={},{}
for id,record in pairs(records)do rec[id]=record end
for id,group in pairs(groups)do grp[id]=group end
modify(rec,grp)
local ok,err=persist(rec,grp)
if not ok then return false,"could not be written: " .. tostring(err)end
records,groups=rec,grp
rebuild()
return true
end

function self.load()
records,groups,selections={},{},{}
rebuild()
local body,err=safe_write.read_with_backup(path,io_opts)
if not body then
if err=="missing" then return "empty" end
return "corrupt",err
end
local ok,decoded=pcall(json.decode,body)
if not ok or type(decoded)~="table" or type(decoded.monitors)~="table" then return "corrupt","monitor file is not readable" end
for _,record in ipairs(decoded.monitors)do
if type(record)=="table" and type(record.logical_id)=="string" and type(record.peripheral)=="string" and not records[record.logical_id] then records[record.logical_id]=record end
end
for id,group in pairs(decoded.groups or{})do groups[id]=group end
for id,selection in pairs(decoded.selections or{})do selections[id]=selection end
rebuild()
return "ready"
end

local function present()
local out={}
if not api then return out end
local okn,names=pcall(api.getNames)
if not okn or type(names)~="table" then return out end
for _,name in ipairs(names)do
local okt,ptype=pcall(api.getType,name)
if okt and type(ptype)=="string" and ptype:lower():find("monitor",1,true)then out[name]=ptype end
end
return out
end

function self.discover()
local list={}
for _,name in ipairs(sorted_keys(present()))do list[#list+1]={name=name}end
return list
end

function self.identify(name,text)
if not present()[name] then return false,"no monitor " .. tostring(name)end
local okw,monitor=pcall(api.wrap,name)
if not okw or not monitor then return false,"monitor cannot be opened" end
pcall(monitor.setTextScale,5)
pcall(monitor.clear)
pcall(monitor.setCursorPos,1,1)
pcall(monitor.write,tostring(text))
return true
end

function self.verify()
local seen=present()
local report={ok=true,missing={},unbound={}}
for _,id in ipairs(sorted_keys(records))do
if not seen[records[id].peripheral] then report.missing[id]=records[id].peripheral;report.ok=false end
end
for _,name in ipairs(sorted_keys(seen))do
if not by_peripheral[name] then report.unbound[#report.unbound+1]=name;report.ok=false end
end
return report
end

local function check(logical_id,name,meta)
if type(logical_id)~="string" or logical_id=="" then return false,"monitor id missing" end
if not(meta and meta.confirmed==true)then return false,"binding needs the confirmation of the operator" end
if not present()[name] then return false,"monitor " .. tostring(name).. " is not there" end
if meta.scale~=nil and(type(meta.scale)~="number" or meta.scale<0.5 or meta.scale>5 or(meta.scale*2)%1~=0)then return false,"scale must be 0.5 to 5 in steps of 0.5" end
if meta.start_view~=nil and not monitor_registry.VIEWS[meta.start_view] then return false,"unknown start view " .. tostring(meta.start_view)end
return true
end

local function make(logical_id,name,meta,replaced_from)
return{logical_id=logical_id,peripheral=name,label=meta.label or logical_id,scale=meta.scale or 1,start_view=meta.start_view or "overview",replaced_from=replaced_from}
end

function self.bind(logical_id,name,meta)
local ok,err=check(logical_id,name,meta)
if not ok then return false,err end
if records[logical_id] then return false,"monitor " .. logical_id .. " is already bound to " .. records[logical_id].peripheral end
if by_peripheral[name] then return false,"peripheral " .. name .. " is already bound to " .. by_peripheral[name] end
return change(function(rec)rec[logical_id]=make(logical_id,name,meta)end)
end

function self.replace(logical_id,name,meta)
local ok,err=check(logical_id,name,meta)
if not ok then return false,err end
local old=records[logical_id]
if not old then return false,"monitor " .. logical_id .. " is not bound" end
if by_peripheral[name] and by_peripheral[name]~=logical_id then return false,"peripheral " .. name .. " is already bound to " .. by_peripheral[name] end
return change(function(rec)rec[logical_id]=make(logical_id,name,meta,old.peripheral)end)
end

function self.unbind(logical_id)
if not records[logical_id] then return false,"monitor is not bound" end
return change(function(rec,grp)
rec[logical_id]=nil
for gid,group in pairs(grp)do
local kept={}
for _,member in ipairs(group.members)do if member~=logical_id then kept[#kept+1]=member end end
grp[gid]={members=kept}
end
end)
end

function self.get(id)return records[id] and copy(records[id])or nil end

function self.list()
local out={}
for _,id in ipairs(sorted_keys(records))do out[#out+1]=copy(records[id])end
return out
end

function self.resolve(id)
local record=records[id]
if not record then return nil,"monitor " .. tostring(id).. " is not bound" end
if not present()[record.peripheral] then return nil,"monitor " .. record.peripheral .. " is missing" end
local okw,monitor=pcall(api.wrap,record.peripheral)
if not okw or not monitor then return nil,"monitor cannot be opened" end
return monitor
end

function self.open(id)
local monitor,why=self.resolve(id)
if not monitor then return nil,why end
local record=records[id]
pcall(monitor.setTextScale,record.scale)
return monitor,record.start_view
end

local function update(id,field,value)
if not records[id] then return false,"monitor is not bound" end
return change(function(rec)local r=copy(rec[id]);r[field]=value;rec[id]=r end)
end

function self.set_label(id,label)if type(label)~="string" or label=="" then return false end return update(id,"label",label)end
function self.set_scale(id,scale)
if type(scale)~="number" or scale<0.5 or scale>5 or(scale*2)%1~=0 then return false,"scale must be 0.5 to 5 in steps of 0.5" end
return update(id,"scale",scale)
end
function self.set_start_view(id,view)
if not monitor_registry.VIEWS[view] then return false,"unknown view " .. tostring(view)end
return update(id,"start_view",view)
end


function self.group_of(id)
for gid,group in pairs(groups)do for _,member in ipairs(group.members)do if member==id then return gid end end end
return nil
end

function self.define_group(group_id,members)
if type(group_id)~="string" or group_id=="" or type(members)~="table" or#members<2 then return false,"a group needs an id and at least two monitors" end
for _,id in ipairs(members)do
if not records[id] then return false,"monitor " .. tostring(id).. " is not bound" end
local existing=self.group_of(id)
if existing and existing~=group_id then return false,"monitor " .. id .. " is in group " .. existing end
end
local list={}
for i,id in ipairs(members)do list[i]=id end
return change(function(_,grp)grp[group_id]={members=list}end)
end

function self.dissolve_group(group_id)
if not groups[group_id] then return false end
selections[group_id]=nil
return change(function(_,grp)grp[group_id]=nil end)
end

function self.group_members(group_id)return groups[group_id] and copy(groups[group_id].members)or nil end

function self.set_selection(group_id,key,value)
if not groups[group_id] then return false,"unknown group" end
if not SELECTION_KEYS[key] then return false,"a group shares train, station or section, nothing else" end
selections[group_id]=selections[group_id] or{}
selections[group_id][key]=value
return change(function()end)
end

function self.get_selection(id,key)
local gid=self.group_of(id)
return gid and selections[gid] and selections[gid][key] or nil
end

return self
end

return monitor_registry
