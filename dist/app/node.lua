





local storelib=require("core.store")
local clocklib=require("core.clock")
local tickerlib=require("core.ticker")
local journallib=require("core.journal")
local msg=require("core.msg")
local netlib=require("core.net")
local detect=require("dev.detect")
local bind=require("dev.bind")
local eventslib=require("dev.events")
local viewlib=require("ui.view")
local W=require("ui.widgets")
local setup_page=require("setup.page")
local version=require("core.version")
local envcheck=require("core.envcheck")
local dataformat=require("core.dataformat")
local model=require("setup.model")
local ser=require("core.ser")
local chunks=require("core.chunks")
local adler=require("core.adler")

local M={}

local DATA="/crn_data"
local CONFIG=DATA.."/config.lua"
local CLAIM=DATA.."/anforderung.lua"
local MAX_MESSAGES=60

local UI_EVENTS={key=true,char=true,mouse_click=true,monitor_touch=true}

function M.new(env)
local n={}
n.hooks={on_event={},on_message={},tick={},pages={}}
n.messages={}
n.running=false

if not env.fs.exists(DATA)then env.fs.makeDir(DATA)end
local store=storelib.new(env.fs)
store.heal(CONFIG)
store.heal(DATA.."/clock.lua")
n.store=store



local format_target=env.data_format or dataformat.FORMAT
local format_status,format_old,format_dir,format_error=dataformat.check(env.fs,store,{program=version.number,format=env.data_format,migrations=env.data_steps})
n.format_status,n.format_old,n.format_dir,n.format_error=format_status,format_old,format_dir,format_error
n.format_blocked=format_status=="zu_neu"or format_status=="fehlgeschlagen"

n.clock=clocklib.new({raw=env.raw_clock,store=store,path=DATA.."/clock.lua"})
n.journal=journallib.new({fs=env.fs,path=DATA.."/journal.log",now=n.clock.now})
n.ticker=tickerlib.new(n.clock)
n.config=store.load(CONFIG)

if n.config and n.config.status~="aktiv"then n.config=nil end
n.scan=detect.scan(env.peripheral)


n.env_hold=false
if n.config and n.config.status=="aktiv"then
local status=envcheck.check(store,DATA.."/umgebung.lua",n.scan,env.host)
n.env_status=status
n.env_hold=status=="geaendert"
end

