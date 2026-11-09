





local registerlib=require("domain.register")
local orderslib=require("domain.orders")
local schedulelib=require("domain.schedule")
local stationslib=require("domain.stations")
local lineslib=require("domain.lines")
local W=require("ui.widgets")
local forms=require("ui.forms")
local netzlib=require("domain.netz")
local model=require("setup.model")
local chunks=require("core.chunks")
local label=require("core.label")
local adler=require("core.adler")
local ser=require("core.ser")

local M={}

local REPLY_WAIT=8
local MAX_TRIES=12
local RETRY_WAITING=10
local DEPART_GRACE=30
local EVENT_KINDS={ankunft=true,abfahrt=true,zug_weg=true,zug_umbenannt=true}
local NODE_SILENT=60

function M.new(node)
local role={}
local now=function()return node.clock.now()end
local DATA="/crn_data"




local epoch_state=node.store.load(DATA.."/epoche.lua")or{n=0}
epoch_state.n=math.max(epoch_state.n+1,node.env.utc_seconds and node.env.utc_seconds()or 0)
node.store.save(DATA.."/epoche.lua",epoch_state)
node.own_epoch=epoch_state.n

role.register=registerlib.new({store=node.store,path=DATA.."/register.lua"})
role.orders=orderslib.new({store=node.store,path=DATA.."/auftraege.lua",now=now})
role.stations=stationslib.new({store=node.store,path=DATA.."/bahnhoefe.lua"})
role.lines=lineslib.new({store=node.store,path=DATA.."/linien.lua",now=now})
role.netz=netzlib.new({store=node.store,path=DATA.."/netz.lua"})
local samples=node.store.load(DATA.."/muster.lua")or{}
local operation=node.store.load(DATA.."/betrieb.lua")or{hold=false}
local retired=node.store.load(DATA.."/stillgelegt.lua")or{}
local later={}
local closed=node.store.load(DATA.."/gesperrt.lua")or{}

local nodes={}
local dir={}
local track_state={}
local pending={}
local waiting={}
local flags={}
local unknown_seen={}
local seen_stay={}
local boots={}
local unknown_trains={}
local silent_notified={}

local function notify(level,text)node.notify(level,text)end


local function held()
if operation.hold then return true,operation.reason or"vom Bediener"end
if node.env_hold then return true,"Umgebung geaendert: Schnittstellen pruefen"end
return false
end

