





local version=require("core.version")

local M={}

local ROOT,DATA="/crn","/crn_data"
local PROBE,BAD,STATE,PREV=DATA.."/probe",DATA.."/update_bad",DATA.."/update.lua","/crn_prev"
local CHECK_EVERY,QUIET,CONFIRM,FIRST_MIN,SPREAD,SICK_AFTER,RETRY=1800,300,120,60,540,5,600
local MODES={auto=true,melden=true,aus=true}

local function read(fs,path)
if not fs.exists(path)then return nil end
local fh=fs.open(path,"rb")
if not fh then return nil end
local text=fh.readAll()
fh.close()
return text
end

local function write(fs,path,text)
local fh=fs.open(path,"wb")
if not fh then return false end
fh.write(text)
fh.close()
return true
end

local function parse(text)
if type(text)~="string"then return nil end
local chunk
if setfenv then
chunk=loadstring(text,"=daten")
if chunk then setfenv(chunk,{})end
else
chunk=load(text,"=daten","t",{})
end
if not chunk then return nil end
local ok,value=pcall(chunk)
if ok and type(value)=="table"then return value end
return nil
end


local function moving(ref)return not ref:match("^v?%d+%.%d+")and not ref:match("^%x%x%x%x%x%x%x+$")end

local function spread(id)
local h=5381
for i=1,#tostring(id)do h=(h*33+tostring(id):byte(i))%65536 end
return math.floor((h*40503%65536)*(SPREAD+1)/65536)
end

function M.new(spec)
local u={}
local fs,store,http,now=spec.fs,spec.store,spec.http,spec.now
local info=parse(read(fs,ROOT.."/install.lua"))or{}
local base=info.base or version.source
local state=store.load(STATE)or{}
if not MODES[state.mode]then state.mode="auto"end
local boot_at=now()
local run={next_check=boot_at+FIRST_MIN+spread(spec.node_id or"?")}

local function save()store.save(STATE,{mode=state.mode,replace=state.replace or nil,skipped=state.skipped})end
local function notify(level,text)if spec.notify then spec.notify(level,text)end end
local function get(url)
if not http then return nil end
local ok,handle=pcall(http.get,url,nil,true)
if not ok or not handle then return nil end
local text=handle.readAll()
handle.close()
return text
end
local function fail(text)
run.note=text
return"fehler",text
end


local probe_text=read(fs,PROBE)
if probe_text then run.probe=tonumber(probe_text:match("^(%d+)"))or 0 end
local bad=read(fs,BAD)
if bad then
state.skipped=bad:match("%S+")
fs.delete(BAD)
save()
notify("fehler","Der Stand "..tostring(state.skipped).." ist nach dem Update nicht angelaufen und wurde zurueckgenommen. Er wird nicht noch einmal versucht, bis ein neuerer erscheint.")
end

function u.state()
return{
mode=state.mode,replace=state.replace==true,skipped=state.skipped,ref=info.ref,role=info.role,id=info.id,version=info.version,
available=run.available,checked=run.checked,next_check=run.next_check,note=run.note,probe=run.probe,restarting=run.restarting==true,
moving=info.ref~=nil and moving(info.ref),
}
end

function u.set_mode(mode)
if not MODES[mode]then return nil end
state.mode=mode
save()
return mode
end

function u.set_replace(on)
state.replace=on==true
save()
end

function u.check()
if not http then
run.note="HTTP ist auf diesem Computer nicht erlaubt: keine Aktualisierung."
return"kein_http",run.note
end
if not info.ref or not info.role then return fail("Keine Installation gefunden (/crn/install.lua).")end
if not moving(info.ref)then return"fest","Feste Version "..info.ref..": wird nicht automatisch aktualisiert."end
local m=parse(get(base..info.ref.."/dist/manifest.lua"))
if not m then return fail("Der Kanal "..info.ref.." ist nicht erreichbar.")end
local files=m.roles and m.roles[info.role]
if type(m.id)~="string"or type(files)~="table"or#files==0 then return fail("Das Verzeichnis des Kanals "..info.ref.." ist unbrauchbar.")end
run.checked,run.note=now(),nil
if m.id==info.id then
run.available=nil
return"aktuell","Aktuell: Version "..tostring(info.version).."."
end
run.available={id=m.id,version=m.version}
return"verfuegbar","Neu: Version "..tostring(m.version).." (Stand "..m.id..")."
end