function n.notify(level,text)
n.messages[#n.messages+1]={level=level,text=text,t=n.clock.now(),acked=false}
if#n.messages>MAX_MESSAGES then table.remove(n.messages,1)end
n.dirty=true
end

if n.format_status=="migriert"then
n.notify("info","Daten an das neue Programm angepasst (Format "..tostring(n.format_old).." auf "..tostring(format_target).."). Sicherung: "..tostring(n.format_dir))
end

function n.status()
if not n.config then return{text="Einrichtung",kind="wait"}end
if n.format_status=="fehlgeschlagen"then return{text="Datenanpassung gescheitert",kind="halt"}end
if n.format_blocked then return{text="Datenformat zu neu",kind="halt"}end
if n.env_hold then return{text="Pruefung noetig",kind="attention"}end
return{text="Bereit",kind="ok"}
end

local function role_text()
if not n.config then return"nicht eingerichtet"end
local names={}
for _,r in ipairs(n.config.node.roles)do names[#names+1]=r end
return table.concat(names,"+")
end

local ctx={

title=function(width)
if not n.config then return"CRN - noch nicht eingerichtet"end
local who=n.config.node.name~=""and n.config.node.name or n.config.node.id
local full=who.." - "..role_text()
width=width or 40
if#full<=width then return full end
return W.fit(who,width)
end,
status=function()return n.status()end,
on_action=function(v,id)
if id=="back"then v.set_page("uebersicht")end
end,
node=n,
}


local function wireless(name)
local ok,w=pcall(env.peripheral.call,name,"isWireless")
return ok and w==true
end


function n.confirm_environment()
if not n.env_hold then return true,"Es ist keine Pruefung noetig."end
n.scan=detect.scan(env.peripheral)
for _,p in ipairs(model.validate(n.config,n.scan))do
if p.code=="geraet_fehlt"or p.code=="geraet_art"or p.code=="geraet_methoden"then
return false,"Pruefung nicht bestanden: "..p.text
end
end
envcheck.accept(store,DATA.."/umgebung.lua",n.scan,env.host)
n.env_hold,n.env_status=false,"gleich"
n.notify("info","Schnittstellenpruefung bestanden: die Automatik laeuft wieder.")
return true,"Pruefung bestanden."
end


local function scale_text(scale)return(string.format("%.1f",scale):gsub("%.",","))end


local function monitor_info(id)
local spec=n.config and n.config.devices[id]
if not spec or spec.kind~="monitor"then return nil end
local info={id=id,name=spec.device,scale=spec.text_scale or 1}
for _,v in ipairs(n.views)do
if v.name==spec.device then info.target=v.target end
end
local target=info.target
if target then
info.can=type(target.setTextScale)=="function"
if type(target.getTextScale)=="function"then
local ok,current=pcall(target.getTextScale)
if ok and type(current)=="number"then info.scale=current end
end
local ok,w,h=pcall(target.getSize)
if ok then info.w,info.h=w,h end
end
return info
end


function n.toggle_monitor_scale(id)
local info=monitor_info(id)
if not info then return false,"Das ist kein Monitor."end
if not info.target then return false,"Der Monitor "..info.name.." ist nicht erreichbar."end
if not info.can then return false,"Textgroesse geht an diesem Monitor nicht."end
local new=(info.scale==0.5)and 1 or 0.5
if not pcall(info.target.setTextScale,new)then return false,info.name.." lehnt Textgroesse "..scale_text(new).." ab."end
n.config.devices[id].text_scale=new
local saved=n.save_config()
n.dirty=true
local ok,w,h=pcall(info.target.getSize)
local text=info.name..": Textgroesse "..scale_text(new)..(ok and string.format(", %dx%d Zeichen.",w,h)or".")
if not saved then text=text.." Nicht gespeichert."end
return true,text
end


local pages={}

pages[#pages+1]={
id="uebersicht",title="Uebersicht",
render=function(v,rect)
local y=rect.y
local function line(text,kind)W.label(v,rect.x+1,y,text,kind or"text",rect.w-2)y=y+1 end
line(version.name.." "..version.number,"hell")
if n.config then
line("Node: "..(n.config.node.name~=""and(n.config.node.name.." ("..n.config.node.id..")")or n.config.node.id))
line("Rolle: "..role_text())
line("Netz: "..n.config.network.name..(n.config.network.central_id and("   Leitstelle: "..n.config.network.central_id)or"   (Leitstelle)"))
line("Zustand: "..n.config.status.."   Einrichtung Nr. "..tostring(n.config.revision))

local central=n.roles and n.roles.zentrale
local step=central and central.next_step and central.next_step()
if step then
for _,text in ipairs(W.wrap(step,rect.w-2))do line(text,"attention")end
end

if n.format_status=="fehlgeschlagen"then
for _,text in ipairs(W.wrap("Daten nicht angepasst, nichts veraendert, Automatik aus: "..tostring(n.format_error),rect.w-2))do line(text,"halt")end
elseif n.format_blocked then
for _,text in ipairs(W.wrap("Die Daten haben ein neueres Format ("..tostring(n.format_old)..") als dieses Programm: Automatik aus.",rect.w-2))do line(text,"halt")end
end
else
line("Dieser Computer ist noch nicht eingerichtet.","attention")
line("Weiter mit der Seite 'Einrichtung'.")
end
y=y+1
local seconds=math.floor(n.clock.now())
line(string.format("Betriebszeit: %d:%02d:%02d%s",math.floor(seconds/3600),math.floor(seconds/60)%60,seconds%60,
n.clock.resumed()and" (fortgesetzt)"or""),"dim")
line("Freier Platz: "..env.fs.getFreeSpace("/").." Byte","dim")
local counts={station=0,observer=0}
for _,d in ipairs(n.scan)do if counts[d.kind]then counts[d.kind]=counts[d.kind]+1 end end
line(string.format("Geraete: %d Bahnhof, %d Beobachter",counts.station,counts.observer),"dim")
local radio={}
for _,d in ipairs(n.scan)do if d.kind=="modem"and wireless(d.name)then radio[#radio+1]=d.name end end
line("Funk: "..(#radio>0 and table.concat(radio,",")or"KEIN FUNKMODEM"),#radio>0 and"dim"or"attention")
local open=#n.journal.pending()
if open>0 then line(open.." offene Vorgaenge im Journal","wait")end
if n.env_hold then line("Modpack oder Schnittstellen haben sich geaendert: Automatik wartet auf die Pruefung.","attention")end

if n.format_status=="migriert"then line("Daten angepasst (Format "..tostring(n.format_old).."); Sicherung: "..tostring(n.format_dir),"dim")end
end,
actions=function(v)
if n.env_hold then return{{id="umgebung",label="Pruefen",kind="primary"}}end
return{}
end,
on_action=function(v,id)
if id=="act:umgebung"then
local ok,text=n.confirm_environment()
v.hint=text
return true
end
end,
}


local function device_items(wide)
local checks=n.config and bind.check(n.config.devices,n.scan)or{}
local by_device={}
if n.config then
for id,spec in pairs(n.config.devices)do by_device[spec.device]={id=id,check=checks[id]}end
end
local items,meta={},{}
for _,d in ipairs(n.scan)do
local bound=by_device[d.name]
local detail=table.concat(d.types,",")
local kind="dim"
if bound then
detail=detail.." -> "..bound.id.." ("..bound.check.status..")"
if bound.check.status~="ok"then kind="attention"end
local info=monitor_info(bound.id)
if wide and info and info.w then detail=detail..string.format(", %dx%d Zeichen, Textgroesse %s",info.w,info.h,scale_text(info.scale))end
end
items[#items+1]={text=d.name,detail=detail,kind=kind}
meta[#items]=bound and bound.id or nil
end

if n.config then
for id,check in pairs(checks)do
if check.status=="fehlt"then
items[#items+1]={text=n.config.devices[id].device,detail="FEHLT ("..id..")",kind="halt"}
meta[#items]=id
end
end
end
return items,meta
end

pages[#pages+1]={
id="geraete",title="Geraete",
render=function(v,rect)
local state=v.page_state("geraete")
state.list=state.list or{index=1}
W.list(v,"geraete",rect,(device_items(v.layout.mode=="gross")),state.list,{empty="Keine Geraete angeschlossen."})
end,

actions=function(v)
local state=v.page_state("geraete")
local _,meta=device_items()
local info=monitor_info(meta[state.list and state.list.index or 1])
if not info then return{{id="textgroesse",label="Textgroesse",kind="secondary",enabled=false,reason="Erst einen Monitor in der Liste waehlen."}}end
local label="Textgroesse "..scale_text(info.scale==0.5 and 1 or 0.5)
if not info.target then return{{id="textgroesse",label=label,kind="secondary",enabled=false,reason="Der Monitor "..info.name.." ist nicht erreichbar."}}end
if not info.can then return{{id="textgroesse",label=label,kind="secondary",enabled=false,reason="Textgroesse geht an diesem Monitor nicht."}}end
return{{id="textgroesse",label=label,kind="secondary"}}
end,
on_action=function(v,id)
if id~="act:textgroesse"then return false end
local state=v.page_state("geraete")
local _,meta=device_items()
local ok,text=n.toggle_monitor_scale(meta[state.list and state.list.index or 1])
v.hint=text
return true
end,
}

pages[#pages+1]={
id="meldungen",title="Meldungen",
render=function(v,rect)
local state=v.page_state("meldungen")
state.list=state.list or{index=1}
local items={}
for i=#n.messages,1,-1 do
local m=n.messages[i]
local kind=m.acked and"dim"or(m.level=="fehler"and"halt"or m.level=="warnung"and"attention"or"text")
items[#items+1]={text=m.text,detail=string.format("%d s%s",math.floor(m.t),m.acked and" (quittiert)"or""),kind=kind,index=i}
end
state.items=items
W.list(v,"meldungen",rect,items,state.list,{empty="Keine Meldungen."})
end,
actions=function(v)
local state=v.page_state("meldungen")
local selected=state.items and state.items[(state.list or{index=1}).index]
return{{id="quittieren",label="Quittieren",enabled=selected~=nil,reason="Keine Meldung gewaehlt."}}
end,
on_action=function(v,id)
if id=="act:quittieren"then
local state=v.page_state("meldungen")
local selected=state.items and state.items[state.list.index]
if selected then
n.messages[selected.index].acked=true
v.hint="Quittiert; Belegung und Signale bleiben."
end
return true
end
end,
hint=function()return"Quittieren aendert nie Belegung oder Signal."end,
}

n.setup=setup_page.new({
scan=function()n.scan=detect.scan(env.peripheral)return n.scan end,
env=env,
now=function()return n.clock.now()end,
store=store,
config_path=CONFIG,
config=function()return n.config end,
modem_is_wireless=wireless,
role_available=function(role)
if not env.fs.exists("/crn/manifest.lua")then return true end
local files={zentrale="zentrale",passagierbahnhof="station",gueterbahnhof="station",depot="station",anmeldung="anmeldung"}
return files[role]~=nil and env.fs.exists("/crn/roles/"..files[role]..".lua")
end,
notify=n.notify,
fetch_config=function(central_id,node_id)return n.fetch_config(central_id,node_id)end,
fetch_status=function()return n.fetch_state end,
search_networks=function()return n.search_networks()end,
search_status=function()return n.search_status()end,
mark_dirty=function()n.dirty=true end,
directory_claim=function(central_id,claim,role,legacy_id,extra)return n.directory_claim(central_id,claim,role,legacy_id,extra)end,
directory_stations=function(central_id)return n.directory_stations(central_id)end,
directory_backups=function(central_id)return n.directory_backups(central_id)end,
directory_status=function()return n.directory_status()end,
directory_reset=function()return n.directory_reset()end,
claim=function()return n.claim()end,
new_claim=function()return n.new_claim()end,
new_token=function()return n.new_token()end,
on_saved=function(config)
n.config=config
n.rebuild_views()
n.start_services()
n.dirty=true
end,
})
pages[#pages+1]=n.setup


local MODE_TEXT={auto="automatisch",melden="nur melden",aus="aus"}
local MODE_NEXT={auto="melden",melden="aus",aus="auto"}
local update_armed=false
pages[#pages+1]={
id="update",title="Update",
render=function(v,rect)
local y=rect.y
local function line(text,kind)
for _,part in ipairs(W.wrap(text,rect.w-2))do W.label(v,rect.x+1,y,part,kind or"text",rect.w-2)y=y+1 end
end
local u=n.updater
if not u then
line("Dieser Computer wurde nicht ueber den Installer eingerichtet: keine Selbstaktualisierung.","attention")
return
end
local st=u.state()
line("Installiert: "..tostring(st.version).." (Stand "..tostring(st.id)..")","hell")
line("Kanal: "..tostring(st.ref).."   Rolle: "..tostring(st.role),"dim")
line("Betriebsart: "..MODE_TEXT[st.mode]..(st.replace and"   (Ersetzen erlaubt)"or""))
y=y+1
if st.moving==false then
line("Feste Version: wird nicht automatisch aktualisiert.","dim")
elseif st.available then
line("Neu: Version "..tostring(st.available.version).." (Stand "..st.available.id..")","attention")
elseif st.checked then
line("Aktuell, geprueft vor "..math.floor((n.clock.now()-st.checked)/60).." min.","dim")
else
line("Noch nicht geprueft.","dim")
end
if st.probe then line("Neuer Stand in der Probezeit: nach 2 Minuten ohne Absturz gilt er als bestaetigt.","wait")end
if st.skipped then line("Zurueckgenommener Stand "..st.skipped.." wird nicht mehr versucht.","attention")end
if st.note then line(st.note,"attention")end
end,
actions=function(v)
local u=n.updater
if not u then return{}end
local st=u.state()
local list={{id="update_pruefen",label="Pruefen",kind="secondary"},{id="update_modus",label="Modus: "..MODE_TEXT[st.mode],kind="secondary"}}
if st.available then list[#list+1]={id="update_jetzt",label=update_armed and"Wirklich?"or"Installieren",kind="danger"}end
return list
end,
on_action=function(v,id)
local u=n.updater
if not u then return end
if id=="act:update_modus"then
update_armed=false
u.set_mode(MODE_NEXT[u.state().mode])
return true
elseif id=="act:update_pruefen"then
update_armed=false
local _,text=u.check()
v.hint=text
return true
elseif id=="act:update_jetzt"then
if not update_armed then
update_armed=true
v.hint="Der Computer startet danach neu. Zum Bestaetigen noch einmal druecken."
return true
end
update_armed=false
local _,text=u.install({force=true})
v.hint=text
return true
end
end,
}

function n.all_pages()
local list={}
for _,p in ipairs(pages)do list[#list+1]=p end
for _,p in ipairs(n.hooks.pages)do list[#list+1]=p end
return list
end


n.views={}
function n.rebuild_views()
local old={}
for _,v in ipairs(n.views)do old[v.name or"terminal"]=v end
n.views={}
local function add(name,target)
local v=old[name or"terminal"]
if v then
v.target=target
v.pages=n.all_pages()
else
v=viewlib.new({target=target,name=name,ctx=ctx,pages=n.all_pages()})
if not n.config then v.set_page("einrichtung")end
end
n.views[#n.views+1]=v
end
add(nil,env.term)
if n.config then
local ids={}
for id,d in pairs(n.config.devices)do if d.kind=="monitor"then ids[#ids+1]=id end end
table.sort(ids)
for _,id in ipairs(ids)do
local name=n.config.devices[id].device
local target=env.wrap and env.wrap(name)
if target then

local scale=n.config.devices[id].text_scale
if scale and target.setTextScale then pcall(target.setTextScale,scale)end
add(name,target)
end
end
end
end

function n.render()
for _,v in ipairs(n.views)do
local ok,err=pcall(v.render)
if not ok then n.notify("fehler","Anzeige "..tostring(v.name or"Terminal")..": "..tostring(err))end
end
n.dirty=false
end


local function setup_net()
if not n.config or n.config.status~="aktiv"then return end
local info=netlib.open({rednet=env.rednet,peripheral=env.peripheral})
n.net_info=info


if not(n.factory and n.factory_id==n.config.node.id)then
n.factory=msg.new({node_id=n.config.node.id,boot_id=n.clock.boot_id(),epoch=function()return n.own_epoch or n.inbox.epoch()end})
n.factory_id=n.config.node.id
end
n.inbox=msg.inbox({node_id=n.config.node.id,central_id=n.config.network.central_id or n.config.node.id})
n.net=netlib.new({rednet=env.rednet,factory=n.factory,inbox=n.inbox,clock=n.clock})
if#info.opened==0 then n.notify("fehler","Kein Modem fuer den Funk gefunden.")
elseif info.fallback then n.notify("warnung","Kein Funkmodem: es wird das Kabelmodem benutzt.")end
end

function n.save_config()return store.save(CONFIG,n.config)end

function n.set_label(text)
if type(text)=="string"and env.set_label then return pcall(env.set_label,text)end
return false
end

function n.start_services()
if n.config and n.config.status=="aktiv"and n.config.node.label then n.set_label(n.config.node.label)end
setup_net()
n.router=eventslib.router({bindings=n.config and bind.routes(n.config.devices)or{},now=n.clock.now})
n.attach_roles()
end


n.env=env
local local_queue={}

function n.central_id()
if n.config and n.config.network.central_id then return n.config.network.central_id end
return n.config and n.config.node.id
end


function n.send_message(m)
if n.config and m.targetNodeId==n.config.node.id then
local_queue[#local_queue+1]=m
return"lokal"
end
if not n.net then return nil end
return n.net.send(m.targetNodeId,m)
end

function n.send_to(target,message_type,payload,extra)
if not n.factory then return nil end
local m=n.factory.make(message_type,target,payload,extra)
n.send_message(m)
return m
end



local PARTS_LIMIT=5000
local set_counter,parts_failed=0,{}
function n.next_set()
set_counter=set_counter+1
return string.format("%d.%d",n.clock.boot_id(),set_counter)
end

function n.send_parts(target,list,make,tag)
local parts,why=chunks.parts_list(list,make,PARTS_LIMIT,ser)
if not parts then
if not parts_failed[tag]then n.notify("fehler",tostring(tag).." nicht moeglich: "..tostring(why))end
parts_failed[tag]=true
return false
end
parts_failed[tag]=nil
for _,payload in ipairs(parts)do n.send_to(target,"meldung",payload)end
return true
end


function n.reply(m,status,payload)
local body={kind="antwort",status=status,antwort_auf=m.payload.kind}
for k,v in pairs(payload or{})do body[k]=v end
local reply=n.factory.make("bestaetigung",m.senderNodeId,body,{correlationId=m.messageId,requestId=m.requestId})
n.inbox.remember(m.messageId,reply)
n.send_message(reply)
return reply
end


local function run_hooks(list,...)
for i,fn in ipairs(list)do
local ok,err=pcall(fn,...)
if not ok then n.notify("fehler","Rolle "..i..": "..tostring(err))end
end
end


local function deliver_local()
local rounds=0
while#local_queue>0 and rounds<200 do
rounds=rounds+1
local m=table.remove(local_queue,1)
local status,extra=n.inbox.accept(m)
run_hooks(n.hooks.on_message,m,status,extra)
end
end

function n.handle(ev)
local kind=ev[1]
if UI_EVENTS[kind]then
for _,v in ipairs(n.views)do
if v.handle(ev)then n.dirty=true end
end
elseif kind=="rednet_message"then
if not n.net and n.replace_net then n.replace_receive(ev)end
if n.net then
local m,status,extra=n.net.receive(ev)
if m then
if status=="node_conflict"then n.notify("fehler","Zwei Computer melden sich als "..m.senderNodeId..".")end
run_hooks(n.hooks.on_message,m,status,extra)
end
end
elseif kind=="peripheral"or kind=="peripheral_detach"then
local before=n.scan
n.scan=detect.scan(env.peripheral)


if kind=="peripheral"and n.net and n.net_info then
local info=netlib.open({rednet=env.rednet,peripheral=env.peripheral})
local was,now_open=table.concat(n.net_info.opened,","),table.concat(info.opened,",")
n.net_info=info
if now_open~=was and#info.opened>0 then n.notify("info","Funkmodem angeschlossen: "..now_open..".")end
end
local added,removed=detect.diff(before,n.scan)
for _,name in ipairs(added)do n.notify("info","Geraet angeschlossen: "..name)end
for _,name in ipairs(removed)do n.notify("warnung","Geraet entfernt: "..name)end
n.dirty=true
elseif kind=="monitor_resize"then
n.dirty=true
elseif n.router then
local routed=n.router.route(ev)
if routed then
if routed.problem then n.notify("warnung",routed.problem..": "..tostring(routed.device))end
run_hooks(n.hooks.on_event,routed)
n.dirty=true
end
end
deliver_local()
n.ticker.poll()
end

function n.tick()
run_hooks(n.hooks.tick)
end


table.insert(n.hooks.tick,function()
if n.setup and n.setup.tick then n.setup.tick()end
end)








local BACKUP_PAYLOAD_LIMIT=5000
local backup={acked=nil,sent=-9999,ids={},failed=nil}
table.insert(n.hooks.tick,function()
if not n.config or n.config.status~="aktiv"or not n.net then return end
for _,r in ipairs(n.config.node.roles)do if r=="zentrale"then return end end
local rev=n.config.revision
if backup.acked==rev or backup.failed==rev then return end
local t=n.clock.now()
if t-backup.sent<30 then return end
backup.sent=t
local text=ser.encode(n.config)
local sum,id=adler.hex(text),n.config.node.id
local parts,why=chunks.parts_text(text,function(piece,i,count)
return{kind="konfig",node=id,revision=rev,part=i,parts=count,sum=sum,config=piece}
end,BACKUP_PAYLOAD_LIMIT,ser)
if not parts then
backup.failed=rev
n.notify("fehler","Die Konfiguration laesst sich nicht sichern: "..tostring(why))
return
end
local known=0
for _ in pairs(backup.ids)do known=known+1 end
if known>200 then backup.ids={}end
for _,payload in ipairs(parts)do
local m=n.send_to(n.central_id(),"meldung",payload)
if m then backup.ids[m.messageId]=rev end
end
end)
table.insert(n.hooks.on_message,function(m,status)
if(status~="ok"and status~="old_sequence")or m.messageType~="bestaetigung"then return end
local rev=backup.ids[m.correlationId]
local p=m.payload

if rev==nil or type(p)~="table"then return end
if p.status=="ok"and p.fertig==true then
backup.acked=rev
elseif p.status=="abgelehnt"and backup.failed~=rev then
backup.failed=rev
n.notify("warnung","Die Leitstelle hat die Konfigurationssicherung abgelehnt: "..tostring(p.grund))
end
end)


local function temporary_net(central_id)
if not n.replace_net then



local boot=n.clock.boot_id()
local unique=env.unique and tostring(env.unique()):gsub("[^%w%-]","")or""
local me="neu-"..(unique~=""and unique or tostring(boot))
n.replace_factory=msg.new({node_id=me,boot_id=boot,epoch=function()return 0 end})
n.replace_net=netlib.new({rednet=env.rednet,factory=n.replace_factory,inbox=msg.inbox({node_id=me,central_id=central_id}),clock=n.clock})
end
return n.replace_net
end


local SEARCH_SECONDS=4
n.search_state=nil
function n.search_networks()
if n.net then n.search_state={kind="halt",text="Dieser Computer ist schon eingerichtet.",networks={}}return end
local info=netlib.open({rednet=env.rednet,peripheral=env.peripheral})
if#info.opened==0 then n.search_state={kind="halt",text="Kein Modem gefunden: das Netz von Hand eingeben.",networks={}}return end
local net=temporary_net(nil)
local m=n.replace_factory.make("abfrage","*",{kind="netze"})
net.broadcast(m)
n.search_req,n.search_until=m.messageId,n.clock.now()+SEARCH_SECONDS
n.search_state={kind="wait",text="Suche laeuft ...",networks={}}
end

function n.search_status()
local st=n.search_state
if st and st.kind=="wait"and n.clock.now()>=n.search_until then
if#st.networks>0 then
st.kind,st.text="ok",#st.networks.." Netz(e) gefunden."
else
st.kind,st.text="halt","Kein Netz gefunden: Leitstelle an, Chunk geladen?"
end
end
return st
end


local function collect_network(m)
local st,p=n.search_state,m.payload
if not st or st.kind~="wait"or type(p)~="table"or p.status~="ok"then return end
local name,central=p.netz,p.zentrale
if type(name)~="string"or type(central)~="string"then return end
if#name==0 or#name>30 or not name:match("^[%w _%-]+$")then return end
if#central==0 or#central>30 or not central:match("^[%w_%-]+$")then return end
for _,known in ipairs(st.networks)do if known.zentrale==central then return end end
st.networks[#st.networks+1]={netz=name,zentrale=central,nodes=tonumber(p.nodes)or 0}
table.sort(st.networks,function(a,b)if a.netz~=b.netz then return a.netz<b.netz end return a.zentrale<b.zentrale end)
n.dirty=true
end

n.fetch_state=nil
local function fetch_request(central_id,node_id,part)
local m=n.replace_factory.make("abfrage",central_id,{kind="konfig_holen",node=node_id,part=part})
n.replace_net.send(central_id,m)
n.replace_req=m.messageId
n.fetch={central=central_id,node=node_id,part=part}
end

function n.fetch_config(central_id,node_id)
if n.net then n.fetch_state={kind="halt",text="Dieser Computer ist schon eingerichtet."}return end
local info=netlib.open({rednet=env.rednet,peripheral=env.peripheral})
if#info.opened==0 then n.fetch_state={kind="halt",text="Kein Modem gefunden."}return end
temporary_net(central_id)
n.fetch_chunks=chunks.new({max_parts=40,max_bytes=60000,max_keys=2,ttl=300,now=function()return n.clock.now()end})
fetch_request(central_id,node_id,1)
n.fetch_state={kind="wait",text="Anfrage an "..central_id.." gesendet ..."}
end



local DIR_TIMEOUT=8
n.dir_state=nil

local function dir_id(v,prefix)return type(v)=="string"and v:match("^"..prefix.."%d%d%d%d+$")~=nil and#v<=12 end
local function dir_name(v)return type(v)=="string"and#v>0 and#v<=30 and v:match("^[%w _%-]+$")~=nil end



local function dir_send(central_id,payload,handler)
local m
if n.net and n.factory then
m=n.send_to(central_id,"abfrage",payload)
if not m then n.dir_state={kind="halt",text="Kein Funk."}return end
else
local info=netlib.open({rednet=env.rednet,peripheral=env.peripheral})
if#info.opened==0 then n.dir_state={kind="halt",text="Kein Modem gefunden."}return end
temporary_net(central_id)
m=n.replace_factory.make("abfrage",central_id,payload)
n.replace_net.send(central_id,m)
end
n.dir_req,n.dir_until,n.dir_handler,n.dir_dropped=m.messageId,n.clock.now()+DIR_TIMEOUT,handler,nil
n.dir_state={kind="wait",text="Frage die Leitstelle ..."}
end

local function dir_bad(text)
n.dir_state={kind="halt",text=text or"Unerwartete Antwort der Leitstelle."}
end


function n.directory_stations(central_id)
local acc={}
local function page(after)
dir_send(central_id,{kind="betriebsstellen_liste",after=after},function(p)
if type(p.stations)~="table"then return dir_bad()end
for _,st in ipairs(p.stations)do
if type(st)~="table"or not dir_id(st.id,"BF")or not dir_name(st.name)or not(st.kind=="personenbahnhof"or st.kind=="gueterbahnhof"or st.kind=="depot")then
return dir_bad()
end
acc[#acc+1]={id=st.id,name=st.name,kind=st.kind}
end
if p.more and#acc<300 and#acc>0 then return page(acc[#acc].id)end
n.dir_state={kind="ok",text=#acc.." Betriebsstelle(n) im Netz.",stations=acc}
end)
end
page(nil)
end



local BACKUP_STATES={stillgelegt=true,ausgefallen=true,aktiv=true}
function n.directory_backups(central_id)
local acc={}
local function page(after)
dir_send(central_id,{kind="ersatz_liste",after=after},function(p)
if type(p.backups)~="table"then return dir_bad()end
for _,b in ipairs(p.backups)do
if type(b)~="table"or type(b.id)~="string"or#b.id==0 or#b.id>30 or not b.id:match("^[%w_%-]+$")or not BACKUP_STATES[b.state]then
return dir_bad()
end
local name=(type(b.name)=="string"and#b.name<=60 and b.name:match("^[%w _%-]*$"))and b.name or""
acc[#acc+1]={id=b.id,name=name,state=b.state}
end
if p.more and#acc<100 and#acc>0 then return page(acc[#acc].id)end
n.dir_state={kind="ok",text=#acc.." Node(s) mit Sicherung.",backups=acc}
end)
end
page(nil)
end


function n.directory_claim(central_id,claim,role,legacy_id,extra)
extra=extra or{}
dir_send(central_id,{kind="node_anfordern",claim=claim,role=role,roles=extra.roles,station=extra.station,legacy=legacy_id},function(p)
local node=p.node
if type(node)~="table"or not dir_id(node.id,"N")or type(node.name)~="string"or#node.name>60 or not node.name:match("^[%w _%-]+$")
or type(node.label)~="string"or#node.label>60 or not node.label:match("^[%w _%-|]+$")then
return dir_bad()
end
n.dir_state={kind="ok",text="Kennung "..node.id.." vergeben.",node={id=node.id,name=node.name,label=node.label}}
end)
end

function n.directory_status()
local st=n.dir_state
if st and st.kind=="wait"and n.clock.now()>=n.dir_until then
n.dir_req,n.dir_handler=nil,nil
n.dir_state={kind="halt",text="Die Leitstelle antwortet nicht. Laeuft sie (Chunk geladen), ist ein Ender-Modem in Reichweite?"..(n.dir_dropped and(" (Antwort verworfen: "..tostring(n.dir_dropped)..")")or"")}
st=n.dir_state
end
return st
end

function n.directory_reset()n.dir_req,n.dir_handler,n.dir_state=nil,nil,nil end



local function fresh_claim()
return string.format("c%d-%06d%06d",n.clock.boot_id(),math.random(0,999999),math.random(0,999999))
end

n.new_token=fresh_claim
function n.claim()
if n.config and n.config.node and type(n.config.node.claim)=="string"then return n.config.node.claim end
local saved=store.load(CLAIM)
if type(saved)=="table"and type(saved.claim)=="string"and#saved.claim>=8 then return saved.claim end
local claim=fresh_claim()
store.save(CLAIM,{claim=claim})
return claim
end

function n.new_claim()
local claim=fresh_claim()
if n.config and n.config.node then n.config.node.claim=nil end
store.save(CLAIM,{claim=claim})
return claim
end


local function dir_reply(m,status)
if not(n.dir_req and m.correlationId==n.dir_req)then return false end
if status~="ok"then n.dir_dropped=status return true end
local handler=n.dir_handler
n.dir_req,n.dir_handler=nil,nil
local p=m.payload
if type(p)~="table"or p.status~="ok"then
n.dir_state={kind="halt",text="Abgelehnt: "..tostring(type(p)=="table"and p.grund or"keine Begruendung")}
else
local ok=pcall(handler,p)
if not ok then dir_bad()end
end
n.dirty=true
if n.setup and n.setup.poll then n.setup.poll()end
return true
end
n.hooks.on_message[#n.hooks.on_message+1]=function(m,status)
if m.messageType=="bestaetigung"then dir_reply(m,status)end
end

function n.replace_receive(ev)
local m,status=n.replace_net.receive(ev)
if not m then return end
if dir_reply(m,status)then return end
if m.correlationId==n.search_req then
if status=="ok"then collect_network(m)end
return
end
if m.correlationId~=n.replace_req then return end
local p=m.payload
if p.status~="ok"then
n.fetch_state={kind="halt",text="Abgelehnt: "..tostring(p.grund)}
return
end

local text=p.config
local fetch=n.fetch
if type(p.parts)=="number"and p.parts>1 then
if not fetch or p.part~=fetch.part then
n.fetch_state={kind="halt",text="Unerwartete Antwort der Leitstelle."}
return
end
local assembled,why=n.fetch_chunks.add("holen",p.revision,p.part,p.parts,p.config,p.sum)
if not assembled then
if why~="offen"then
n.fetch_state={kind="halt",text="Teile unvollstaendig: "..tostring(why)}
return
end
fetch_request(fetch.central,fetch.node,p.part+1)
n.fetch_state={kind="wait",text="Empfange Konfiguration: Teil "..p.part.." von "..p.parts.." ..."}
return
end
text=assembled
end
local config=type(text)=="string"and ser.decode(text)or nil
if type(config)~="table"or not config.node then
n.fetch_state={kind="halt",text="Die Konfiguration ist nicht lesbar."}
return
end
config.status="offen"
n.fetch_state={kind="ok",text="Konfiguration von "..tostring(config.node.id).." (Stand "..tostring(config.revision)..") empfangen.",config=config}
end


local attached={}
function n.attach_roles()
for _,entry in ipairs(attached)do
for _,list in ipairs({"on_event","on_message","tick"})do
for i=#n.hooks[list],1,-1 do
if n.hooks[list][i]==entry[list]then table.remove(n.hooks[list],i)end
end
end
for _,page in ipairs(entry.page_list)do
for i=#n.hooks.pages,1,-1 do
if n.hooks.pages[i]==page then table.remove(n.hooks.pages,i)end
end
end
end
attached={}
n.roles={}
if not n.config or n.config.status~="aktiv"or not n.net then return end
if n.format_blocked then
if n.format_status=="fehlgeschlagen"then
n.notify("fehler","Die Anpassung der Daten ist gescheitert, nichts wurde veraendert und die Automatik startet nicht: "..tostring(n.format_error))
else
n.notify("fehler","Die Daten stammen von einem neueren Programm (Format "..tostring(n.format_old).."). Die Automatik startet nicht. Mit 'crn/app/main daten-zurueck N' wird eine Sicherung zurueckgespielt.")
end
return
end
local modules={}
for _,role in ipairs(n.config.node.roles)do
if role=="passagierbahnhof"or role=="gueterbahnhof"or role=="depot"then modules.station="roles.station"
elseif role=="zentrale"then modules.zentrale="roles.zentrale"
elseif role=="anmeldung"then modules.anmeldung="roles.anmeldung"
end
end
local names={}
for _,name in ipairs({"station","zentrale","anmeldung"})do
if modules[name]then names[#names+1]=name end
end
for _,name in ipairs(names)do
local ok,obj=pcall(function()
return require(modules[name]).new(n)
end)
if not ok then
n.notify("fehler","Rolle "..name.." konnte nicht starten: "..tostring(obj))
else
n.roles[name]=obj
local entry={on_event=obj.on_event,on_message=obj.on_message,tick=obj.tick,page_list={}}
if obj.on_event then n.hooks.on_event[#n.hooks.on_event+1]=obj.on_event end
if obj.on_message then n.hooks.on_message[#n.hooks.on_message+1]=obj.on_message end
if obj.tick then n.hooks.tick[#n.hooks.tick+1]=obj.tick end
for _,p in ipairs(obj.pages or{})do entry.page_list[#entry.page_list+1]=p end
if obj.page then entry.page_list[#entry.page_list+1]=obj.page end
for _,p in ipairs(entry.page_list)do n.hooks.pages[#n.hooks.pages+1]=p end
attached[#attached+1]=entry
end
end
n.rebuild_views()
end


if env.fs.exists("/crn/install.lua")then
n.updater=require("core.updater").new({
fs=env.fs,store=store,http=env.http,now=n.clock.now,node_id=n.config and n.config.node.id or"?",
notify=n.notify,
healthy=function()return not n.format_blocked end,
blockers=function()
for _,role in pairs(n.roles or{})do
local reason=role.update_blocker and role.update_blocker()
if reason then return reason end
end
return nil
end,
reboot=function()
n.clock.save()
if env.reboot then env.reboot()else n.running=false end
end,
})
if n.format_status=="migriert"then n.updater.note_migration(n.format_dir)end
n.ticker.every("update",1,function()n.updater.tick()end)
end

n.ticker.every("uhr",30,function()n.clock.save()end)
n.ticker.every("anzeige",1,function()n.dirty=true end)
n.ticker.every("takt",1,function()n.tick()end)

function n.shutdown()
n.clock.save()
n.running=false
end

function n.run()
n.running=true
n.render()
local timer=env.start_timer(1)
local ok,err=pcall(function()
while n.running do
local ev=env.pull_event()
if ev[1]=="timer"then
timer=env.start_timer(1)
end

local handled,problem=pcall(n.handle,ev)
if not handled then
local text="Ereignis "..tostring(ev[1])..": "..tostring(problem)
local at=n.clock.now()
if n.last_problem~=text or at-(n.last_problem_at or-999)>=60 then
n.last_problem,n.last_problem_at=text,at
n.notify("fehler",text)
end
end
if n.dirty then n.render()end
end
end)
n.shutdown()
if not ok and tostring(err)~="Terminated"then error(err,0)end
end

n.rebuild_views()
n.start_services()
if n.env_hold then n.notify("warnung","Die Umgebung (Modpack/Schnittstellen) hat sich geaendert: neue Abfahrten bleiben aus, bis die Pruefung auf der Seite Uebersicht bestanden ist.")end
return n
end

return M
