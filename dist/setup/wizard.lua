





local model=require("setup.model")
local label=require("core.label")
local ser=require("core.ser")
local adler=require("core.adler")
local detect=require("dev.detect")
local stationlib=require("dev.station")

local M={}


local SELECTABLE={station=true,monitor=true,displaylink=true}

M.STEPS={"Netz","Aufgabe","Geraete","Gleise","Test","Fertig"}

function M.new(opts)
local w={step=1,mode="create",network_name="",central_id="",key="",name="",roles={},scan=opts.scan()}
local env=opts.env
local existing=opts.existing

w.was_active=existing~=nil and existing.status=="aktiv"
if not existing and opts.role_available and not opts.role_available("zentrale")then w.mode="join"end

w.config=existing and model.drop_legacy(assert(ser.decode(ser.encode(existing))))or model.new("",{},{})
w.claimed_id=(existing~=nil and existing.node.claimed==true)and existing.node.id or nil
if existing then
w.network_name=existing.network.name
w.central_id=existing.network.central_id or""
w.key=existing.network.key or""
w.name=existing.node.name
w.roles={}
for _,r in ipairs(existing.node.roles)do w.roles[#w.roles+1]=r end
w.mode=model.has_role(existing,"zentrale")and"create"or"join"
end

local function has(list,v)
for _,x in ipairs(list)do if x==v then return true end end
return false
end

local function sync_config()
local c=w.config
c.network.name=w.network_name
c.network.central_id=(w.mode=="join"and w.central_id~="")and w.central_id or nil
c.network.key=(w.key~="")and w.key or nil

c.node.name=(w.name~=""or w.claimed_id or existing)and w.name or w.suggest_name()
if not existing then c.node.id=w.claimed_id or model.slug(c.node.name)end
c.node.roles={}
for _,r in ipairs(model.ROLES)do if has(w.roles,r)then c.node.roles[#c.node.roles+1]=r end end
end

function w.rescan()
w.scan=opts.scan()
for _,d in pairs(w.config.devices)do
local found=detect.find(w.scan,d.device)
if not found or found.kind~=d.kind or#detect.missing(d.kind,found)>0 then w.config.tests={}end
end
end


function w.set_mode(mode)
w.mode=mode
if mode=="create"and#w.roles==0 and has(w.available_roles(),"zentrale")then w.roles={"zentrale"}end
sync_config()
end
function w.set_network(name,central,key)
w.network_name,w.central_id,w.key=name or w.network_name,central or w.central_id,key or w.key
sync_config()
end

local NAME_BASE={zentrale="Leitstelle",passagierbahnhof="Bahnhof",gueterbahnhof="Gueterbahnhof",depot="Depot",anmeldung="Anmeldung"}
function w.suggest_name()
w.name_number=w.name_number or math.random(100,999)
return(NAME_BASE[w.roles[1]or""]or"Node").." "..w.name_number
end
function w.set_name(name)
w.name=name:match("%S")and name or""
sync_config()
end
function w.available_roles()
local roles={}
for _,role in ipairs(model.ROLES)do if not opts.role_available or opts.role_available(role)then roles[#roles+1]=role end end
return roles
end


function w.removal_effect(role)
local effect={devices=0,tracks=0}
if not has(w.roles,role)then return effect end
local roles={}
for _,r in ipairs(w.roles)do if r~=role then roles[#roles+1]=r end end
local p=model.profile({node={roles=roles}})
for _,d in pairs(w.config.devices)do if not p.allowed[d.kind]then effect.devices=effect.devices+1 end end
if not p.tracks then for _ in pairs(w.config.tracks)do effect.tracks=effect.tracks+1 end end
return effect
end


function w.toggle_role(role,confirmed)
if not has(w.available_roles(),role)then return false end
local removed
if has(w.roles,role)then
local effect=w.removal_effect(role)
if(effect.devices>0 or effect.tracks>0)and not confirmed then return false,"bestaetigen",effect end
removed=effect
end
if has(w.roles,role)then
local kept={}
for _,r in ipairs(w.roles)do if r~=role then kept[#kept+1]=r end end
w.roles=kept
else
w.roles[#w.roles+1]=role
end
sync_config()
local p=model.profile(w.config)
local remove={}
for id,d in pairs(w.config.devices)do if not p.allowed[d.kind]then remove[#remove+1]=id end end
for _,id in ipairs(remove)do model.remove_device(w.config,id)end
if not model.has_role(w.config,"anmeldung")then w.config.registration_station=nil end
if not p.tracks then w.config.tracks={}end
w.config.tests={}
return true,nil,removed
end

local function needs(kind_role)
return model.has_role(w.config,kind_role)
end

function w.allowed_devices()return model.profile(w.config).allowed end



local function test_fingerprint(kind,ref)
local c=w.config
local function track_part(track)
local copy=assert(ser.decode(ser.encode(track)))
copy.name,copy.status=nil,nil
return copy
end
local part={}
if kind=="ausgang"then
if c.tracks[ref]then part.track=track_part(c.tracks[ref])end
else
part.device=c.devices[ref]
for _,track in pairs(c.tracks)do
if track.station==ref then part.track=track_part(track)end
end
end
local text=ser.encode(part)
return#text..":"..adler.hex(text)
end



function w.step_ok(n,cached,skip)
sync_config()
if n==1 then
if not w.network_name:match("%S")then return false,"Der Netzname fehlt."end
if w.mode=="join"and not w.central_id:match("%S")then return false,"Die Kennung der Leitstelle fehlt."end
return true
elseif n==2 then
if#w.roles==0 then return false,"Bitte mindestens eine Rolle waehlen."end
for _,role in ipairs(w.roles)do if not has(w.available_roles(),role)then return false,"Die Programmdateien fuer Rolle "..role.." fehlen."end end
if w.mode=="create"and not has(w.roles,"zentrale")then return false,"Die erste Leitstelle braucht die Rolle Leitstelle."end
if w.mode=="join"and has(w.roles,"zentrale")then
return false,"Eine zweite aktive Leitstelle ist nicht vorgesehen. Eine Ersatz-Leitstelle wird ueber 'Vorhandene Node uebernehmen' eingerichtet."
end
return true
elseif n>=3 then
if not cached then w.rescan()end
local modem=false
for _,d in ipairs(w.scan)do
if d.kind=="modem"and#detect.missing("modem",d)==0 then modem=true end
end
if not modem then return false,"Ein erreichbares Netzwerkmodem fehlt."end
local counts={}
for _,d in pairs(w.config.devices)do
local found=detect.find(w.scan,d.device)
if not w.allowed_devices()[d.kind]then return false,"Geraet "..d.device.." passt nicht zur Rolle. Bitte abwaehlen."end
if not found or found.kind~=d.kind then return false,"Geraet "..d.device.." ist nicht erreichbar oder hat die falsche Art."end
if#detect.missing(d.kind,found)>0 then return false,"Geraet "..d.device..": erforderliche Methoden fehlen."end
counts[d.kind]=(counts[d.kind]or 0)+1
end
local p=model.profile(w.config)

local present={}
for _,d in ipairs(w.scan)do if#detect.missing(d.kind,d)==0 then present[d.kind]=true end end
if(p.station or needs("anmeldung"))and not counts.station then
return false,present.station and"Mindestens eine Train Station muss ausgewaehlt werden."or"Keine Train Station am Computer gefunden: anschliessen, dann Neu lesen."
end
if n>=4 then
for _,p in ipairs(model.validate(w.config,w.scan))do
if not(skip and skip[p.code])then return false,p.text end
end
end
if n>=5 and not w.all_tests_ok()then
for _,test in ipairs(w.tests())do
local state,text=w.test_state(test.id,nil,test)
if state=="fehler"then
local line=test.title.." fehlgeschlagen: "..tostring(text or"")
if#line>90 then line=line:sub(1,87).."..."end
return false,line
elseif state~="ok"then
return false,"Pruefung noch offen: "..test.title.."."
end
end
return false,"Erforderliche Pruefungen sind noch offen oder fehlgeschlagen."
end
return true
end
return true
end

function w.warnings()
sync_config()
local out={}
for _,p in ipairs(model.validate(w.config,w.scan))do out[#out+1]=p end
return out
end

function w.next()
local ok,reason=w.step_ok(w.step)
if not ok then return false,reason end
if w.step<#M.STEPS then w.step=w.step+1 end
if w.step==3 then w.rescan()end
return true
end

function w.back()
if w.step>1 then w.step=w.step-1 end
if w.step==3 then w.rescan()end
return true
end


function w.device_selected(name)
for _,d in pairs(w.config.devices)do if d.device==name then return true end end
return false
end

function w.toggle_device(name)
local found=detect.find(w.scan,name)
if not found or not SELECTABLE[found.kind]or not w.allowed_devices()[found.kind]then return false end
for id,d in pairs(w.config.devices)do
if d.device==name then
model.remove_device(w.config,id)
return true
end
end
model.add_device(w.config,found.kind,name)
return true
end


function w.tracks()
local ids={}
for id in pairs(w.config.tracks)do ids[#ids+1]=id end
table.sort(ids)
return ids
end

function w.add_track(name)
return model.add_track(w.config,name)
end

function w.copy_track(id,name)
return model.copy_track(w.config,id,name)
end

function w.remove_track(id)
model.remove_track(w.config,id)
end

function w.rename_track(id,name)
local track=w.config.tracks[id]
if not track then return false end
track.name=name
return true
end


function w.toggle_track_station(track_id,device_id)
local track=w.config.tracks[track_id]
if not track then return false,"unbekanntes Gleis"end
if track.station==device_id then track.station=nil return true end
for id,other in pairs(w.config.tracks)do
if id~=track_id and other.station==device_id then return false,"Das Geraet gehoert schon zu "..other.name.."."end
end
track.station=device_id
return true
end

function w.set_registration(device_id)
w.config.registration_station=device_id
return true
end





function w.legacy_id()
return(existing~=nil and existing.node.claimed~=true)and existing.node.id or nil
end

function w.guided_begin(info)
local roles={}
for _,r in ipairs(info.roles or{info.role or"passagierbahnhof"})do roles[#roles+1]=r end
w.mode="join"
w.roles=roles
w.claimed_id=info.node.id
w.name=info.node.name
sync_config()
local c=w.config
c.node.claimed,c.node.label,c.node.claim=true,info.node.label,info.claim
return true
end


function w.anmeldung_begin(info)
w.mode="join"
w.roles={"anmeldung"}
w.claimed_id=info.node.id
w.name=info.node.name
sync_config()
local c=w.config
c.node.claimed,c.node.label,c.node.claim,c.node.station=true,info.node.label,info.claim,info.station.id
return true
end


local function device_name(id)return w.config.devices[id]and w.config.devices[id].device or"?"end

function w.tests()
sync_config()
local list={}
local ids={}
for id in pairs(w.config.devices)do ids[#ids+1]=id end
table.sort(ids)
for _,id in ipairs(ids)do
local d=w.config.devices[id]
if d.kind=="station"then
list[#list+1]={
id="lesen:"..id,kind="lesen",title="Lesen: "..d.device,spec=d.device,fp=test_fingerprint("geraet",id),
explain="Der Zustand von "..d.device.." wird nur gelesen.",
}
end
end
return list
end

local function find_test(id)
for _,t in ipairs(w.tests())do if t.id==id then return t end end
end

function w.test_state(id,current,test)
test=test or find_test(id)
if not test then return nil end
local result=w.config.tests[id]
if not result then return"offen"end
if result.spec~=test.spec or result.fp~=test.fp then return"offen"end
return result.ok and"ok"or"fehler",result.text
end

function w.all_tests_ok()
for _,test in ipairs(w.tests())do
if w.test_state(test.id,nil,test)~="ok"then return false end
end
return true
end

local function record(test,ok,text)
w.config.tests[test.id]={ok=ok,text=text,spec=test.spec,fp=test.fp,at=opts.now()}
return ok,text
end

function w.run_test(id)
local test=find_test(id)
if not test then return false,"unbekannte Pruefung"end
local kind,ref=id:match("^(%a+):(.+)$")
if kind=="lesen"then
local d=w.config.devices[ref]
local state=stationlib.new(env,d.device).read()
if not state.available then return record(test,false,"nicht erreichbar: "..tostring(state.errors and state.errors[1]or""))end
if state.errors and#state.errors>0 then return record(test,false,state.errors[1])end
return record(test,true,"lesbar")
end
return false,"unbekannte Pruefung"
end



function w.run_open_tests()
local result={ok=0,failed=0}
for _,test in ipairs(w.tests())do
if w.test_state(test.id,nil,test)~="ok"then
local ok=w.run_test(test.id)
result[ok and"ok"or"failed"]=result[ok and"ok"or"failed"]+1
end
end
return result
end




function w.finish(store,path)
sync_config()
w.rescan()
local problems=model.validate(w.config,w.scan)
for n=1,5 do
local ok,reason=w.step_ok(n,true)
if not ok then problems[#problems+1]={code="schritt_"..n,text=reason}end
end
if#problems>0 or not w.all_tests_ok()then
return nil,problems,"Pflichtangaben und Pruefungen sind nicht vollstaendig."
end
w.config.status="aktiv"
for _,track in pairs(w.config.tracks)do track.status="aktiv"end
w.config.revision=(w.config.revision or 0)+1
local ok,err=store.save(path,w.config)
if not ok then
w.config.status="offen"
return nil,problems,err
end
return"aktiv",problems
end


if not existing and opts.role_available and opts.role_available("zentrale")then
local other=false
for _,role in ipairs(model.ROLES)do if role~="zentrale"and opts.role_available(role)then other=true end end
if not other then w.set_mode("create")end
end
return w
end

return M