local function engine()
local text=get(base..info.ref.."/installer.lua")
if not text or#text<5000 or#text>300000 then return nil,"Der Installer des Kanals ist nicht erreichbar oder unbrauchbar."end
local env=setmetatable({__CRN_ENGINE=true},{__index=_G})
env._G=env
local chunk
if setfenv then
chunk=loadstring(text,"=installer")
if chunk then setfenv(chunk,env)end
else
chunk=load(text,"=installer","t",env)
end
if not chunk then return nil,"Der Installer des Kanals ist kein gueltiges Lua."end
local ok,eng=pcall(chunk)
if not ok or type(eng)~="table"or not(eng.get_manifest and eng.plan and eng.apply and eng.recover and eng.make_room)then
return nil,"Der Installer des Kanals hat nicht die erwartete Form."
end
return eng
end

function u.install(opts)
opts=opts or{}
if run.restarting then return false,"Der Computer startet gleich neu."end
if run.probe and not opts.force then return false,"Das letzte Update ist noch in der Probezeit."end
if not run.available then
local status=u.check()
if status~="verfuegbar"then return false,run.note or"Es gibt nichts zu installieren."end
end
local target=run.available
local log={}
local env={fs=fs,http=http,print=function(line)log[#log+1]=tostring(line)end,read=function()return""end}
local function failed(text)
run.retry_at=now()+RETRY
return false,select(2,fail(text))
end
local eng,why=engine()
if not eng then return failed(why)end
eng.recover(env)
local source,err=eng.get_manifest(env,info.ref)
if not source then return failed(err)end
local plan,perr=eng.plan(env,source,info.role)
if not plan then return failed(perr)end
if plan.short and fs.exists(PREV)then
fs.delete(PREV)
plan=eng.plan(env,source,info.role)
end
if plan.short then
if plan.can_replace and state.replace then
eng.make_room(env,plan)
elseif plan.can_replace then
return failed("Alt und neu passen nicht zugleich auf den Computer. Von Hand: installer "..info.role.." --replace (kein Zurueck zur Vorversion), oder fuer die Selbstaktualisierung erlauben: crn/app/main update ersetzen ein.")
else
return failed("Zu wenig Platz auf dem Computer fuer die neue Version.")
end
end
if not eng.apply(env,plan)then
return failed((log[#log-1]or"").." "..(log[#log]or""))
end
info=parse(read(fs,ROOT.."/install.lua"))or info

if fs.exists(PREV)then write(fs,PROBE,"0\nbad="..tostring(target.id).."\n")end
run.restarting,run.available,run.note=true,nil,nil
notify("info","Neue Version "..tostring(target.version).." installiert, der Computer startet neu.")
if spec.reboot then spec.reboot()end
return true,"Installiert: Version "..tostring(target.version).."."
end


function u.note_migration(dir)
local text=read(fs,PROBE)
if text and not text:find("restore=",1,true)and type(dir)=="string"then
write(fs,PROBE,text.."restore="..(dir:match("([^/]+)$")or dir).."\n")
end
end

local function tick_probe(t)
local uptime=t-boot_at
if not spec.healthy()then
if uptime>=SICK_AFTER and not run.restarting then
run.restarting=true
write(fs,PROBE,"2"..(read(fs,PROBE)or""):gsub("^%d+",""))
notify("fehler","Das neue Programm laeuft mit den Daten dieses Computers nicht an: Rueckkehr zur Vorversion.")
if spec.reboot then spec.reboot()end
end
return
end
if uptime>=CONFIRM then
fs.delete(PROBE)
run.probe=nil
notify("info","Update auf Version "..tostring(info.version).." bestaetigt.")
end
end

function u.tick()
local t=now()
if run.probe then return tick_probe(t)end
if state.mode=="aus"then return end
if t>=run.next_check then
run.next_check=t+CHECK_EVERY
u.check()
local found=run.available
if found and state.mode=="melden"and run.announced~=found.id then
run.announced=found.id
notify("info","Neue Version "..tostring(found.version).." ist verfuegbar (Betriebsart: nur melden).")
end
end
local found=run.available
if state.mode~="auto"or not found or found.id==state.skipped then return end
if t<(run.retry_at or 0)then return end
local reason
if t-boot_at<QUIET then reason="kurz nach dem Start"
elseif not spec.healthy()then reason="Daten und Programm passen nicht zusammen"
else reason=spec.blockers and spec.blockers()end
if reason then
run.note="Neue Version "..tostring(found.version).." wartet: "..reason
return
end
u.install({})
end

return u
end

return M
