















local json=require("src.shared.json")
local safe_write=require("src.shared.safe_write")

local update_control={}

local NOT_CRITICAL={panel=true,train=true}

function update_control.new(opts)
opts=opts or{}
local now=opts.now or function()return 0 end
local path=opts.path or "state/update_plan.json"
local io_opts={fs=opts.fs}
local config=opts.config or{}
local nodes={}
local self={}

local function role_of(node_id)
for _,node in ipairs(config.nodes or{})do if node.id==node_id then return node.role end end
return nil
end
local function critical(node_id)return not NOT_CRITICAL[role_of(node_id)or "unknown"] end

local function save()
return safe_write.write(path,json.encode({v=1,nodes=nodes}),io_opts)
end

local function lock(node_id,reason)
local rec=nodes[node_id] or{}
nodes[node_id]=rec
rec.locked,rec.lock_reason,rec.state=true,reason,"LOCKED"
if opts.on_lock then opts.on_lock(node_id,reason)end
end

function self.load()
nodes={}
local body,err=safe_write.read_with_backup(path,io_opts)
if not body then
if err=="missing" then return "empty" end
for _,node in ipairs(config.nodes or{})do if critical(node.id)then lock(node.id,"Planstand nicht lesbar")end end
return "corrupt",err
end
local ok,decoded=pcall(json.decode,body)
if not ok or type(decoded)~="table" or type(decoded.nodes)~="table" then
for _,node in ipairs(config.nodes or{})do if critical(node.id)then lock(node.id,"Planstand nicht lesbar")end end
return "corrupt","plan file is not readable"
end
nodes=decoded.nodes
for node_id,rec in pairs(nodes)do
if rec.state=="ACTIVATING" then lock(node_id,"Neustart waehrend der Aktivierung: gueltiger Slot unbekannt")end
end
save()
return "loaded"
end

function self.prepare(node_id,package)
if type(package)~="table" or type(package.release)~="string" then return false,"bad_package" end
local rec=nodes[node_id] or{}
if rec.locked then return false,"locked" end
nodes[node_id]=rec
rec.state,rec.release,rec.rollback_to,rec.prepared_at="PREPARED",package.release,package.rollback_to,now()
rec.released_by=nil
local ok,err=save()
if not ok then return false,"plan not written: " .. tostring(err)end
return true
end

function self.release_node(node_id,operator,evidence)
local rec=nodes[node_id]
if not rec or rec.state~="PREPARED" then return false,"no prepared update for " .. tostring(node_id)end
if type(operator)~="string" or operator=="" then return false,"operator missing" end
if type(evidence)~="string" or evidence=="" then return false,"evidence of the safe state missing" end
rec.released_by,rec.release_evidence=operator,evidence
return save()
end

function self.is_locked(node_id)
local rec=nodes[node_id]
if rec and rec.locked then return true,rec.lock_reason end
return false
end

function self.check(node_id,o)
local reasons={}
local rec=nodes[node_id]
local function no(text)reasons[#reasons+1]=text end
if not rec or rec.state~="PREPARED" then no("kein vorbereitetes, geprueftes Paket fuer " .. tostring(node_id))end
if rec and rec.locked then no("Wartungssperre: " .. tostring(rec.lock_reason))end
if not(o and o.confirm==true)then no("Betreiberbestaetigung fehlt")end
if critical(node_id)then
if rec and not rec.released_by then no("Freigabe des Knotens (Sicherheit und Wartung) fehlt")end
if opts.busy and opts.busy(node_id)then no("eine aktive Fahrt haengt vom Knoten ab")end
local state=opts.op_state and opts.op_state()
if state=="FAULT_LOCKED" or state=="RECOVERY" then no("Betriebszustand " .. state)end
local role=role_of(node_id)
local ha=opts.ha and opts.ha()or{}
if role=="master" then

if ha.leads~=true then no("nur der gesunde fuehrende Master aktualisiert den anderen: erst die Fuehrung kontrolliert wechseln")end
elseif role=="arbiter" then
if ha.both_masters_healthy~=true then no("Schiedsrichter nur bei zwei gesunden Mastern")end
elseif role=="fleet" and opts.fleet_pairs then
local partner=opts.fleet_pairs.partner_of(node_id)
if partner then
local prec=nodes[partner]
if prec and(prec.state=="ACTIVATING" or prec.state=="TRIAL")then no("der Partner " .. partner .. " wird gerade aktualisiert")end
if prec and prec.locked then no("der Partner " .. partner .. " ist gesperrt")end
local status=opts.fleet_pairs.status(opts.fleet_pairs.pair_of(node_id))
if status and status.alive==false then no("der Partner " .. partner .. " ist nicht erreichbar")end
end
end
end
if#reasons>0 then return false,reasons end
return true
end

function self.begin(node_id,operator)
local rec=nodes[node_id]
if not rec or rec.state~="PREPARED" then return false,"not prepared" end
rec.state,rec.operator,rec.started_at="ACTIVATING",operator,now()
return save()
end

function self.finish(node_id,result)
local rec=nodes[node_id]
if not rec or(rec.state~="ACTIVATING" and rec.state~="TRIAL")then return false,"no activation running" end
if result=="trial" then rec.state="TRIAL";return save()end
if result=="confirmed" then
rec.state,rec.locked,rec.lock_reason="CONFIRMED",nil,nil
else
lock(node_id,result=="rolled_back" and "Rollback: alte Reservierungen werden nicht wiederhergestellt" or "Aktivierung fehlgeschlagen")
end
return save()
end

function self.locks()
local list={}
for node_id,rec in pairs(nodes)do if rec.locked then list[#list+1]={node_id=node_id,reason=rec.lock_reason}end end
table.sort(list,function(a,b)return a.node_id<b.node_id end)
return list
end

function self.unlock(node_id,operator,proof)
local rec=nodes[node_id]
if not rec or not rec.locked then return false,"not locked" end
if type(operator)~="string" or operator=="" then return false,"operator missing" end
if type(proof)~="table" or type(proof.kind)~="string" or type(proof.source)~="string" then return false,"a lock is lifted by a proof (kind and source), not by a click" end
rec.locked,rec.lock_reason,rec.state,rec.unlocked_by=nil,nil,"IDLE",operator
return save()
end

function self.state_of(node_id)return nodes[node_id] end

return self
end

return update_control
