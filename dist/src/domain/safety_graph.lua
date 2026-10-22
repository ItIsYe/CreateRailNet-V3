















local canon=require("src.shared.canon")
local sha256=require("src.shared.sha256")

local safety_graph={}

local function sorted_keys(t)
local keys={}
for key in pairs(t or{})do keys[#keys+1]=key end
table.sort(keys,function(a,b)return tostring(a)<tostring(b)end)
return keys
end

local function copy_list(list)
local out={}
for i,v in ipairs(list or{})do out[i]=v end
return out
end

local function sorted_list(list)
local out=copy_list(list)
table.sort(out,function(a,b)return tostring(a)<tostring(b)end)
return out
end

local function route_groups(route)
local groups={}
if route.conflict_group then groups[#groups+1]=route.conflict_group end
for _,group in ipairs(route.conflict_groups or{})do groups[#groups+1]=group end
return groups
end

function safety_graph.build(config)
config=config or{}
local g={problems={}}
local function problem(severity,code,subject,text)g.problems[#g.problems+1]={severity=severity,code=code,subject=subject,text=text}end

local blocks,order={},{}
for _,def in ipairs(config.blocks or{})do
if blocks[def.id] then
problem("error","duplicate_block",def.id,"block " .. tostring(def.id).. " is defined twice")
else
blocks[def.id]=def
order[#order+1]=def.id
end
end

local stops={}
for _,stop in ipairs(config.safe_stops or{})do
if not blocks[stop.block] then
problem("error","unknown_block",tostring(stop.block),"safe stop at unknown block " .. tostring(stop.block))
else
stops[stop.block]={length=stop.length,proven=stop.proven==true}
end
end

local routes,route_order={},{}
for _,route in ipairs(config.routes or{})do
routes[route.id]=route
route_order[#route_order+1]=route.id
end

local succ,pred={},{}
for _,id in ipairs(order)do succ[id]={};pred[id]={}end
local function add_edge(a,b)
if not succ[a][b] then succ[a][b]=true;pred[b][a]=true end
end
for _,route_id in ipairs(route_order)do
local route=routes[route_id]
local known=true
for _,block_id in ipairs(route.blocks or{})do
if not blocks[block_id] then
known=false
problem("error","unknown_block",tostring(block_id),"route " .. tostring(route_id).. " names unknown block " .. tostring(block_id))
end
end
if known then
for i=1,#(route.blocks or{})- 1 do add_edge(route.blocks[i],route.blocks[i+1])end
end
end

for _,route_id in ipairs(route_order)do
local route=routes[route_id]
for _,alt_id in ipairs(route.alternatives or{})do
local alt=routes[alt_id]
if not alt or alt.from~=route.from or alt.to~=route.to or alt_id==route_id then
problem("error","bad_alternative",route_id,"alternative " .. tostring(alt_id).. " of route " .. tostring(route_id).. " does not run between the same ends")
end
end
end

local function tail_sensors(block_id)
local def=blocks[block_id]
if not def then return{}end
return copy_list(def.tail_sensors or def.sensors)
end
for _,id in ipairs(order)do
if#tail_sensors(id)==0 then problem("warn","no_tail_evidence",id,"block " .. id .. " has no sensor that can prove the end of a train: it can never be proven free")end
end

local flank={}
for _,il in ipairs(config.interlocking_routes or{})do
if il.flank_protection then flank[il.id]=il.flank_protection end
end

g.blocks=blocks
g.stops=stops
g.routes=routes

function g.has_edge(a,b)return succ[a]~=nil and succ[a][b]==true end
function g.successors(id)return sorted_keys(succ[id])end
function g.predecessors(id)return sorted_keys(pred[id])end
function g.tail_sensors(id)return tail_sensors(id)end

function g.reachable(a,b)
if not succ[a] or not succ[b] then return false end
local seen,queue,head={[a]=true},{a},1
while queue[head] do
local current=queue[head];head=head+1
if current==b then return true end
for _,nxt in ipairs(sorted_keys(succ[current]))do
if not seen[nxt] then seen[nxt]=true;queue[#queue+1]=nxt end
end
end
return false
end

function g.next_waypoint(start)
if not succ[start] then return nil end
local seen,queue,head={[start]=true},{start},1
while queue[head] do
local current=queue[head];head=head+1
if stops[current] and stops[current].proven then return current end
for _,nxt in ipairs(sorted_keys(succ[current]))do
if not seen[nxt] then seen[nxt]=true;queue[#queue+1]=nxt end
end
end
return nil
end

function g.provable(id)
if#tail_sensors(id)==0 then return false,"no tail sensor configured for block " .. tostring(id)end
return true
end

local function block_switches(route)
local out={}
for _,block_id in ipairs(route.blocks or{})do
local def=blocks[block_id]
for _,sw in ipairs(def and def.switches or{})do out[tostring(sw.id)]=sw.position end
end
return out
end

function g.routes_conflict(a,b)
local ra,rb=routes[a],routes[b]
if not ra or not rb then return true,"unknown route " .. tostring(ra and b or a)end
local mine={}
for _,id in ipairs(ra.blocks or{})do mine[id]=true end
local shared={}
for _,id in ipairs(rb.blocks or{})do if mine[id] then shared[#shared+1]=id end end
if#shared>0 then
table.sort(shared,function(x,y)return tostring(x)<tostring(y)end)
return true,"shared block(s) " .. table.concat(shared,", ")
end
local sa,sb=block_switches(ra),block_switches(rb)
for _,sw in ipairs(sorted_keys(sa))do
if sb[sw]~=nil and sb[sw]~=sa[sw] then return true,"switch " .. sw .. " is needed in two positions" end
end
local groups={}
for _,group in ipairs(route_groups(ra))do groups[group]=true end
for _,group in ipairs(route_groups(rb))do if groups[group] then return true,"conflict group " .. tostring(group)end end
for _,pair in ipairs({{a,sb},{b,sa}})do
for _,flank_switch in ipairs(flank[pair[1]] or{})do
local position=pair[2][tostring(flank_switch.switch_id)]
if position~=nil and position~=flank_switch.position then return true,"flank switch " .. tostring(flank_switch.switch_id).. " of route " .. tostring(pair[1])end
end
end
return false
end

function g.route_end(route_id,opts)
local route=routes[route_id]
if not route or#(route.blocks or{})==0 then return false,"unknown route " .. tostring(route_id)end
local last=route.blocks[#route.blocks]
local stop=stops[last]
if not stop then return false,"no safe waiting point at the end block " .. tostring(last)end
if not stop.proven then return false,"waiting point " .. tostring(last).. " is not proven yet (stop test missing)" end
local length=opts and opts.length
if length then
if not stop.length then return false,"length of waiting point " .. tostring(last).. " was never measured" end
if length>stop.length then return false,"train too long for waiting point " .. tostring(last).. " (" .. tostring(length).. " > " .. tostring(stop.length).. ")" end
end
return true
end


local function signature(id)
local def=blocks[id]
local sw={}
for _,s in ipairs(def.switches or{})do sw[#sw+1]=tostring(s.id).. "=" .. tostring(s.position)end
table.sort(sw)
local stop=stops[id]
local text=canon.encode({
sensors=sorted_list(def.sensors),tail=sorted_list(def.tail_sensors),switches=sw,
stop=stop and{length=stop.length,proven=stop.proven}or false,
next=sorted_keys(succ[id]),prev=sorted_keys(pred[id])
})
return text
end
g.signatures={}
for _,id in ipairs(order)do g.signatures[id]=signature(id)end

local route_sig={}
for _,route_id in ipairs(route_order)do
local route=routes[route_id]
route_sig[#route_sig+1]={id=route_id,from=route.from or false,to=route.to or false,blocks=copy_list(route.blocks),groups=sorted_list(route_groups(route)),alternatives=sorted_list(route.alternatives)}
end
table.sort(route_sig,function(x,y)return tostring(x.id)<tostring(y.id)end)
local flank_sig={}
for _,id in ipairs(sorted_keys(flank))do
local items={}
for _,f in ipairs(flank[id])do items[#items+1]=tostring(f.switch_id).. "=" .. tostring(f.position)end
table.sort(items)
flank_sig[#flank_sig+1]={id=id,flank=items}
end
local parts={}
for _,id in ipairs(sorted_keys(g.signatures))do parts[#parts+1]={id,g.signatures[id]}end
g.version=sha256.hex(canon.encode({blocks=parts,routes=route_sig,flank=flank_sig})):sub(1,16)
return g
end

function safety_graph.diff(old,new)
local seen,out={},{}
for id,sig in pairs(old.signatures)do
if new.signatures[id]~=sig then seen[id]=true end
end
for id in pairs(new.signatures)do
if old.signatures[id]==nil then seen[id]=true end
end
for id in pairs(seen)do out[#out+1]=id end
table.sort(out,function(a,b)return tostring(a)<tostring(b)end)
return out
end

return safety_graph
