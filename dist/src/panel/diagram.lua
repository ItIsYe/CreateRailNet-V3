












local json=require("src.shared.json")
local safe_write=require("src.shared.safe_write")

local diagram={}

local SPACING_X,SPACING_Y=12,4

local function sorted_keys(t)
local keys={}
for key in pairs(t or{})do keys[#keys+1]=key end
table.sort(keys,function(a,b)return tostring(a)<tostring(b)end)
return keys
end

local function copy(value)
if type(value)~="table" then return value end
local out={}
for k,v in pairs(value)do out[k]=copy(v)end
return out
end

local function block_ids(graph)return sorted_keys(graph.blocks)end

local function links_of(graph)
local out={}
for _,from in ipairs(block_ids(graph))do
for _,to in ipairs(graph.successors(from))do out[#out+1]={from=from,to=to}end
end
return out
end

local function new_object(graph,id,x,y)
local def=graph.blocks[id] or{}
return{id=id,kind="block",x=x,y=y,label=id,layer="network",entry_signal=def.entry_signal,exit_signal=def.exit_signal}
end

function diagram.propose(graph)
local ids=block_ids(graph)
local layer={}
for _,id in ipairs(ids)do layer[id]=0 end
for _=1,#ids do
local changed=false
for _,id in ipairs(ids)do
for _,pred in ipairs(graph.predecessors(id))do
if layer[pred]+1>layer[id] and layer[pred]+1<=#ids then layer[id]=layer[pred]+1;changed=true end
end
end
if not changed then break end
end
local rows={}
local layout={topology_version=graph.version,objects={},links=links_of(graph),viewports={}}
for _,id in ipairs(ids)do
rows[layer[id]]=(rows[layer[id]] or -1)+1
layout.objects[id]=new_object(graph,id,2+layer[id]*SPACING_X,2+rows[layer[id]]*SPACING_Y)
end
return layout
end

local function is_number(v)return type(v)=="number" and v==v and v>=0 end

function diagram.editor(active_layout,graph,opts)
opts=opts or{}
local self={}
local active=copy(active_layout)
local previous
local draft=copy(active_layout)
local previewed=false

local function touch()previewed=false end

function self.draft()return draft end
function self.active()return active end
function self.previous()return previous end

function self.move(id,x,y)
if not graph.blocks[id] or not draft.objects[id] then return false,"object " .. tostring(id).. " is not in the graph" end
if not is_number(x)or not is_number(y)then return false,"position must be numbers >= 0" end
draft.objects[id].x,draft.objects[id].y=x,y
touch()
return true
end

function self.label(id,text)
if not draft.objects[id] then return false,"object " .. tostring(id).. " is not in the graph" end
if type(text)~="string" or text=="" then return false,"label must be text" end
draft.objects[id].label=text
touch()
return true
end

function self.set_layer(id,layer)
if not draft.objects[id] then return false,"object " .. tostring(id).. " is not in the graph" end
if type(layer)~="string" or layer=="" then return false,"layer must be a name" end
draft.objects[id].layer=layer
touch()
return true
end

function self.define_viewport(name,rect,monitor)
if type(name)~="string" or name=="" then return false,"viewport needs a name" end
if type(rect)~="table" or not is_number(rect.x)or not is_number(rect.y)or not is_number(rect.w)or not is_number(rect.h)or rect.w<=0 or rect.h<=0 then return false,"viewport needs x, y, w > 0, h > 0" end
draft.viewports[name]={x=rect.x,y=rect.y,w=rect.w,h=rect.h,monitor=monitor}
touch()
return true
end

function self.validate()
local problems={}
if draft.topology_version~=graph.version then problems[#problems+1]="the draft is for topology " .. tostring(draft.topology_version).. ", the graph is " .. tostring(graph.version)end
for _,id in ipairs(sorted_keys(draft.objects))do
if not graph.blocks[id] then problems[#problems+1]="object " .. id .. " is not in the graph" end
end
for _,id in ipairs(block_ids(graph))do
if not draft.objects[id] then problems[#problems+1]="block " .. id .. " has no object in the draft" end
end
if opts.monitors then
for _,name in ipairs(sorted_keys(draft.viewports))do
local monitor=draft.viewports[name].monitor
if monitor~=nil and not opts.monitors[monitor] then problems[#problems+1]="viewport " .. name .. " names the unknown monitor " .. tostring(monitor)end
end
end
return{ok=#problems==0,problems=problems}
end

function self.preview()
local result={moved=0,relabeled=0,added=0,removed=0,changed_objects={}}
local seen={}
for _,id in ipairs(sorted_keys(draft.objects))do
local new,old=draft.objects[id],active.objects[id]
if not old then
result.added=result.added+1;seen[id]=true
else
local moved=new.x~=old.x or new.y~=old.y
local relabeled=new.label~=old.label or new.layer~=old.layer
if moved then result.moved=result.moved+1 end
if relabeled then result.relabeled=result.relabeled+1 end
if moved or relabeled then seen[id]=true end
end
end
for id in pairs(active.objects)do if not draft.objects[id] then result.removed=result.removed+1;seen[id]=true end end
result.changed_objects=sorted_keys(seen)
previewed=true
return result
end

function self.publish(confirmation)
if not(type(confirmation)=="table" and confirmation.confirmed==true)then return false,"publishing needs an explicit confirmation" end
if not previewed then return false,"show the preview first" end
local report=self.validate()
if not report.ok then return false,"the draft does not fit the graph: " .. report.problems[1] end
previous=active
active=copy(draft)
draft=copy(active)
previewed=false
return true
end

function self.rollback(current_graph)
if not previous then return false,"there is no previous layout" end
if previous.topology_version~=current_graph.version then return false,"the topology changed since that layout: it is not brought back silently" end
active=previous
draft=copy(active)
previous=nil
previewed=false
return true
end

return self
end

function diagram.carry_over(layout,old_graph,new_graph)
local result={layout={topology_version=new_graph.version,objects={},links=links_of(new_graph),viewports=copy(layout.viewports)},added={},changed={},removed={}}
local proposal=diagram.propose(new_graph)
local occupied={}
local function free_spot(x,y)
local key=x .. ":" .. y
while occupied[key] do y=y+SPACING_Y;key=x .. ":" .. y end
return x,y
end
for _,id in ipairs(block_ids(new_graph))do
local old=layout.objects[id]
if old then
local object=copy(old)
object.entry_signal,object.exit_signal=(new_graph.blocks[id] or{}).entry_signal,(new_graph.blocks[id] or{}).exit_signal
if new_graph.signatures[id]~=old_graph.signatures[id] then object.changed=true;result.changed[#result.changed+1]=id else object.changed=nil end
result.layout.objects[id]=object
occupied[object.x .. ":" .. object.y]=true
end
end
for _,id in ipairs(block_ids(new_graph))do
if not layout.objects[id] then
local x,y=free_spot(proposal.objects[id].x,proposal.objects[id].y)
local object=new_object(new_graph,id,x,y)
object.new=true
result.layout.objects[id]=object
occupied[x .. ":" .. y]=true
result.added[#result.added+1]=id
end
end
for _,id in ipairs(sorted_keys(layout.objects))do if not new_graph.blocks[id] then result.removed[#result.removed+1]=id end end
return result
end

function diagram.render_model(layout,state)
local items={}
local now=state.now or 0
local stale_after=state.stale_after or 30
for _,id in ipairs(sorted_keys(layout.objects))do
local object=layout.objects[id]
local block=(state.blocks or{})[id] or{}
local proof=block.proof
local occupancy=(proof and proof.state)or "UNKNOWN"
local certainty="none"
if proof and proof.state~="UNKNOWN" and proof.at then certainty=((now - proof.at)<=stale_after)and "fresh" or "stale" end
local signals=state.signals or{}
items[#items+1]={
id=id,x=object.x,y=object.y,label=object.label,layer=object.layer,occupancy=occupancy,
reserved_by=block.reserved_by,train=(occupancy=="OCCUPIED_PROVEN")and block.occupied_by or nil,fault=block.state=="FAULT",
signals={entry=signals[object.entry_signal or ""] or "UNKNOWN",exit=signals[object.exit_signal or ""] or "UNKNOWN"},certainty=certainty
}
end
return items
end

function diagram.store(opts)
opts=opts or{}
local self={}
local path=opts.path or "state/panel_layout.json"
local io_opts={fs=opts.fs}
local loaded
function self.load()
loaded=nil
local body,err=safe_write.read_with_backup(path,io_opts)
if not body then
if err=="missing" then return "empty" end
return "corrupt",err
end
local ok,decoded=pcall(json.decode,body)
if not ok or type(decoded)~="table" or type(decoded.active)~="table" then return "corrupt","layout file is not readable" end
loaded=decoded
return "ready"
end
function self.save(data)
local ok,err=safe_write.write(path,json.encode({v=1,active=data.active,previous=data.previous,draft=data.draft}),io_opts)
if ok then loaded={active=data.active,previous=data.previous,draft=data.draft}end
return ok,err
end
function self.data()return loaded end
return self
end

return diagram
