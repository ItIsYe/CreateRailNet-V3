














local status_model={}

local DEFAULT_CRITICAL={signal=true,switch=true,sensor=true}

local function is_down(node)
local status=node.status or node.state or "up"
return status=="down" or status=="DOWN" or status=="OFFLINE"
end

local function sorted_keys(t)
local keys={}
for key in pairs(t or{})do keys[#keys+1]=key end
table.sort(keys,function(a,b)return tostring(a)<tostring(b)end)
return keys
end

local function maintenance_on(maintenance)
if not maintenance then return false end
if maintenance.is_locked then return maintenance.is_locked()==true end
if maintenance.status then return maintenance.status().enabled==true end
return maintenance.enabled==true
end


function status_model.collect(sources)
local src=sources or{}
local recovery=src.recovery and src.recovery()or nil
local manager=src.ota and src.ota()or nil
return{
nodes=src.registry and src.registry.all and src.registry.all()or{},
blocks=src.dispatcher and src.dispatcher.get_overview and src.dispatcher.get_overview()or{},
deadlocks=src.dispatcher and src.dispatcher.get_deadlocks and src.dispatcher.get_deadlocks()or{},
maintenance=maintenance_on(src.maintenance),
recovery_required=recovery~=nil and recovery.required==true and recovery.confirmed~=true,
ota=manager and manager.status and manager.status()or{}
}
end

function status_model.build(inputs)
local input=inputs or{}
local critical=input.critical_roles or DEFAULT_CRITICAL
local model={lamp="GREEN",reasons={},nodes={total=0,up=0,down=0},blocks={total=0,fault=0},roles={},problems={}}

local role_rows={}
local down_critical,down_other=0,0
for _,id in ipairs(sorted_keys(input.nodes))do
local node=input.nodes[id]
local role=tostring(node.role or "unknown")
local row=role_rows[role]
if not row then
row={role=role,total=0,up=0,down=0,critical=critical[role]==true,color="GREEN"}
role_rows[role]=row
end
row.total=row.total+1
model.nodes.total=model.nodes.total+1
if is_down(node)then
row.down=row.down+1
model.nodes.down=model.nodes.down+1
if row.critical then down_critical=down_critical+1 else down_other=down_other+1 end
model.problems[#model.problems+1]={severity=row.critical and "RED" or "YELLOW",kind="node",id=id,text=id .. " (" .. role .. ") antwortet nicht"}
else
row.up=row.up+1
model.nodes.up=model.nodes.up+1
end
end
for _,role in ipairs(sorted_keys(role_rows))do
local row=role_rows[role]
if row.down>0 then row.color=row.critical and "RED" or "YELLOW" end
model.roles[#model.roles+1]=row
end

local fault_blocks=0
for _,id in ipairs(sorted_keys(input.blocks))do
model.blocks.total=model.blocks.total+1
if input.blocks[id].state=="FAULT" then
fault_blocks=fault_blocks+1
model.problems[#model.problems+1]={severity="RED",kind="block",id=id,text="Block " .. id .. " gestoert"}
end
end
model.blocks.fault=fault_blocks

local ota_failed,ota_running=0,0
for _,item in ipairs(input.ota or{})do
if item.state=="FAILED" then
ota_failed=ota_failed+1
model.problems[#model.problems+1]={severity="RED",kind="ota",id=item.node_id,text="Update " .. tostring(item.node_id).. ": " .. tostring(item.error or "fehlgeschlagen")}
elseif item.state=="UNCONFIRMED" then
model.problems[#model.problems+1]={severity="YELLOW",kind="ota",id=item.node_id,text="Update " .. tostring(item.node_id).. " nicht bestaetigt"}
ota_running=ota_running+1
elseif item.state~="CONFIRMED" then
ota_running=ota_running+1
end
end

local deadlock_count=0
for _ in pairs(input.deadlocks or{})do deadlock_count=deadlock_count+1 end


local function add(severity,text)
model.reasons[#model.reasons+1]=text
if severity=="RED" then model.lamp="RED" elseif model.lamp~="RED" then model.lamp="YELLOW" end
end
if down_critical>0 then add("RED",down_critical .. " kritische Node(s) ausgefallen")end
if fault_blocks>0 then add("RED",fault_blocks .. " Block/Bloecke gestoert")end
if input.recovery_required then add("RED","Wiederanlauf wartet auf Bestaetigung")end
if ota_failed>0 then add("RED",ota_failed .. " Update(s) fehlgeschlagen")end
if down_other>0 then add("YELLOW",down_other .. " Node(s) ausgefallen")end
if deadlock_count>0 then add("YELLOW",deadlock_count .. " Zug/Zuege warten ohne Aussicht")end
if input.maintenance then add("YELLOW","Wartungsmodus aktiv")end
if ota_running>0 then add("YELLOW","Update laeuft (" .. ota_running .. ")")end

if input.recovery_required then
model.problems[#model.problems+1]={severity="RED",kind="recovery",id="recovery",text="Wiederanlauf: Zustand pruefen und bestaetigen"}
end
table.sort(model.problems,function(a,b)
if a.severity~=b.severity then return a.severity=="RED" end
if a.kind~=b.kind then return a.kind<b.kind end
return tostring(a.id)<tostring(b.id)
end)
return model
end

return status_model