local function rebuild_dir()
dir={}
local ids={}
for id in pairs(nodes)do ids[#ids+1]=id end
table.sort(ids)
for _,id in ipairs(ids)do
for _,track in ipairs(nodes[id].tracks or{})do
local name=track.station_name
if name then
if dir[name]then dir[name].ambiguous=true else dir[name]={node=id,track=track.id,ambiguous=false}end
end
end
end
end

local function reachable(node_id)
local info=nodes[node_id]
return info~=nil and now()-info.last_seen<NODE_SILENT
end

local function locate(station)
local entry=dir[station]
if not entry then return nil,"Der Bahnhof "..station.." ist unbekannt."end
if entry.ambiguous then return nil,"Der Bahnhofsname "..station.." ist nicht eindeutig."end
if not reachable(entry.node)then return nil,"Der Node "..entry.node.." meldet sich nicht."end
return entry
end


local function ask(node_id,message_type,payload,order,on_reply)
local m=node.send_to(node_id,message_type,payload,{requestId=order and order.id or nil})
if not m then return nil end
pending[m.messageId]={m=m,order=order and order.id or nil,sent=now(),tries=1,on_reply=on_reply,target=node_id}
if order then waiting[order.id]=true end
return m
end

local function release_wait(p)
if p.order then waiting[p.order]=nil;if flags[p.order]then flags[p.order].unconfirmed=nil end end
end

local function to_clarification(order,reason)
local ok=role.orders.transition(order.id,"klaerung",reason)
if ok then notify("warnung","Auftrag "..order.id..": "..reason)end
end

local function check_pending()
local t=now()
local ids={}
for id in pairs(pending)do ids[#ids+1]=id end
table.sort(ids)
for _,id in ipairs(ids)do
local p=pending[id]
if t-p.sent>=REPLY_WAIT then
if p.tries>=MAX_TRIES then
pending[id]=nil
release_wait(p)
local order=p.order and role.orders.get(p.order)
if order then to_clarification(order,"Keine Rueckmeldung von "..p.target.." (Rueckmeldung fehlt).")end
else
p.tries,p.sent=p.tries+1,t
if p.order then flags[p.order]=flags[p.order]or{};flags[p.order].unconfirmed=true end
node.send_message(p.m)
end
end
end
end


local function set_position(train_name,kind,where,source,t)
local train=role.register.by_create_name(train_name)
if not train then return nil end
local pos=train.position
if pos and pos.kind==kind and pos.where==where then return train end
role.register.set_position(train.id,kind,where,source,t)
return train
end


local function entries_of(template)
local list={}
for _,stop in ipairs(template.stops)do list[#list+1]=stop end
if template.return_to_start~=false then
list[#list+1]={station=template.stops[1].station,wait=0}
end
return list
end


local function section_of(order,template,leg)
local entries=entries_of(template)
local from,to=order.plan and order.plan[leg],order.plan and order.plan[leg+1]
if not from or not to then return nil,"Der Auftrag kennt diese Etappe nicht."end
local entry=entries[leg]or{}
return schedulelib.section(from.station,{wait=entry.wait,cargo=entry.cargo},to.station,samples)
end


local function carried_route(order,template,leg)
if leg<2 then return nil end
local previous=section_of(order,template,leg-1)
return previous and schedulelib.route_hash(previous)or nil
end

local function release_message(order,entry,stay)
local train=role.register.get(order.train)
local template=role.orders.template(order.template)
local section,err=section_of(order,template,order.leg)
if not section then return nil,err end
return{kind="freigabe",orderId=order.id,track=entry.track,train=train and train.create_name,stay=stay,wait=order.min_stay or 0,
schedule=section,expect=carried_route(order,template,order.leg)}
end



local function guarded(order,fn)
local state,leg=order.state,order.leg
return function(payload)
if order.state~=state or order.leg~=leg then return end
return fn(payload)
end
end


local drive


local function track_info(create_name,order,train,payload)
local entry=dir[create_name]
if not entry then return{problem="unbekannt"}end
if entry.ambiguous then return{problem="Name nicht eindeutig"}end
if not reachable(entry.node)then return{problem="Node "..entry.node.." meldet sich nicht"}end
if closed[create_name]then return{problem="gesperrt"}end
local tstate=track_state[entry.node..":"..entry.track]
if tstate and tstate.available==false then return{problem="Geraet nicht verfuegbar"}end
local r=payload.reach and payload.reach[create_name]
if r and not r.ok then return{problem="nicht erreichbar"..(r.reason and(" ("..tostring(r.reason)..")")or"")}end
local st=track_state[entry.node..":"..entry.track]
if st and st.present and st.train and st.train~=(train and train.create_name)then return{problem="belegt von "..tostring(st.train)}end
for _,other in ipairs(role.orders.active())do
if other.id~=order.id and other.plan then
for i=math.max(1,(other.leg or 0)+1),#other.plan do
if other.plan[i].station==create_name then return{problem="dem Auftrag "..other.id.." zugewiesen"}end
end
end
end
local length
for _,tr in ipairs(nodes[entry.node].tracks or{})do if tr.id==entry.track then length=tr.length end end
if train and train.length and length and train.length>length then return{problem="zu kurz ("..length.." Wagen, Zug "..train.length..")"}end
return{}
end

local function handle_check_reply(order,payload)
local template=role.orders.template(order.template)
local train=role.register.get(order.train)
local function waiting_for(reason)
role.orders.transition(order.id,"wartend",reason)
end
if payload.status~="ok"then return waiting_for(payload.grund or"Der Bahnhof lehnt die Pruefung ab.")end
if not payload.available then return waiting_for("Der Bahnhof "..payload.station_name.." ist nicht verfuegbar.")end
if not payload.present then return waiting_for("Der Zug fehlt am Startbahnhof.")end
if not train then return waiting_for("Der Zug "..order.train.." ist nicht registriert.")end
if train.state~="gesteuert"or train.mode=="manuell"then
return role.orders.transition(order.id,"abgelehnt","Der Zug "..train.id.." ist nicht im gesteuerten Betrieb ("..train.state..", "..tostring(train.mode)..").")
end
if payload.train~=train.create_name then
return waiting_for("Am Start steht "..tostring(payload.train)..", nicht "..train.create_name..": Identitaet klaeren, kein fremder Fahrplan wird ueberschrieben.")
end
if payload.has_schedule and not payload.waiting_ok then
return to_clarification(order,"Der Zug hat einen unbekannten Fahrplan: Uebergabe noetig.")
end
local entries=entries_of(template)

local plan={{station=payload.station_name,node=order.start.node,track=order.start.track}}
for i=2,#entries do
local candidates=role.stations.candidates(entries[i].station)
local previous=plan[i-1].station
local chosen,reasons=stationslib.choose(candidates,function(name)

if name==previous then return{problem="Zug steht dort schon"}end
return track_info(name,order,train,payload)
end)
if not chosen then
return waiting_for("Kein geeignetes Gleis fuer "..entries[i].station.." ("..table.concat(reasons,"; ")..").")
end
plan[i]={station=chosen,node=dir[chosen].node,track=dir[chosen].track}
end

for i=1,#entries-1 do
local section,err=schedulelib.section(plan[i].station,{wait=entries[i].wait,cargo=entries[i].cargo},plan[i+1].station,samples)
if not section then return role.orders.transition(order.id,"abgelehnt",err)end
local problems=schedulelib.check_section(section)
if#problems>0 then return role.orders.transition(order.id,"abgelehnt",problems[1])end
end
order.schedule=nil
order.plan=plan
order.stay=payload.stay
order.arrivals={[order.start.node..":"..order.start.track]=payload.stay}
order.leg=1
order.min_stay=entries[1].wait or 0
role.orders.save()
role.orders.transition(order.id,"vorbereitet","Zug und Auftrag sind zugeordnet")
end

local function handle_schedule_reply(order,payload)
if payload.status=="zurueckgestellt"then
order.retry_at=now()+(payload.retry_in or 5)
return
end
if payload.status=="uebergeben"then
role.orders.transition(order.id,"fahrplan_uebergeben","Fahrplan uebergeben (Schnittstelle bestaetigt die Uebergabe)")
elseif payload.klaerung then
to_clarification(order,payload.grund or"Fahrplan nicht uebergeben.")
else
role.orders.transition(order.id,"wartend",payload.grund or"Fahrplan nicht uebergeben.")
end
end

local function handle_release_reply(order,payload)
if payload.status=="freigabe_gesetzt"then
role.orders.transition(order.id,"abfahrt_freigegeben","Freigabe gesetzt, Abfahrt noch nicht bestaetigt")
elseif payload.status=="zurueckgestellt"then
order.retry_at=now()+(payload.retry_in or 2)
else
to_clarification(order,"Freigabe abgelehnt: "..tostring(payload.grund))
end
end

local function handle_wait_reply(order,payload)
local train=role.register.get(order.train)
local template=role.orders.template(order.template)
if payload.status=="uebergeben"then
if template and template.kind=="abstellen"then
if train then role.register.set_state(train.id,"abgestellt")end
role.orders.transition(order.id,"abgeschlossen","Abgestellt, Warteauftrag erteilt")
else
if train then role.register.set_state(train.id,"gesteuert")end
role.orders.transition(order.id,"abgeschlossen","Rueckkehr bestaetigt, Warteauftrag erteilt")
end
elseif payload.status=="zurueckgestellt"then
order.retry_at=now()+(payload.retry_in or 5)
else
to_clarification(order,"Warteauftrag am Ziel nicht erteilt: "..tostring(payload.grund))
end
end

drive=function(order)
if waiting[order.id]then return end
local template=role.orders.template(order.template)
if not template then return role.orders.transition(order.id,"abgelehnt","Die Vorlage gibt es nicht mehr.")end
local state=order.state

if held()then
local entries_n=#template.stops+((template.return_to_start~=false)and 1 or 0)
if state=="vorbereitet"or state=="fahrplan_uebergeben"or(state=="am_ziel"and order.leg<entries_n)then return end
end
if order.retry_at and now()<order.retry_at and(state=="vorbereitet"or state=="am_ziel")then return end
if state=="angefordert"then
role.orders.transition(order.id,"in_pruefung","Voraussetzungen werden geprueft")
state="in_pruefung"
end
local entries=entries_of(template)
if state=="wartend"then
if now()-order.since>=RETRY_WAITING then role.orders.transition(order.id,"in_pruefung","erneute Pruefung")end
return
end
if state=="in_pruefung"then

local train=role.register.get(order.train)
local start,why
for _,name in ipairs(role.stations.candidates(entries[1].station))do
local entry=locate(name)
if entry then
local st=track_state[entry.node..":"..entry.track]
if st and st.present and train and st.train==train.create_name then start=entry break end
start=start or entry
else
why=why or select(2,locate(name))
end
end
if not start then return role.orders.transition(order.id,"wartend",why or("Der Bahnhof "..entries[1].station.." ist unbekannt."))end
local targets={}
for i=2,#entries do
for _,name in ipairs(role.stations.candidates(entries[i].station))do targets[#targets+1]=name end
end
order.start={node=start.node,track=start.track}
ask(start.node,"abfrage",{kind="pruefen",track=start.track,targets=targets},order,guarded(order,function(payload)handle_check_reply(order,payload)end))
elseif state=="vorbereitet"then
local train=role.register.get(order.train)
ask(order.start.node,"auftrag",{kind="fahrplan",orderId=order.id,track=order.start.track,train=train.create_name},order,
guarded(order,function(payload)handle_schedule_reply(order,payload)end))
elseif state=="fahrplan_uebergeben"or(state=="am_ziel"and order.leg<#entries)then
if order.retry_at and now()<order.retry_at then return end
order.retry_at=nil
local at=order.at or order.start
local entry={track=at.track}
local message,err=release_message(order,entry,order.stay)
if not message then return to_clarification(order,"Der Abschnittsfahrplan fehlt: "..tostring(err))end
ask(at.node,"auftrag",message,order,guarded(order,function(payload)handle_release_reply(order,payload)end))
elseif state=="abfahrt_freigegeben"then


local entry=entries[order.leg]or{}
local at=order.at or order.start
local st=at and track_state[at.node..":"..at.track]
local train=role.register.get(order.train)
if not entry.cargo and now()-order.since>=(order.min_stay or 0)+DEPART_GRACE and st and st.present and train and st.train==train.create_name then
to_clarification(order,"Der Zug ist nach der Freigabe nicht abgefahren: Fahrplan und Strecke pruefen.")
end
elseif state=="am_ziel"and order.leg>=#entries then
local at=order.at
local train=role.register.get(order.train)
local expect=carried_route(order,template,order.leg)
ask(at.node,"auftrag",{kind="warteauftrag",track=at.track,train=train.create_name,wait=0,expect=expect},order,guarded(order,function(payload)handle_wait_reply(order,payload)end))
end
end

local function drive_all()

local list=role.orders.active()
local t=now()
table.sort(list,function(a,b)
local ra,rb=orderslib.rank(a,t),orderslib.rank(b,t)
if ra~=rb then return ra>rb end
return a.number<b.number
end)
for _,order in ipairs(list)do
local ok,err=pcall(drive,order)
if not ok then notify("fehler","Auftrag "..order.id..": "..tostring(err))end
end
end


local function orders_of_train(train_name)
local out={}
local train=role.register.by_create_name(train_name)
if not train then return out end
for _,order in ipairs(role.orders.active())do
if order.train==train.id then out[#out+1]=order end
end
return out
end

local function remember_unknown(name,node_id,track_id,present,t)
if not name then return end
local entry=unknown_trains[name]
if not entry then
entry={since=t or now()}
unknown_trains[name]=entry
end
entry.node,entry.track,entry.last,entry.present=node_id,track_id,t or now(),present
end

local function on_arrival(m)
local p=m.payload
local where=p.node..":"..p.track

local stale=p.stay~=nil and seen_stay[where]~=nil and p.stay<seen_stay[where]
if p.stay then seen_stay[where]=math.max(seen_stay[where]or 0,p.stay)end
local train=(not stale)and set_position(p.train,"am_bahnhof",where,"meldung",p.t)or role.register.by_create_name(p.train)
if not train then
remember_unknown(p.train,p.node,p.track,true,p.t)
if not unknown_seen[where..":"..tostring(p.train)]then
unknown_seen[where..":"..tostring(p.train)]=true
notify("warnung","Unerwarteter Zug "..tostring(p.train).." auf Gleis "..p.track.." ("..p.node.."). Er wird als Belegung beachtet, aber keinem Auftrag zugeordnet.")
end
return
end
for _,order in ipairs(orders_of_train(p.train))do
local template=role.orders.template(order.template)
local entries=entries_of(template)
order.arrivals=order.arrivals or{}
local done=order.arrivals[where]
if order.state=="unterwegs"and not(p.stay~=nil and done~=nil and p.stay<=done)then
local expected=order.plan and order.plan[order.leg+1]
if expected and p.station_name==expected.station then
order.leg=order.leg+1
order.at={node=p.node,track=p.track}
order.stay=p.stay
order.arrivals[where]=p.stay
order.min_stay=entries[order.leg]and entries[order.leg].wait or 0
role.orders.save()
role.orders.transition(order.id,"am_ziel","Zielankunft bestaetigt: "..tostring(p.station_name))
else
to_clarification(order,"Der Zug ist an einer unerwarteten Station angekommen: "..tostring(p.station_name)..".")
end
end
end
end

local function on_departure(m)
local p=m.payload
local where=p.node..":"..p.track
local train=role.register.by_create_name(p.train)
if train then role.register.set_position(train.id,"unbekannt",nil,"meldung",p.t)end
if not train and unknown_trains[p.train]then remember_unknown(p.train,p.node,p.track,false,p.t)end
for _,order in ipairs(orders_of_train(p.train))do
local at_=order.at or order.start
local stale=order.state=="abfahrt_freigegeben"and((p.stay~=nil and order.stay~=nil and p.stay~=order.stay)or(at_~=nil and(at_.node~=p.node or at_.track~=p.track)))
if stale then

elseif order.state=="abfahrt_freigegeben"and p.released then
role.orders.transition(order.id,"unterwegs","Abfahrt bestaetigt")
elseif p.released and p.stay~=nil and p.stay==order.stay and(order.state=="fahrplan_uebergeben"or order.state=="am_ziel")
and(function()local at=order.at or order.start return at~=nil and at.node==p.node and at.track==p.track end)()then

role.orders.transition(order.id,"abfahrt_freigegeben","Freigabe durch die Abfahrtsmeldung belegt")
role.orders.transition(order.id,"unterwegs","Abfahrt bestaetigt")
elseif order.state=="vorbereitet"or order.state=="fahrplan_uebergeben"then
to_clarification(order,"Der Zug ist ohne Freigabe abgefahren.")
end
end
end

local function on_vanished(m)
local p=m.payload
for _,order in ipairs(orders_of_train(p.train))do
if order.state=="abfahrt_freigegeben"or order.state=="fahrplan_uebergeben"or order.state=="vorbereitet"then
to_clarification(order,"Der Zug ist nicht mehr am Bahnhof, aber die Abfahrt wurde nicht gemeldet.")
end
end
end

local function on_state(m)
local p=m.payload
for _,tr in ipairs(p.tracks or{})do
track_state[p.node..":"..tr.id]=tr

if tr.available==false then
local where=p.node..":"..tr.id
for _,train in ipairs(role.register.list())do
if train.position and train.position.kind=="am_bahnhof"and train.position.where==where then
role.register.set_position(train.id,"unbekannt",nil,"meldung",p.t)
end
end
for _,order in ipairs(role.orders.active())do
local at=order.at or order.start
if at and at.node==p.node and at.track==tr.id and(order.state=="fahrplan_uebergeben"or order.state=="abfahrt_freigegeben"or order.state=="vorbereitet")then
to_clarification(order,"Das Geraet an "..label.track(tr.name).." ist nicht verfuegbar: Lage klaeren.")
end
end
end

for name,e in pairs(unknown_trains)do
if e.present and e.node==p.node and e.track==tr.id and(not tr.present or tr.train~=name)then e.present=false end
end

local exit=tr.last_exit
if exit and not tr.present and exit.train then
for _,order in ipairs(orders_of_train(exit.train))do
if order.stay==exit.stay and(order.state=="abfahrt_freigegeben"or order.state=="fahrplan_uebergeben"or order.state=="vorbereitet")then
local pp={node=p.node,track=tr.id,train=exit.train,released=exit.released,stay=exit.stay,t=p.t}
if exit.vanished then on_vanished({payload=pp})else on_departure({payload=pp})end
end
end
end
if tr.present and tr.train then
local train=set_position(tr.train,"am_bahnhof",p.node..":"..tr.id,"meldung",p.t)
if not train then remember_unknown(tr.train,p.node,tr.id,true,p.t)end
if not train and not unknown_seen[p.node..":"..tr.id..":"..tostring(tr.train)]then
unknown_seen[p.node..":"..tr.id..":"..tostring(tr.train)]=true
notify("warnung","Unerwarteter Zug "..tostring(tr.train).." auf Gleis "..tr.id.." ("..p.node..").")
end

for _,order in ipairs(orders_of_train(tr.train))do
if order.state=="unterwegs"then
on_arrival({payload={node=p.node,track=tr.id,train=tr.train,station_name=tr.station_name,stay=tr.stay,t=p.t}})
end
end
end
end
end



local hello_asked,hello_asked_count={},0
local function ask_hello(sender)
if type(sender)~="string"or nodes[sender]then return end
local t=now()
if hello_asked[sender]and t-hello_asked[sender]<30 then return end
if not hello_asked[sender]then
if hello_asked_count>=200 then hello_asked,hello_asked_count={},0 end
hello_asked_count=hello_asked_count+1
end
hello_asked[sender]=t
node.send_to(sender,"abfrage",{kind="hallo_senden"})
end



local station_parts=chunks.new({max_parts=60,max_items=400,max_keys=80,ttl=60,now=now})
local function on_hello(m)
local p=m.payload
local tracks=p.tracks
if p.parts~=nil then
local assembled,why=station_parts.add("h:"..tostring(p.node),p.set,p.part,p.parts,p.tracks)
if not assembled then
if why=="offen"then return node.reply(m,"ok",{fertig=false})end
return node.reply(m,"abgelehnt",{grund=why})
end
tracks=assembled
end
nodes[p.node]={name=p.name,roles=p.roles,tracks=tracks,last_seen=now(),active=p.active,revision=p.revision}
silent_notified[p.node]=nil
role.netz.mark_active(p.node)
rebuild_dir()
node.reply(m,"ok",{fertig=true})
end


local function handle_register(m)
local p=m.payload
local entry=dir[p.station_name or""]

if not entry then return node.reply(m,"spaeter",{grund="Die Station "..tostring(p.station_name).." ist der Leitstelle noch nicht bekannt."})end
if entry.ambiguous then return node.reply(m,"abgelehnt",{grund="Die Station "..tostring(p.station_name).." gehoert zu keinem eindeutigen Bahnhofs-Node."})end
if not reachable(entry.node)then return node.reply(m,"spaeter",{grund="Der Node "..entry.node.." meldet sich nicht."})end
local req={id=p.id,create_name=p.create_name,display_name=p.display_name,usage=p.usage,mode=p.mode,length=p.length}
local ok,why=role.register.validate(req)
if not ok then return node.reply(m,"abgelehnt",{grund=why})end
local function finish()
req.evidence={present=true,train_name=p.create_name,where=entry.node..":"..entry.track,source="abfrage",t=now()}
local saved,err=role.register.register(req)
if not saved then return node.reply(m,"abgelehnt",{grund=err})end
node.reply(m,"angenommen",{id=p.id})
unknown_trains[p.current_name]=nil
unknown_trains[p.create_name]=nil

role.adopt(p.id,entry.node,entry.track)
end
if p.current_name~=p.create_name then
ask(entry.node,"auftrag",{kind="umbenennen",track=entry.track,from=p.current_name,to=p.create_name},nil,function(payload)
if payload.status=="ok"then finish()
elseif payload.status=="zurueckgestellt"then node.reply(m,"spaeter",{grund="Der Bahnhof gleicht sich noch mit der Leitstelle ab."})
else node.reply(m,"abgelehnt",{grund="Umbenennen nicht moeglich: "..tostring(payload.grund)})end
end)
else
finish()
end
end


function role.demand(template_id,request_id,extra)
local is_held,why=held()
if is_held then return nil,"Der Betrieb ist zurueckgehalten ("..why.."): neue Fahrten werden nicht angenommen."end
local template=role.orders.template(template_id)
if template then
local train=role.register.get((extra and extra.train)or template.train)
if train and train.state~="gesteuert"then return nil,"Der Zug "..train.id.." ist nicht im gesteuerten Betrieb ("..train.state..")."end
if train and train.mode=="manuell"then return nil,"Der Zug "..train.id.." wird manuell gefahren und bekommt keine automatischen Auftraege."end
end
return role.orders.request(template_id,request_id,extra)
end

local function handle_demand(m)
local order,new=role.demand(m.payload.template,m.payload.requestId or m.requestId,{source="bedarf"})
if not order then return node.reply(m,"abgelehnt",{grund=new})end
node.reply(m,"angenommen",{order=order.id,state=order.state,neu=new})
if new then drive_all()end
end

local REPLY_LIMIT=4800



local function reply_page(m,key,list,more,extra)
local function body_of(part,flag)
local body={}
for k,v in pairs(extra or{})do body[k]=v end
body[key],body.more=part,flag
return body
end
local fitted,cut=chunks.fit(list,function(part)return body_of(part,true)end,REPLY_LIMIT,ser)
if not fitted then return node.reply(m,"abgelehnt",{grund=cut})end
return node.reply(m,"ok",body_of(fitted,(more or cut)and true or nil))
end

local function templates_info()
local list={}
for _,template in ipairs(role.orders.templates())do
local active=role.orders.active_for(template.id)
list[#list+1]={
id=template.id,title=template.title,train=template.train,priority=template.priority,
active=active and{id=active.id,state=active.state,reason=active.reason,unconfirmed=flags[active.id]and flags[active.id].unconfirmed or nil}or nil,
}
end
return list
end


local function handle_templates_query(m)
local list=templates_info()
local after=type(m.payload.nach)=="string"and m.payload.nach or nil
if after then
local rest,seen={},false
for _,info in ipairs(list)do
if seen then rest[#rest+1]=info end
if info.id==after then seen=true end
end

if seen then list=rest else after=nil end
end
reply_page(m,"templates",list,false,{von_vorn=(after==nil)or nil})
end

local function handle_cancel(m)
local order=m.payload.order and role.orders.get(m.payload.order)
if not order then return node.reply(m,"abgelehnt",{grund="Unbekannter Auftrag."})end
local ok,text=role.orders.cancel(order.id)
node.reply(m,ok and"angenommen"or"abgelehnt",{hinweis=text,grund=not ok and text or nil})
end


local function dispatch_request(m)
local kind=m.payload.kind
if m.messageType=="auftrag"then
if kind=="anmelden"then handle_register(m)
elseif kind=="bedarf"then handle_demand(m)
elseif kind=="stornieren"then handle_cancel(m)
else node.reply(m,"abgelehnt",{grund="Unbekannter Auftrag."})end
elseif kind=="vorlagen"then handle_templates_query(m)
elseif kind=="node_anfordern"or kind=="betriebsstellen_liste"then role.handle_directory(m)
elseif kind=="konfig_holen"then role.handle_fetch_config(m)
elseif kind=="ersatz_liste"then role.handle_replace_list(m)
elseif kind=="netze"then

local count=0
for _ in pairs(nodes)do count=count+1 end
node.reply(m,"ok",{netz=node.config.network.name,zentrale=node.config.node.id,nodes=count})
elseif kind=="tafel"then

if m.payload.station~=nil and type(m.payload.station)~="string"then return node.reply(m,"abgelehnt",{grund="Die Betriebsstelle ist ungueltig."})end
reply_page(m,"rows",role.board(m.payload.station),false,{t=now()})
else
node.reply(m,"abgelehnt",{grund="Unbekannte Abfrage."})
end
end

local PART_KINDS={konfig=true,hallo=true}

function role.on_message(m,status)

if status=="old_sequence"and m.messageType=="meldung"and m.payload.kind=="hallo"and m.payload.parts==nil then
if retired[m.senderNodeId]then return node.reply(m,"ok",{stillgelegt=true})end
return on_hello(m)
end

if status=="old_sequence"and m.messageType=="meldung"and EVENT_KINDS[m.payload.kind]then status="ok"end

if status=="old_sequence"and m.messageType=="meldung"and PART_KINDS[m.payload.kind]and m.payload.parts~=nil then status="ok"end
if status~="ok"then return end
if retired[m.senderNodeId]then

if m.messageType=="meldung"and m.payload.kind=="hallo"then node.reply(m,"ok",{stillgelegt=true})end
return
end

local boot=tostring(m.messageId):match("^[^:]*:([^:]*):")
if boot and boots[m.senderNodeId]~=boot then
boots[m.senderNodeId]=boot
for key in pairs(seen_stay)do
if key:sub(1,#m.senderNodeId+1)==m.senderNodeId..":"then seen_stay[key]=nil end
end
end

if m.messageType=="bestaetigung"and m.correlationId and pending[m.correlationId]and pending[m.correlationId].target~=nil
and pending[m.correlationId].target~=m.senderNodeId then
notify("warnung","Antwort auf eine Frage an "..tostring(pending[m.correlationId].target).." kam von "..tostring(m.senderNodeId).." und wird nicht gewertet.")
return
end
if m.messageType=="bestaetigung"and m.correlationId and pending[m.correlationId]then
local p=pending[m.correlationId]
pending[m.correlationId]=nil
release_wait(p)
if nodes[m.senderNodeId]then nodes[m.senderNodeId].last_seen=now()end
if p.on_reply then
local ok,err=pcall(p.on_reply,m.payload,m)
if not ok then notify("fehler","Antwort von "..m.senderNodeId..": "..tostring(err))end
end
drive_all()
return
end
if nodes[m.senderNodeId]then nodes[m.senderNodeId].last_seen=now()end
if m.messageType=="meldung"then
local kind=m.payload.kind
if kind=="zustand"then ask_hello(m.senderNodeId)end
if kind=="hallo"then on_hello(m)
elseif kind=="konfig"then role.on_config(m)
elseif kind=="zustand"then on_state(m)
elseif kind=="ankunft"then on_arrival(m)
elseif kind=="abfahrt"then on_departure(m)
elseif kind=="zug_weg"then on_vanished(m)
elseif kind=="zug_umbenannt"then
notify("warnung","Der Zug "..tostring(m.payload.before).." heisst jetzt "..tostring(m.payload.train).." ("..tostring(m.payload.node).."): die Zuordnung ist ungeklaert.")

local train=role.register.by_create_name(m.payload.before)
if train then role.register.set_position(train.id,"unbekannt",nil,"meldung",m.payload.t)end
for _,order in ipairs(orders_of_train(m.payload.before))do
to_clarification(order,"Der Zug heisst jetzt "..tostring(m.payload.train).." statt "..tostring(m.payload.before)..": Zuordnung klaeren.")
end
end

if EVENT_KINDS[kind]then node.reply(m,"ok",{})end
drive_all()
elseif m.messageType=="auftrag"or m.messageType=="abfrage"then


local ok,err=pcall(dispatch_request,m)
if not ok then
notify("fehler","Anfrage "..tostring(m.payload.kind).." von "..tostring(m.senderNodeId)..": "..tostring(err))
if not node.inbox.reply_for(m.messageId)then
node.reply(m,"abgelehnt",{grund="Die Leitstelle konnte die Anfrage nicht bearbeiten ("..tostring(err):sub(1,80)..")."})
end
end
end
end


local function idle_train(line,template)
local ids=#line.trains>0 and line.trains or{template.train}

local from=1
for i,id in ipairs(ids)do if id==line.last_train then from=i%#ids+1 end end
local first_name=template.stops[1].station
local starts={}
for _,name in ipairs(role.stations.candidates(first_name))do starts[name]=true end
for k=0,#ids-1 do
local id=ids[(from-1+k)%#ids+1]
local train=role.register.get(id)
local busy=false
for _,order in ipairs(role.orders.active())do if order.train==id then busy=true end end
if train and train.state=="gesteuert"and train.mode~="manuell"and not busy then
local pos=train.position
if pos and pos.kind=="am_bahnhof"then
for name in pairs(starts)do
local entry=dir[name]
if entry and pos.where==entry.node..":"..entry.track then return train end
end
end
end
end
return nil
end

local function run_lines()
for _,line in ipairs(role.lines.due())do
local template=role.orders.template(line.template)
local term=line.next_due
local served=false
if held()then
role.lines.note(line.id,"Termin ausgelassen: Betrieb zurueckgehalten.")
elseif not template then
role.lines.note(line.id,"Die Vorlage "..line.template.." gibt es nicht.")
else
local train=idle_train(line,template)
if train then
local order=role.orders.request(line.template,"linie-"..line.id.."-"..term,{train=train.id,priority=line.priority,source="linie"})
served=order~=nil
if served then role.lines.used(line.id,train.id)end
role.lines.note(line.id,order and("Termin bedient: "..order.id)or"Auftrag nicht angelegt.")
else
role.lines.note(line.id,"Termin ausgelassen: kein Zug bereit am Start.")
end
end
local info=role.lines.advance(line.id,served)
if info and info.skipped>0 then notify("warnung","Linie "..line.id..": "..info.skipped.." Termine waehrend einer Unterbrechung ausgelassen (keine Nachholfahrten).")end
end
end


function role.board(station)
local rows={}
for _,line in ipairs(role.lines.list())do
local template=role.orders.template(line.template)
local serves=station==nil
if template and station then
local names={}
for _,name in ipairs(role.stations.candidates(station))do names[name]=true end
for _,stop in ipairs(template.stops)do
for _,name in ipairs(role.stations.candidates(stop.station))do if names[name]or stop.station==station then serves=true end end
end
end
if serves then
local row={line=line.id,title=line.title,interval=line.interval,next_due=line.next_due,in_seconds=line.next_due-now(),missed=line.missed,note=line.note,active=line.active,priority=line.priority}
for _,order in ipairs(role.orders.active())do
local ot=role.orders.template(order.template)
if ot and order.template==line.template and order.source=="linie"then
row.order={id=order.id,train=order.train,state=order.state,reason=order.reason,leg=order.leg,legs=#entries_of(ot)}
break
end
end
rows[#rows+1]=row
end
end
return rows
end

function role.tick()
check_pending()
local t=now()
for i=#later,1,-1 do
if t>=later[i].at then
local item=table.remove(later,i)
local ok,err=pcall(item.fn)
if not ok then notify("fehler","Wiederholung: "..tostring(err))end
end
end
run_lines()
for id,info in pairs(nodes)do
if now()-info.last_seen>=NODE_SILENT and not silent_notified[id]then
silent_notified[id]=true
notify("warnung","Der Node "..id.." meldet sich nicht mehr.")
end
end
drive_all()
end


function role.next_step()
if next(nodes)==nil then
return"Naechster Schritt: andere Computer einrichten (Einrichtung, Beitreten, Netz, Rolle)."
end
return nil
end


function role.update_blocker()
local running=0
for _,order in ipairs(role.orders.active())do
local st=order.state
if st=="fahrplan_uebergeben"or st=="abfahrt_freigegeben"or st=="unterwegs"or st=="am_ziel"then running=running+1 end
end
if running>0 then return running.." Fahrt(en) laufen"end
end


function role.info()
return{nodes=nodes,dir=dir,track_state=track_state,pending=pending,flags=flags,samples=samples}
end



role.sample_status=nil
function role.read_sample(station_name,value)
local entry,why=locate(station_name)
if not entry then role.sample_status={kind="halt",text=why}return nil,why end
role.sample_status={kind="wait",text="Fahrplan wird gelesen ..."}
ask(entry.node,"abfrage",{kind="lesen",track=entry.track},nil,function(payload)
if payload.status~="ok"then
role.sample_status={kind="halt",text="Lesen nicht moeglich: "..tostring(payload.grund)}
return
end
local cond=schedulelib.find_cargo(payload.schedule)
if not cond then
role.sample_status={kind="halt",text="Im Fahrplan des Zuges "..tostring(payload.train).." steht keine Mengenbedingung (nur Warten/Redstone)."}
return
end
if cond.id~="create:item_threshold"then
role.sample_status={kind="halt",text="Die Bedingung ist "..tostring(cond.id)..", gebraucht wird create:item_threshold (Fracht: Gegenstaende)."}
return
end
local path,err=schedulelib.locate_unique(cond,value)
if not path then role.sample_status={kind="halt",text=err}return end
local ok,serr=role.set_sample("item_threshold",{condition=cond,path=path})
role.sample_status=ok and{kind="ok",text="Muster gespeichert (Feld "..table.concat(path,".")..")."}or{kind="halt",text=tostring(serr)}
end)
return true
end


function role.create_template(fields,opts2)
local previous=role.orders.template(fields.id)
if previous and not(opts2 and opts2.replace)then return nil,"Die Vorlage "..tostring(fields.id).." gibt es schon: mit Aendern bearbeiten."end
local stops,err=orderslib.parse_stops(fields.stops)
if not stops then return nil,err end
local train=role.register.get(fields.train)
if not train then return nil,"Der Zug "..tostring(fields.train).." ist nicht angemeldet."end
for _,stop in ipairs(stops)do
if stop.cargo and not samples.item_threshold then return nil,"Fuer Mengenangaben fehlt das Muster (Seite Vorlagen, Muster erfassen)."end
end
local ok,e=role.orders.add_template({id=fields.id,title=fields.title,train=fields.train,return_to_start=true,stops=stops,priority=previous and previous.priority or nil},
function(name)return role.stations.get(name)~=nil end)
if not ok then return nil,e end
return true
end


function role.update_station_group(old,name,members)
local renamed=name~=old
if renamed then

for _,order in ipairs(role.orders.active())do
local template=role.orders.template(order.template)
local uses=false
for _,stop in ipairs(template and template.stops or{})do if stop.station==old then uses=true end end
for _,plan_name in ipairs(order.plan or{})do if plan_name==old then uses=true end end
if uses then return nil,"Der Auftrag "..order.id.." faehrt zu diesem Bahnhof: erst beenden oder abbrechen."end
end
end
local ok,err=role.stations.update(old,name,members)
if not ok then return nil,err end
if renamed then
local count,why=role.orders.rename_station(old,name)
if not count then return nil,why end
end
return true
end


function role.remove_template(id)
for _,line in ipairs(role.lines.list())do
if line.template==id then return nil,"Die Linie "..line.title.." fuehrt diese Vorlage: erst die Linie loeschen."end
end
return role.orders.remove_template(id)
end


role.depot_status=nil
local function depot_say(kind,text)role.depot_status={kind=kind,text=text}return text end

local function station_of(node_id,track_id)
local info=nodes[node_id]
for _,tr in ipairs(info and info.tracks or{})do if tr.id==track_id then return tr.station_name end end
end

local function split_where(where)
if type(where)~="string"then return nil end
return where:match("^(.-):(.+)$")
end

local function active_order_of(train_id)
for _,order in ipairs(role.orders.active())do if order.train==train_id then return order end end
end


function role.adopt(train_id,node_id,track_id)
local train=role.register.get(train_id)
if not train then return nil,"Unbekannter Zug."end
ask(node_id,"auftrag",{kind="warteauftrag",track=track_id,train=train.create_name,wait=0,handover=true},nil,function(payload)
if payload.status=="zurueckgestellt"then
later[#later+1]={at=now()+(payload.retry_in or 5),fn=function()role.adopt(train_id,node_id,track_id)end}
elseif payload.status=="uebergeben"then
role.register.set_state(train_id,"gesteuert")
role.register.set_position(train_id,"am_bahnhof",node_id..":"..track_id,"abfrage",now())
if train.mode=="manuell"then role.register.set_mode(train_id,"bedarf")end
depot_say("ok","Zug "..train_id.." ist aufgenommen (gesteuert).")
else
notify("warnung","Zug "..train_id..": Warteauftrag nicht erteilt ("..tostring(payload.grund)..").")
depot_say("halt","Aufnahme nicht bestaetigt: "..tostring(payload.grund))
end
end)
return true
end


function role.park(train_id,target)
local train=role.register.get(train_id)
if not train then return nil,depot_say("halt","Unbekannter Zug.")end
if train.state~="gesteuert"then return nil,depot_say("halt","Der Zug ist nicht im gesteuerten Betrieb ("..train.state..").")end
if active_order_of(train_id)then return nil,depot_say("halt","Der Zug hat noch einen laufenden Auftrag.")end
local node_id,track_id=split_where(train.position and train.position.kind=="am_bahnhof"and train.position.where)
if not node_id then return nil,depot_say("halt","Der Zug steht nicht nachweislich an einem Bahnhof.")end
local from=station_of(node_id,track_id)
if not from then return nil,depot_say("halt","Der Startbahnhof ist unbekannt.")end
if target==from then return nil,depot_say("halt","Der Zug steht schon an "..from..".")end
if role.stations.candidates(target)[1]==nil or(not role.stations.get(target)and not dir[target])then
return nil,depot_say("halt","Die Abstellstation "..tostring(target).." ist unbekannt.")
end
local id="abstellen-"..train_id
local ok,err=role.orders.add_template({id=id,title="Abstellen "..train_id,train=train_id,kind="abstellen",return_to_start=false,stops={{station=from,wait=0},{station=target,wait=0}}})
if not ok then return nil,depot_say("halt",err)end
local order,new=role.orders.request(id,nil,{train=train_id,source="abstellen"})
if not order then return nil,depot_say("halt",tostring(new))end
drive_all()
return order,depot_say("wait",(new and"Abstellauftrag "or"Laeuft schon: ")..order.id)
end


function role.activate(train_id)
local train=role.register.get(train_id)
if not train then return nil,depot_say("halt","Unbekannter Zug.")end
if train.state~="abgestellt"then return nil,depot_say("halt","Der Zug ist nicht abgestellt ("..train.state..").")end
local node_id,track_id=split_where(train.position and train.position.kind=="am_bahnhof"and train.position.where)
if not node_id or not reachable(node_id)then return nil,depot_say("halt","Der Abstellort ist nicht erreichbar oder unbekannt.")end
depot_say("wait","Pruefung laeuft ...")
ask(node_id,"abfrage",{kind="pruefen",track=track_id,targets={}},nil,function(payload)
if payload.status~="ok"or not payload.available or not payload.present then
return depot_say("halt","Aktivierung abgelehnt: kein Zug am Abstellgleis.")
end
if payload.train~=train.create_name then
return depot_say("halt","Aktivierung abgelehnt: am Abstellgleis steht "..tostring(payload.train)..", nicht "..train.create_name..".")
end
if payload.has_schedule and not payload.waiting_ok then
return depot_say("halt","Aktivierung abgelehnt: der Fahrplan entspricht nicht dem Warteauftrag (Aufnehmen mit Uebergabe noetig).")
end
role.register.set_state(train_id,"gesteuert")
depot_say("ok","Zug "..train_id.." ist aktiv (gesteuert).")
end)
return true
end


function role.eject(train_id)
local train=role.register.get(train_id)
if not train then return nil,depot_say("halt","Unbekannter Zug.")end
if train.state~="gesteuert"and train.state~="abgestellt"then return nil,depot_say("halt","Der Zug ist schon nicht mehr im gesteuerten Betrieb ("..train.state..").")end
if active_order_of(train_id)then return nil,depot_say("halt","Der Zug hat noch einen laufenden Auftrag: erst beenden oder abbrechen und die Lage klaeren.")end
if not train.position or train.position.kind~="am_bahnhof"then return nil,depot_say("halt","Ausgeschleust wird nur an einem bestaetigten Haltepunkt.")end
local ok,err=role.register.set_state(train_id,"ausgeschleust")
if not ok then return nil,depot_say("halt",err)end
role.register.set_mode(train_id,"manuell")
return true,depot_say("ok","Zug "..train_id.." ist ausgeschleust. Sein Create-Fahrplan bleibt unveraendert; die Belegung gilt weiter.")
end


function role.take_over(train_id)
local train=role.register.get(train_id)
if not train then return nil,depot_say("halt","Unbekannter Zug.")end
if train.state=="gesteuert"then return nil,depot_say("halt","Der Zug ist schon im gesteuerten Betrieb.")end
if train.state=="abgestellt"then return nil,depot_say("halt","Ein abgestellter Zug wird aktiviert, nicht aufgenommen.")end
local node_id,track_id=split_where(train.position and train.position.kind=="am_bahnhof"and train.position.where)
if not node_id then return nil,depot_say("halt","Der Zug steht nicht nachweislich an einem Bahnhof.")end
local st=track_state[node_id..":"..track_id]
if not st or not st.present or st.train~=train.create_name then
return nil,depot_say("halt","Am Haltepunkt ist der Zug "..train.create_name.." nicht nachgewiesen.")
end
depot_say("wait","Aufnahme laeuft ...")
return role.adopt(train_id,node_id,track_id)
end

function role.cycle_mode(train_id)
local train=role.register.get(train_id)
if not train then return nil,depot_say("halt","Unbekannter Zug.")end
if active_order_of(train_id)then return nil,depot_say("halt","Waehrend eines Auftrags wechselt die Betriebsart nicht.")end
local nxt=({bedarf="linie",linie="manuell",manuell="bedarf"})[train.mode]or"bedarf"
if nxt~="manuell"and train.state~="gesteuert"then return nil,depot_say("halt","Nur ein gesteuerter Zug wechselt zwischen Bedarfs- und Linienbetrieb.")end
local ok,err=role.register.set_mode(train_id,nxt)
if not ok then return nil,depot_say("halt",err)end
return true,depot_say("ok","Betriebsart von "..train_id..": "..nxt)
end

function role.unknown_list()
local names={}
for name in pairs(unknown_trains)do names[#names+1]=name end
table.sort(names)
local out={}
for _,name in ipairs(names)do
local e=unknown_trains[name]
out[#out+1]={name=name,node=e.node,track=e.track,station=station_of(e.node,e.track),present=e.present,since=e.since,last=e.last}
end
return out
end

function role.forget_unknown(name)
local e=unknown_trains[name]
if not e then return nil,"Den Zug kenne ich nicht."end
if e.present then return nil,"Der Zug steht noch am Gleis: Belegung bleibt."end
unknown_trains[name]=nil
return true
end


function role.set_hold(on,reason)
local previous={hold=operation.hold,reason=operation.reason,since=operation.since}
operation.hold,operation.reason,operation.since=on and true or false,on and(reason or"vom Bediener")or nil,on and now()or nil
local ok,err=node.store.save(DATA.."/betrieb.lua",operation)
if not ok then
operation.hold,operation.reason,operation.since=previous.hold,previous.reason,previous.since
return nil,err
end
return true
end

function role.hold_state()return held()end


function role.drain_state()
local active,committed=0,0
for _,order in ipairs(role.orders.active())do
active=active+1
if order.state=="abfahrt_freigegeben"or order.state=="unterwegs"then committed=committed+1 end
end
return{active=active,committed=committed}
end


function role.faults()
local list={}
local function add(kind,who,text)list[#list+1]={kind=kind,who=who,text=text}end
local is_held,why=held()
if is_held then add("attention","Betrieb","Neue Abfahrten zurueckgehalten: "..why)end
local ids={}
for id in pairs(nodes)do ids[#ids+1]=id end
table.sort(ids)
for _,id in ipairs(ids)do
local info=nodes[id]
if retired[id]then
add("dim",id,"stillgelegt")
elseif not reachable(id)then
add("halt",id,"meldet sich nicht (keine neuen zentral abhaengigen Freigaben)")
end
for _,tr in ipairs(info.tracks or{})do
local st=track_state[id..":"..tr.id]
if st and st.available==false then add("halt",id.."/"..tr.name,"Bahnhof-Geraet nicht verfuegbar: Gleis ungeklaert, keine Fahrplanaenderung")end
end
end
for _,order in ipairs(role.orders.active())do
if order.state=="klaerung"then add("halt",order.id,"Klaerung: "..tostring(order.reason))
elseif order.state=="wartend"then add("wait",order.id,"wartet: "..tostring(order.reason))end
end
for _,row in ipairs(role.unknown_list())do
if row.present then add("attention",row.name,"fremder Zug an "..tostring(row.station or row.track).." (Belegung)")end
end
return list
end


function role.refresh_all()
local count=0
for id in pairs(nodes)do
if reachable(id)then
node.send_to(id,"abfrage",{kind="zustand_senden"})
count=count+1
end
end
return count
end



local DIRECTORY_PAGE=20
function role.handle_directory(m)
local p=m.payload
local revision=role.netz.revision()
if p.kind=="betriebsstellen_liste"then

local after=type(p.after)=="string"and p.after or nil
local list,more={},false
for _,st in ipairs(role.netz.stations())do
if after==nil or st.id>after then
if#list>=DIRECTORY_PAGE then more=true break end
list[#list+1]={id=st.id,name=st.name,kind=st.kind}
end
end
return reply_page(m,"stations",list,more,{revision=revision})
end
if p.legacy~=nil and type(p.legacy)~="string"then return node.reply(m,"abgelehnt",{grund="Die bisherige Node-Kennung ist ungueltig."})end
if p.station~=nil and type(p.station)~="string"then return node.reply(m,"abgelehnt",{grund="Die Betriebsstelle ist ungueltig."})end
if p.roles~=nil and type(p.roles)~="table"then return node.reply(m,"abgelehnt",{grund="Die Rollen sind ungueltig."})end
local entry,err=role.netz.claim_node({claim=p.claim,role=p.role,roles=p.roles,station=p.station,legacy=p.legacy})
if not entry then return node.reply(m,"abgelehnt",{grund=err})end
node.reply(m,"ok",{node={id=entry.id,name=entry.name,label=entry.label},revision=role.netz.revision()})
end


local BACKUP_DIR=DATA.."/nodesich"
local function backup_path(id)return BACKUP_DIR.."/"..tostring(id):gsub("[^%w%-_]","_")..".lua"end



local MAX_CONFIG=60000
local MAX_BACKUPS=60
local config_parts=chunks.new({max_parts=40,max_bytes=MAX_CONFIG,max_keys=80,ttl=180,now=now})

function role.on_config(m)
local p=m.payload
local fs=node.env.fs
if type(p.node)~="string"or#p.node==0 or#p.node>40 then return node.reply(m,"abgelehnt",{grund="Die Node-Kennung fehlt."})end
if p.node~=m.senderNodeId then return node.reply(m,"abgelehnt",{grund="Eine Node sichert nur ihre eigene Konfiguration."})end
if type(p.revision)~="number"then return node.reply(m,"abgelehnt",{grund="Der Stand fehlt."})end
local text=p.config
if p.parts~=nil then
local assembled,why=config_parts.add("konfig:"..p.node,p.revision,p.part,p.parts,p.config,p.sum)
if not assembled then
if why=="offen"then return node.reply(m,"ok",{fertig=false})end
return node.reply(m,"abgelehnt",{grund=why})
end
text=assembled
end
if type(text)~="string"or#text>MAX_CONFIG then return node.reply(m,"abgelehnt",{grund="Die Konfiguration ist zu gross."})end
local decoded=ser.decode(text)
if type(decoded)~="table"or type(decoded.node)~="table"or decoded.node.id~=p.node then
return node.reply(m,"abgelehnt",{grund="Die Konfiguration ist nicht lesbar oder gehoert einer anderen Node."})
end
if not fs.exists(BACKUP_DIR)then fs.makeDir(BACKUP_DIR)end
local count=#fs.list(BACKUP_DIR)
if count>=MAX_BACKUPS and not fs.exists(backup_path(p.node))then
return node.reply(m,"abgelehnt",{grund="Zu viele gesicherte Nodes."})
end
local ok,err=node.store.save(backup_path(p.node),{revision=p.revision,config=text,t=now()})
node.reply(m,ok and"ok"or"abgelehnt",{grund=err,fertig=ok and true or nil})
end

function role.backup_of(id)return node.store.load(backup_path(id))end

function role.retire(id)
if not nodes[id]then return nil,"Den Node kenne ich nicht."end
retired[id]=true
nodes[id].retired=true
local ok,err=node.store.save(DATA.."/stillgelegt.lua",retired)
if not ok then retired[id],nodes[id].retired=nil,nil return nil,err end
return true
end

function role.unretire(id)
retired[id]=nil
if nodes[id]then nodes[id].retired=nil end
return node.store.save(DATA.."/stillgelegt.lua",retired)
end




function role.forget_node(id)
local info=nodes[id]
if not info then return nil,"Den Node kenne ich nicht."end
if not retired[id]and reachable(id)then return nil,"Der Node "..id.." laeuft noch: erst stilllegen."end
local ok,err=role.netz.remove_node(id)
if not ok and err~="Die Node gibt es nicht."and err~="Die Node ist schon entfernt."then return nil,err end
retired[id]=true
local saved,save_err=node.store.save(DATA.."/stillgelegt.lua",retired)
if not saved then return nil,save_err end
nodes[id]=nil
silent_notified[id]=nil
for key in pairs(track_state)do
if key:sub(1,#id+1)==id..":"then track_state[key]=nil end
end
if node.env.fs.exists(backup_path(id))then node.env.fs.delete(backup_path(id))end
rebuild_dir()
return true
end


local REPLACE_PAGE=12
function role.handle_replace_list(m)
local after=type(m.payload.after)=="string"and m.payload.after or nil
local ids={}
for id in pairs(nodes)do
if type(id)=="string"and node.env.fs.exists(backup_path(id))and(after==nil or id>after)then ids[#ids+1]=id end
end
table.sort(ids)
local list,more={},nil
for _,id in ipairs(ids)do
if#list>=REPLACE_PAGE then more=true break end
local info=nodes[id]
local state=retired[id]and"stillgelegt"or(reachable(id)and"aktiv"or"ausgefallen")
list[#list+1]={id=id,name=type(info.name)=="string"and info.name or"",state=state}
end
reply_page(m,"backups",list,more)
end



function role.handle_fetch_config(m)
local id=m.payload.node
local part_no=m.payload.part==nil and 1 or m.payload.part
if type(part_no)~="number"or part_no~=math.floor(part_no)or part_no<1 then
return node.reply(m,"abgelehnt",{grund="Die Teilnummer ist ungueltig."})
end
local entry=role.backup_of(id)
if not entry then return node.reply(m,"abgelehnt",{grund="keine Sicherung von "..tostring(id).."."})end
if nodes[id]and not retired[id]and reachable(id)then
return node.reply(m,"abgelehnt",{grund="Die Node "..id.." ist noch aktiv: erst ausschalten oder in der Leitstelle stilllegen."})
end
local text=entry.config
local parts
if type(text)=="string"then
local sum=adler.hex(text)
local why
parts,why=chunks.parts_text(text,function(piece,i,count)return{config=piece,revision=entry.revision,part=i,parts=count,sum=sum}end,REPLY_LIMIT,ser)
if not parts then return node.reply(m,"abgelehnt",{grund="Die Sicherung laesst sich nicht senden: "..tostring(why)})end
else
parts={{config=entry.config,revision=entry.revision,part=1,parts=1}}
end
if part_no>#parts then return node.reply(m,"abgelehnt",{grund="Diesen Teil gibt es nicht."})end
if part_no==1 then

role.unretire(id)
notify("warnung","Die Konfiguration von "..id.." wurde an einen Ersatzcomputer uebergeben. Die alte Node darf nicht mehr laufen.")
end
node.reply(m,"ok",parts[part_no])
end


function role.set_closed(create_name,value)
local previous=closed[create_name]
closed[create_name]=value and true or nil
local ok,err=node.store.save(DATA.."/gesperrt.lua",closed)
if not ok then closed[create_name]=previous return nil,err end
return true
end
function role.is_closed(create_name)return closed[create_name]==true end

function role.set_sample(kind,sample)
samples[kind]=sample
return node.store.save(DATA.."/muster.lua",samples)
end


for _,order in ipairs(role.orders.active())do
if order.state=="vorbereitet"or order.state=="in_pruefung"then
role.orders.transition(order.id,order.state=="in_pruefung"and"in_pruefung"or"in_pruefung","nach Neustart neu geprueft")
end
if order.start and order.state~="angefordert"then

end
end


local pages={}
local arm={cancel=false}

local STATE_TEXT={
angefordert="angefordert",in_pruefung="wird geprueft",wartend="wartet",vorbereitet="vorbereitet",
fahrplan_uebergeben="Fahrplan uebergeben",abfahrt_freigegeben="Abfahrt freigegeben (noch nicht bestaetigt)",
unterwegs="unterwegs",am_ziel="am Ziel",abgeschlossen="abgeschlossen",klaerung="KLAERUNG erforderlich",
abgelehnt="abgelehnt",storniert="storniert",
}
local STATE_KIND={klaerung="halt",wartend="wait",abgeschlossen="ok",abgelehnt="halt",storniert="dim",abfahrt_freigegeben="wait",am_ziel="ok",unterwegs="text"}

pages[#pages+1]={
id="zuege",title="Zuege",
render=function(v,rect)
local state=v.page_state("zuege")
state.list=state.list or{index=1}
state.fields=state.fields or{name={value="",max=30},create={value="",max=30}}
if state.screen=="aendern"then
W.label(v,rect.x+1,rect.y,"Zug "..tostring(state.edit).." aendern","hell",rect.w-2)
W.field(v,"zname",rect.x+1,rect.y+2,math.min(34,rect.w-2),"Anzeigename",state.fields.name)
W.field(v,"zcreate",rect.x+1,rect.y+5,math.min(34,rect.w-2),"Create-Zugname (so heisst der Zug in Create)",state.fields.create)
return
end
local items={}
state.trains={}
for i,train in ipairs(role.register.list())do
local pos=train.position
local where=pos and(pos.kind=="am_bahnhof"and("am Bahnhof "..tostring(pos.where))or pos.kind)or"unbekannt"
items[#items+1]={text=train.id.." "..train.display_name,detail=train.state..", "..train.mode..", "..where}
state.trains[i]=train
end
W.list(v,"zuege",rect,items,state.list,{empty="Noch kein Zug angemeldet (Rolle Anmeldung)."})
end,
actions=function(v)
local state=v.page_state("zuege")
if state.screen=="aendern"then
return{
{id="z_speichern",label="Speichern",side="rechts"},
{id="z_zurueck",label="Zurueck",kind="secondary",side="rechts"},
}
end
local train=state.trains and state.trains[(state.list or{index=1}).index]
return{
{id="z_aendern",label="Aendern",kind="secondary",enabled=train~=nil,reason="Erst einen Zug waehlen."},
{id="abmelden",label=arm.unregister and"Wirklich?"or"Abmelden",kind="danger",enabled=train~=nil,reason="Erst einen Zug waehlen."},
}
end,
on_action=function(v,id)
local state=v.page_state("zuege")
if id=="act:z_aendern"then
local train=state.trains and state.trains[state.list.index]
if not train then return true end
state.fields=state.fields or{name={value="",max=30},create={value="",max=30}}
state.fields.name.value,state.fields.create.value=train.display_name or"",train.create_name or""
state.edit,state.screen=train.id,"aendern"
return true
elseif id=="act:z_zurueck"then
state.screen=nil
return true
elseif id=="act:z_speichern"then
local train=role.register.get(state.edit)
if not train then state.screen=nil return true end
local new_create=state.fields.create.value:match("^%s*(.-)%s*$")
if new_create~=train.create_name then
for _,order in ipairs(role.orders.active())do
if order.train==train.id then
v.hint="Der Zug hat den aktiven Auftrag "..order.id..": erst beenden oder abbrechen."
return true
end
end
local ok,err=role.register.rename_create(train.id,new_create)
if not ok then v.hint=err return true end
end
local new_name=state.fields.name.value:match("^%s*(.-)%s*$")
if new_name~=""and new_name~=train.display_name then
local ok,err=role.register.rename_display(train.id,new_name)
if not ok then v.hint=err return true end
end
v.hint="Gespeichert."
state.screen=nil
return true
end
if id=="act:abmelden"then
local state=v.page_state("zuege")
local train=state.trains and state.trains[state.list.index]
if not train then return true end
for _,order in ipairs(role.orders.active())do
if order.train==train.id then
v.hint="Der Zug hat den aktiven Auftrag "..order.id.."."
arm.unregister=false
return true
end
end
if not arm.unregister then
arm.unregister=true
v.hint="Nochmal druecken: nur die Zustaendigkeit endet, nicht der Zug."
else
arm.unregister=false
role.register.unregister(train.id)
v.hint="Abgemeldet; der Zug und seine Belegung bleiben bestehen."
end
return true
end
end,
}

pages[#pages+1]={
id="auftraege",title="Auftraege",
render=function(v,rect)
local state=v.page_state("auftraege")
state.list=state.list or{index=1}
local items={}
state.orders={}
local all=role.orders.list()
for i=#all,1,-1 do
local order=all[i]
local template=role.orders.template(order.template)
local text=STATE_TEXT[order.state]or order.state
if flags[order.id]and flags[order.id].unconfirmed then text=text.." - Rueckmeldung fehlt"end
items[#items+1]={text=order.id.." "..(template and template.title or order.template),detail=text..(order.reason and(": "..order.reason)or""),kind=STATE_KIND[order.state]or"text"}
state.orders[#items]=order
end
W.list(v,"auftraege",rect,items,state.list,{empty="Noch keine Auftraege."})
end,
actions=function(v)
local state=v.page_state("auftraege")
local order=state.orders and state.orders[(state.list or{index=1}).index]
local terminal=order and(order.state=="abgeschlossen"or order.state=="abgelehnt"or order.state=="storniert")
return{
{id="stornieren",label=arm.cancel and"Wirklich?"or"Abbrechen",kind="danger",enabled=order~=nil and not terminal,reason="Kein laufender Auftrag gewaehlt."},
{id="neu_pruefen",label="Neu pruefen",kind="secondary",enabled=order~=nil and(order.state=="klaerung"or order.state=="wartend"),reason="Nur fuer wartende Auftraege und Klaerungen."},
}
end,
on_action=function(v,id)
local state=v.page_state("auftraege")
local order=state.orders and state.orders[state.list.index]
if id=="act:stornieren"and order then
if not arm.cancel then
arm.cancel=true
v.hint="Nochmal druecken. Vor der Fahrplanuebergabe wird storniert, danach ist es nur ein Aenderungswunsch."
else
arm.cancel=false
local ok,text=role.orders.cancel(order.id)
v.hint=ok and text or text
end
return true
elseif id=="act:neu_pruefen"and order then
role.orders.transition(order.id,"in_pruefung","vom Bediener neu angestossen")
drive_all()
return true
end
end,
}

pages[#pages+1]={
id="netz",title="Netz",
render=function(v,rect)
local state=v.page_state("netz")
state.list=state.list or{index=1}
local items={}
local ids={}
state.ids={}
for id in pairs(nodes)do ids[#ids+1]=id end
table.sort(ids)
for _,id in ipairs(ids)do
local info=nodes[id]
local ok=reachable(id)
local tracks={}
for _,tr in ipairs(info.tracks or{})do
local st=track_state[id..":"..tr.id]
tracks[#tracks+1]=tr.name..(st and st.present and(":"..tostring(st.train))or"")
end
items[#items+1]={text=id.." "..(info.name or""),detail=(retired[id]and"STILLGELEGT"or(ok and"erreichbar"or"NICHT ERREICHBAR"))..", "..#tracks.." Gleise"..(#tracks>0 and(": "..table.concat(tracks,","))or""),kind=retired[id]and"dim"or(ok and"ok"or"halt")}
state.ids=state.ids or{}
state.ids[#items]=id
end

state.reserved={}
for _,entry in ipairs(role.netz.nodes())do
if entry.state=="reserviert"and not nodes[entry.id]then
items[#items+1]={text=entry.id.." "..entry.name,detail="RESERVIERT, hat sich noch nicht gemeldet",kind="wait"}
state.ids[#items]=entry.id
state.reserved[entry.id]=true
end
end
W.list(v,"netz",rect,items,state.list,{empty="Noch kein Node hat sich gemeldet."})
end,
actions=function(v)
local state=v.page_state("netz")
local id=state.ids and state.ids[(state.list or{index=1}).index]
if id and state.reserved and state.reserved[id]then
return{{id="stilllegen",label=arm.discard==id and"Wirklich?"or"Verwerfen",kind="danger"}}
end
local can_forget=id~=nil and(retired[id]or not reachable(id))
return{
{id="stilllegen",label=id and retired[id]and"Aktivieren"or(arm.retire and"Wirklich?"or"Stilllegen"),kind="danger",enabled=id~=nil,reason="Erst einen Node waehlen."},
{id="entfernen",label=arm.forget==id and"Wirklich?"or"Entfernen",kind="danger",enabled=can_forget,
reason=id and"Der Node laeuft noch: erst stilllegen."or"Erst einen Node waehlen."},
}
end,
on_action=function(v,action)
if action~="act:stilllegen"and action~="act:entfernen"then return end
local state=v.page_state("netz")
local id=state.ids and state.ids[state.list.index]
if not id then return true end
if action=="act:entfernen"then
arm.retire,arm.discard=false,nil
if arm.forget~=id then
arm.forget=id
v.hint="Nochmal druecken: "..id.." entfernen."
else
arm.forget=nil
local ok,err=role.forget_node(id)
v.hint=ok and("Node "..id.." entfernt.")or err
end
return true
end
arm.forget=nil
if state.reserved and state.reserved[id]then

if arm.discard~=id then
arm.discard=id
v.hint="Nochmal druecken: die Anforderung "..id.." wird verworfen (die Kennung wird nicht wieder vergeben)."
else
arm.discard=nil
local ok,err=role.netz.discard_node(id)
v.hint=ok and("Anforderung "..id.." verworfen.")or err
end
return true
end
if retired[id]then
local ok,err=role.unretire(id)
v.hint=ok and("Node "..id.." ist wieder aktiv.")or err
elseif not arm.retire then
arm.retire=true
v.hint="Nochmal druecken: "..id.." wird stillgelegt (nur fuer den Ersatz durch einen anderen Computer). Meldungen von ihr werden nicht mehr beachtet."
else
arm.retire=false
local ok,err=role.retire(id)
v.hint=ok and("Node "..id.." ist stillgelegt.")or err
end
return true
end,
}


local netz_arm={}
local function two_step(kind,record_id,text,fn)
if netz_arm[kind]~=record_id then
netz_arm[kind]=record_id
return"Nochmal druecken: "..text
end
netz_arm[kind]=nil
local ok,err=fn()
return ok and"Geloescht."or err
end

local function find_station_by_name(name)
local wanted=tostring(name or""):match("^%s*(.-)%s*$"):lower()
for _,st in ipairs(role.netz.stations())do
if st.name:lower()==wanted then return st end
end
end

local KIND_TEXT={personenbahnhof="Personenbahnhof",gueterbahnhof="Gueterbahnhof",depot="Depot"}
local function station_kind(text)
local want=tostring(text or""):match("^%s*(.-)%s*$"):lower()
if want=="personen"or want=="personenbahnhof"or want=="p"then return"personenbahnhof"end
if want=="gueter"or want=="gueterbahnhof"or want=="g"then return"gueterbahnhof"end
if want=="depot"or want=="d"then return"depot"end
return want
end


pages[#pages+1]=forms.page({
id="betriebsstellen",title="Betriebsstellen",new_label="Neu",
empty="Noch keine Betriebsstelle. Eine Anmeldung gehoert zu einer Betriebsstelle (Personenbahnhof, Gueterbahnhof oder Depot), die hier angelegt wird.",
items=function()
local items,records={},{}
for i,st in ipairs(role.netz.stations())do
items[i]={text=st.name.."  ("..st.id..")",detail=KIND_TEXT[st.kind]..(st.site_name and(", Standort "..st.site_name)or"")}
records[i]=st
end
return items,records
end,
fields={
{id="name",label="Name der Betriebsstelle",max=30,width=34},
{id="art",label="Art: personenbahnhof, gueterbahnhof, depot",max=16,width=24,default="personenbahnhof"},
{id="standort",label="Standort (Name, leer = keiner)",max=30,width=34},
},
edit=function(st)return{name=st.name,art=st.kind,standort=st.site_name or""}end,
on_save=function(values,record)
local kind=station_kind(values.art)
if record then
return role.netz.set_station(record.id,{name=values.name,kind=kind,site=values.standort,if_rev=record.rev})
end
local id,err=role.netz.add_station({name=values.name,kind=kind,site=values.standort})
if not id then return nil,err end
return true
end,
extra={
{id="loeschen",label=function(st)return st and netz_arm.station==st.id and"Wirklich?"or"Loeschen"end,kind="danger",
run=function(v,st)return two_step("station",st.id,"die Betriebsstelle "..st.name.." wird geloescht.",function()return role.netz.remove_station(st.id)end)end},
},
})

pages[#pages+1]={
id="vorlagen",title="Vorlagen",
render=function(v,rect)
local state=v.page_state("vorlagen")
state.list=state.list or{index=1}
state.screen=state.screen or"liste"
state.fields=state.fields or{
id={value="",max=16},title={value="",max=30},train={value="",max=16},stops={value="",max=120},
station={value="",max=40},count={value="7",max=6},
}
if state.screen=="liste"then
local items={}
state.templates={}
for i,info in ipairs(templates_info())do
items[#items+1]={text=info.title..(info.priority=="bevorzugt"and" (bevorzugt)"or""),detail=info.active and("Auftrag "..info.active.id..": "..(STATE_TEXT[info.active.state]or info.active.state))or("Zug "..info.train),kind=info.active and"wait"or"dim"}
state.templates[i]=info
end
W.list(v,"vorlagen",rect,items,state.list,{empty="Noch keine Vorlage. Mit 'Neue Vorlage' anlegen."})
elseif state.screen=="neu1"then
W.label(v,rect.x+1,rect.y,(state.edit and"Vorlage aendern"or"Neue Vorlage").." (1/2)","hell")
W.field(v,"id",rect.x+1,rect.y+2,math.min(24,rect.w-2),state.edit and"Kennung (bleibt)"or"Kennung (z.B. weizen)",state.fields.id)
W.field(v,"title",rect.x+1,rect.y+5,math.min(34,rect.w-2),"Titel (z.B. Weizen liefern)",state.fields.title)
elseif state.screen=="neu2"then
W.label(v,rect.x+1,rect.y,(state.edit and"Vorlage aendern"or"Neue Vorlage").." (2/2)","hell")
W.field(v,"train",rect.x+1,rect.y+2,math.min(24,rect.w-2),"Zug (Kennung, angemeldet)",state.fields.train)
W.field(v,"stops",rect.x+1,rect.y+5,rect.w-2,"Halte: Bahnhof:Sekunden:Menge; naechster ...",state.fields.stops)
W.label(v,rect.x+1,rect.y+8,"Beispiel: Weizenhof:5:640; Zentrallager:3","dim",rect.w-2)
W.label(v,rect.x+1,rect.y+9,"Danach faehrt der Zug zum ersten Halt zurueck.","dim",rect.w-2)
elseif state.screen=="muster"then
W.label(v,rect.x+1,rect.y,"Mengenmuster erfassen","hell")
W.label(v,rect.x+1,rect.y+1,"Lege in Create am Bahnhof einen Fahrplan mit einer Fracht-","dim",rect.w-2)
W.label(v,rect.x+1,rect.y+2,"bedingung (Gegenstand, Menge) an, z.B. Weizen, Menge 7.","dim",rect.w-2)
W.field(v,"station",rect.x+1,rect.y+4,math.min(34,rect.w-2),"Bahnhof, an dem der Zug steht (Create-Name)",state.fields.station)
W.field(v,"count",rect.x+1,rect.y+7,10,"Die Zahl, die du eingestellt hast",state.fields.count)
if role.sample_status then W.label(v,rect.x+1,rect.y+10,role.sample_status.text,role.sample_status.kind,rect.w-2)end
if samples.item_threshold and not role.sample_status then W.label(v,rect.x+1,rect.y+10,"Ein Muster ist gespeichert.","ok",rect.w-2)end
end
end,
actions=function(v)
local state=v.page_state("vorlagen")
local screen=state.screen or"liste"
if screen=="liste"then
local info=state.templates and state.templates[(state.list or{index=1}).index]
return{
{id="anfordern",label="Anfordern",enabled=info~=nil,reason="Erst eine Vorlage waehlen."},
{id="neu",label="Neu",kind="secondary"},
{id="vl_aendern",label="Aendern",kind="secondary",enabled=info~=nil,reason="Erst eine Vorlage waehlen."},
{id="prio",label="Prio",kind="secondary",enabled=info~=nil,reason="Erst eine Vorlage waehlen."},
{id="muster",label="Muster",kind="secondary"},
{id="vl_loeschen",label=arm.template==(info and info.id)and info~=nil and"Wirklich?"or"Loeschen",kind="danger",enabled=info~=nil,reason="Erst eine Vorlage waehlen."},
}
elseif screen=="muster"then
return{{id="lesen",label="Fahrplan lesen",side="rechts"},{id="vl_zurueck",label="Fertig",kind="secondary",side="rechts"}}
end
return{
{id=screen=="neu2"and"vl_speichern"or"vl_weiter",label=screen=="neu2"and"Speichern"or"Weiter",side="rechts"},
{id="vl_zurueck",label="Zurueck",kind="secondary",side="rechts"},
}
end,
on_action=function(v,id)
local state=v.page_state("vorlagen")
local f=state.fields
if id=="act:anfordern"then
local info=state.templates and state.templates[state.list.index]
if not info then return true end
local order,new=role.demand(info.id,nil)
v.hint=order and((new and"Auftrag "or"Laeuft schon: ")..order.id)or tostring(new)
drive_all()
return true
elseif id=="act:neu"then
f.id.value,f.title.value,f.train.value,f.stops.value="","","",""
state.edit=nil
state.screen="neu1"
return true
elseif id=="act:vl_aendern"then
local info=state.templates and state.templates[state.list.index]
if not info then return true end
local template=role.orders.template(info.id)
if not template then return true end
f.id.value,f.title.value,f.train.value=template.id,template.title,template.train
f.stops.value=orderslib.format_stops(template.stops)
state.edit=info.id
state.screen="neu1"
return true
elseif id=="act:prio"then
local info=state.templates and state.templates[state.list.index]
if info then
local ok,err=role.orders.set_priority(info.id,info.priority=="bevorzugt"and"normal"or"bevorzugt")
v.hint=ok and("Prioritaet: "..(info.priority=="bevorzugt"and"normal"or"bevorzugt"))or err
end
return true
elseif id=="act:vl_loeschen"then
local info=state.templates and state.templates[state.list.index]
if not info then return true end
if arm.template~=info.id then
arm.template=info.id
v.hint="Nochmal druecken: Vorlage "..info.title.." loeschen."
else
arm.template=nil
local ok,err=role.remove_template(info.id)
v.hint=ok and("Vorlage "..info.title.." geloescht.")or err
end
return true
elseif id=="act:muster"then
role.sample_status=nil
state.screen="muster"
return true
elseif id=="act:lesen"then
local ok,why=role.read_sample(f.station.value,f.count.value)
if not ok then v.hint=why end
return true
elseif id=="act:vl_weiter"then
if f.id.value==""or f.title.value==""then v.hint="Kennung und Titel sind noetig."return true end
state.screen="neu2"
return true
elseif id=="act:vl_zurueck"then
if state.screen~="neu2"then state.edit=nil end
state.screen=(state.screen=="neu2")and"neu1"or"liste"
return true
elseif id=="act:vl_speichern"then
local ok,err=role.create_template({id=state.edit or f.id.value,title=f.title.value,train=f.train.value,stops=f.stops.value},{replace=state.edit~=nil})
if ok then
v.hint="Vorlage gespeichert."
state.edit=nil
state.screen="liste"
else
v.hint=err
end
return true
end
end,
}


pages[#pages+1]=forms.page({
id="bahnhoefe",title="Bahnhoefe",empty="Noch kein Bahnhof mit mehreren Gleisen. Einzelne Gleise brauchen keinen Eintrag.",
new_label="Neu",
items=function()
local items,records={},{}
for i,g in ipairs(role.stations.list())do
local parts={}
for _,member in ipairs(g.members)do parts[#parts+1]=member..(closed[member]and" (gesperrt)"or"")end
items[i]={text=g.name,detail=table.concat(parts,", ")}
records[i]=g
end
return items,records
end,
fields={
{id="name",label="Name (z.B. Hauptbahnhof)",max=30,width=34},
{id="members",label="Gleise (Create-Namen mit ; trennen)",max=160,width=48},
},
edit=function(g)return{name=g.name,members=table.concat(g.members,"; ")}end,
on_save=function(values,record)
local members={}
for part in(values.members or""):gmatch("[^;]+")do
local name=part:match("^%s*(.-)%s*$")
if name~=""then members[#members+1]=name end
end
if record then return role.update_station_group(record.name,values.name,members)end
if role.stations.get(values.name)then return nil,"Einen Bahnhof "..tostring(values.name).." gibt es schon: mit Aendern bearbeiten."end
return role.stations.set(values.name,members)
end,
extra={
{id="loeschen",label="Loeschen",kind="danger",run=function(v,g)
local using=role.orders.templates_using(g.name)
local ok,err=role.stations.remove(g.name)
if not ok then return err end
return#using>0 and("Bahnhof geloescht. Die Vorlage "..using[1].title.." nennt ihn noch.")or"Bahnhof geloescht (die Gleise bleiben)."
end},
{id="sperren",label="Sperre",run=function(v,g)
local name=g.members[1]
local ok,err=role.set_closed(name,not closed[name])
return ok and(name..(closed[name]and" ist gesperrt."or" ist frei."))or err
end},
},
})


pages[#pages+1]=forms.page({
id="linien",title="Linien",empty="Noch keine Linie. Eine Linie fuehrt eine Vorlage im Takt aus.",new_label="Neu",
items=function()
local items,records={},{}

local ist_of={}
for _,row in ipairs(role.board())do ist_of[row.line]=row.order end
for i,line in ipairs(role.lines.list())do
local text=line.title.." alle "..line.interval.." s"..(line.priority=="bevorzugt"and" (bevorzugt)"or"")..(line.active and""or" [aus]")

local order=ist_of[line.id]
local detail="in "..math.max(0,math.floor(line.next_due-now())).." s"..(line.missed>0 and(", "..line.missed.." ausgel.")or"")
..", "..(order and(order.train.." "..(STATE_TEXT[order.state]or order.state).." "..math.min(order.leg,order.legs).."/"..order.legs)or"kein Zug")
if line.note then detail=detail..". "..line.note end
items[i]={text=text,detail=detail,kind=line.active and(order and STATE_KIND[order.state]or"text")or"dim"}
records[i]=line
end
return items,records
end,
fields={
{id="id",label="Kennung (z.B. pendel)",max=16,width=24},
{id="title",label="Titel",max=30,width=34},
{id="template",label="Vorlage (Kennung)",max=16,width=24},
{id="trains",label="Zuege (Kennungen mit ; trennen)",max=80,width=48},
{id="interval",label="Takt in Sekunden (Betriebszeit)",max=6,width=12,default="300"},
{id="priority",label="Prioritaet: normal oder bevorzugt",max=10,width=14,default="normal"},
},
edit=function(line)return{id=line.id,title=line.title,template=line.template,trains=table.concat(line.trains,"; "),interval=line.interval,priority=line.priority}end,
on_save=function(values,record)

if record then values.id=record.id
elseif role.lines.get(values.id)then return nil,"Die Linie "..tostring(values.id).." gibt es schon: mit Aendern bearbeiten."end
local trains={}
for part in(values.trains or""):gmatch("[^;]+")do
local id=part:match("^%s*(.-)%s*$")
if id~=""then trains[#trains+1]=id end
end
for _,id in ipairs(trains)do
if not role.register.get(id)then return nil,"Der Zug "..id.." ist nicht angemeldet."end
end
if not role.orders.template(values.template)then return nil,"Die Vorlage "..tostring(values.template).." gibt es nicht."end
return role.lines.set({id=values.id,title=values.title,template=values.template,trains=trains,interval=tonumber(values.interval),priority=values.priority~=""and values.priority or"normal"})
end,
extra={
{id="aus",label="Ein/Aus",run=function(v,line)
line.active=not line.active
role.lines.save()
return line.active and"Linie laeuft."or"Linie angehalten: keine neuen Termine."
end},
{id="loeschen",label="Loeschen",kind="danger",run=function(v,line)local ok,err=role.lines.remove(line.id)return ok and"Linie geloescht (laufende Auftraege bleiben)."or err end},
},
})


local ZSTATE={registriert="registriert",gesteuert="gesteuert",uebergabe="Uebergabe offen",abgestellt="abgestellt",ausgeschleust="ausgeschleust"}
local depot_arm={}
pages[#pages+1]={
id="depot",title="Depot",
render=function(v,rect)
local state=v.page_state("depot")
state.list=state.list or{index=1}
state.screen=state.screen or"liste"
state.target=state.target or{value="",max=40}
if state.screen=="abstellen"then
W.label(v,rect.x+1,rect.y,"Zug abstellen: "..tostring(state.train_id),"hell",rect.w-2)
W.field(v,"ziel",rect.x+1,rect.y+2,math.min(40,rect.w-2),"Abstellstation (Bahnhof oder Gleis-Name)",state.target)
W.label(v,rect.x+1,rect.y+5,"Der Zug faehrt als normaler Auftrag dorthin und wartet dort.","dim",rect.w-2)
return
end
local items={}
state.trains={}
for i,train in ipairs(role.register.list())do
local pos=train.position
local where=pos and(pos.kind=="am_bahnhof"and("am Bahnhof "..tostring(pos.where))or pos.kind)or"unbekannt"
local order=active_order_of(train.id)
local kind=train.state=="gesteuert"and"text"or(train.state=="abgestellt"and"dim"or"attention")
items[#items+1]={text=train.id.." "..train.display_name,detail=(ZSTATE[train.state]or train.state)..", "..tostring(train.mode)..", "..where..(order and(", Auftrag "..order.id)or""),kind=kind}
state.trains[i]=train
end
local list_rect={x=rect.x,y=rect.y,w=rect.w,h=rect.h-1}
W.list(v,"depot",list_rect,items,state.list,{empty="Noch kein Zug angemeldet."})
if role.depot_status then W.label(v,rect.x+1,rect.y+rect.h-1,role.depot_status.text,role.depot_status.kind,rect.w-2)end
end,
actions=function(v)
local state=v.page_state("depot")
if state.screen=="abstellen"then
return{{id="dp_los",label="Abstellen",side="rechts"},{id="dp_zurueck",label="Zurueck",kind="secondary",side="rechts"}}
end
local train=state.trains and state.trains[(state.list or{index=1}).index]
local list={}
local s=train and train.state
local busy=train and active_order_of(train.id)~=nil
if s=="gesteuert"then
list[#list+1]={id="dp_abstellen",label="Abstellen",enabled=not busy,reason="Der Zug hat einen laufenden Auftrag."}
list[#list+1]={id="dp_ausschleusen",label=depot_arm.eject and"Wirklich?"or"Ausschleusen",kind="danger",enabled=not busy,reason="Der Zug hat einen laufenden Auftrag."}
list[#list+1]={id="dp_art",label="Art",kind="secondary",enabled=not busy,reason="Waehrend eines Auftrags wechselt die Betriebsart nicht."}
elseif s=="abgestellt"then
list[#list+1]={id="dp_aktivieren",label="Aktivieren"}
list[#list+1]={id="dp_ausschleusen",label=depot_arm.eject and"Wirklich?"or"Ausschleusen",kind="danger"}
elseif train then
list[#list+1]={id="dp_aufnehmen",label=depot_arm.take and"Wirklich?"or"Aufnehmen",kind="primary"}
else
list[#list+1]={id="dp_aufnehmen",label="Aufnehmen",enabled=false,reason="Erst einen Zug waehlen."}
end
return list
end,
on_action=function(v,id)
local state=v.page_state("depot")
local train=state.trains and state.trains[state.list.index]
local function say(ok,err)v.hint=ok and(role.depot_status and role.depot_status.text)or err return true end
if id=="act:dp_abstellen"and train then
state.screen,state.train_id,state.target.value="abstellen",train.id,""
return true
elseif id=="act:dp_zurueck"then
state.screen="liste"
return true
elseif id=="act:dp_los"then
local order,why=role.park(state.train_id,state.target.value)
if order then state.screen="liste"end
v.hint=why
return true
elseif id=="act:dp_aktivieren"and train then
local ok,why=role.activate(train.id)
return say(ok,why)
elseif id=="act:dp_art"and train then
local ok,why=role.cycle_mode(train.id)
return say(ok,why)
elseif id=="act:dp_ausschleusen"and train then
if not depot_arm.eject then
depot_arm.eject=true
v.hint="Nochmal druecken, wenn der Fahrbetrieb des Zuges geklaert ist (Fahrplan, Freigabe). Der Create-Fahrplan bleibt im Zug."
else
depot_arm.eject=false
local ok,why=role.eject(train.id)
say(ok,why)
end
return true
elseif id=="act:dp_aufnehmen"and train then
if not depot_arm.take then
depot_arm.take=true
v.hint="Nochmal druecken: der Zug steht am Haltepunkt, der Fahrbetrieb ist geklaert, der Warteauftrag darf erteilt werden."
else
depot_arm.take=false
local ok,why=role.take_over(train.id)
say(ok,why)
end
return true
end
end,
}


local hold_arm={}
pages[#pages+1]={
id="stoerungen",title="Stoerungen",
render=function(v,rect)
local state=v.page_state("stoerungen")
state.list=state.list or{index=1}
state.rows={}
local items={}
for _,f in ipairs(role.faults())do items[#items+1]={text=f.who,detail=f.text,kind=f.kind}end

for _,row in ipairs(role.unknown_list())do
items[#items+1]={text="Fremd: "..row.name,detail=(row.present and"steht "or"war ").."an "..tostring(row.station or row.track).." ("..tostring(row.node)..")",kind=row.present and"attention"or"dim"}
state.rows[#items]=row
end
local drain=role.drain_state()
W.list(v,"stoerungen",{x=rect.x,y=rect.y,w=rect.w,h=rect.h-1},items,state.list,{empty="Keine Stoerung und keine fremden Zuege bekannt."})
W.label(v,rect.x+1,rect.y+rect.h-1,"Auftraege: "..drain.active.." offen, "..drain.committed.." mit Freigabe/unterwegs","dim",rect.w-2)
end,
actions=function(v)
local is_held=held()
local state=v.page_state("stoerungen")
local row=state.rows and state.rows[(state.list or{index=1}).index]
return{
{id="halten",label=is_held and(hold_arm.resume and"Wirklich?"or"Fortsetzen")or"Halten",kind=is_held and"primary"or"danger"},
{id="pruefen",label="Pruefen",kind="secondary"},
{id="vergessen",label="Vergessen",kind="secondary",enabled=row~=nil and not row.present,reason="Nur ein fremder Zug, der nicht mehr am Gleis steht."},
}
end,
on_action=function(v,id)
if id=="act:halten"then
if operation.hold then
if not hold_arm.resume then
hold_arm.resume=true
v.hint="Nochmal druecken: neue Abfahrten werden wieder freigegeben."
else
hold_arm.resume=false
local ok,err=role.set_hold(false)
v.hint=ok and"Betrieb fortgesetzt."or err
end
else
local ok,err=role.set_hold(true,"vom Bediener")
v.hint=ok and"Neue Abfahrten sind zurueckgehalten; Fahrten unterwegs laufen weiter."or err
end
return true
elseif id=="act:pruefen"then
v.hint="Zustandsabfrage an "..role.refresh_all().." Nodes gesendet."
return true
elseif id=="act:vergessen"then
local state=v.page_state("stoerungen")
local row=state.rows and state.rows[state.list.index]
if row then
local ok,why=role.forget_unknown(row.name)
v.hint=ok and"Aus der Liste genommen; Belegungen bleiben ueber ihre eigenen Meldungen bestehen."or why
end
return true
end
end,
}


local directory_pages={betriebsstellen=true}
local ordered={}
for _,pg in ipairs(pages)do if not directory_pages[pg.id]then ordered[#ordered+1]=pg end end
for _,pg in ipairs(pages)do if directory_pages[pg.id]then ordered[#ordered+1]=pg end end
role.pages=ordered
return role
end

return M
