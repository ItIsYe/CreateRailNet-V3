





local migrations=require("core.migrations")

local M={}

M.FORMAT=migrations.FORMAT
local DATA="/crn_data"
local FILE=DATA.."/format.lua"
local MARK=DATA.."/migration.lua"
local DONE="fertig.lua"
local MAX_FILE,MAX_TOTAL,MARGIN=60000,150000,5000

local function skipped_name(name)
local base=name:match("([^/]+)$")or name
if name=="journal.log"or name=="format.lua"or name=="migration.lua"then return true end
if base:match("%.tmp$")or base:match("%.prev$")then return true end
return false
end


local function list_files(fs,rel,out)
out=out or{}
local dir=rel and(DATA.."/"..rel)or DATA
if not fs.exists(dir)then return out end
for _,entry in ipairs(fs.list(dir))do
local name=rel and(rel.."/"..entry)or entry
local path=DATA.."/"..name
if fs.isDir(path)then
if not entry:match("^sicherung_f%d+$")then list_files(fs,name,out)end
elseif not skipped_name(name)then
out[#out+1]={name=name,size=fs.getSize(path)}
end
end
return out
end

local function read_all(fs,path)
local fh=fs.open(path,"rb")
if not fh then return nil end
local text=fh.readAll()
fh.close()
return text
end

local function ensure_dir(fs,path)
local dir=fs.getDir(path)
if dir~=""and dir~=".."and not fs.exists(dir)then
ensure_dir(fs,dir)
fs.makeDir(dir)
end
end

local function copy(fs,from,to)
local text=read_all(fs,from)
if not text then return false end
ensure_dir(fs,to)
local dst=fs.open(to,"wb")
if not dst then return false end
dst.write(text)
dst.close()
return true
end

local function backup_dir(format)return DATA.."/sicherung_f"..tostring(format)end

local function complete(fs,dir)return fs.exists(dir.."/"..DONE)end

function M.backups(fs)
local out={}
if not fs.exists(DATA)then return out end
for _,name in ipairs(fs.list(DATA))do
local n=name:match("^sicherung_f(%d+)$")
if n and complete(fs,DATA.."/"..name)then out[#out+1]={format=tonumber(n),dir=DATA.."/"..name}end
end
table.sort(out,function(a,b)return a.format<b.format end)
return out
end


local function copy_back(fs,dir,rel)
local here=rel and(dir.."/"..rel)or dir
for _,entry in ipairs(fs.list(here))do
local name=rel and(rel.."/"..entry)or entry
if fs.isDir(dir.."/"..name)then
local ok,why=copy_back(fs,dir,name)
if not ok then return false,why end
elseif name~=DONE then
if not copy(fs,dir.."/"..name,DATA.."/"..name)then return false,name end
end
end
return true
end


local function roll_back(fs,dir,known)
local ok,why=copy_back(fs,dir)
if not ok then return false,"Zurueckspielen von "..tostring(why).." fehlgeschlagen."end
if known then
local keep={}
for _,name in ipairs(known)do keep[name]=true end
for _,file in ipairs(list_files(fs))do
if not keep[file.name]then fs.delete(DATA.."/"..file.name)end
end
end
return true
end

local function make_context(fs,store)
local ctx={fs=fs,store=store,dir=DATA}
function ctx.files()
local names={}
for _,f in ipairs(list_files(fs))do names[#names+1]=f.name end
return names
end
function ctx.exists(name)return fs.exists(DATA.."/"..name)end

function ctx.delete(name)
for _,suffix in ipairs({"",".tmp",".prev"})do
local path=DATA.."/"..name..suffix
if fs.exists(path)then fs.delete(path)end
end
return true
end
function ctx.load(name)return(store.load(DATA.."/"..name))end
function ctx.save(name,value)
local ok,why=store.save(DATA.."/"..name,value)
if not ok then error("Speichern von "..name.." fehlgeschlagen: "..tostring(why),0)end
return true
end

function ctx.update(name,fn)
local value=store.load(DATA.."/"..name)
if value==nil then return false end
local result=fn(value)
if result==nil then result=value end
return ctx.save(name,result)
end
return ctx
end

local function step_parts(step,from)
if type(step)=="function"then return step,"Schritt "..from end
return step.run,step.text or("Schritt "..from)
end

function M.check(fs,store,opts)
opts=opts or{}
local format=opts.format or M.FORMAT
local steps=opts.migrations
if steps==nil and opts.format==nil then steps=migrations.STEPS end
steps=steps or{}
local saved=store.load(FILE)
if not saved or type(saved.format)~="number"then
store.save(FILE,{format=format,program=opts.program})
return"neu",nil,nil
end
if saved.format==format then

if fs.exists(MARK)then fs.delete(MARK)end
if saved.program~=opts.program then store.save(FILE,{format=format,program=opts.program})end
return"gleich",saved.format,nil
end
if saved.format>format then return"zu_neu",saved.format,nil end


local from_format=saved.format
local dir=backup_dir(from_format)
if fs.exists(MARK)then
local mark=store.load(MARK)
if mark and mark.from==from_format and complete(fs,dir)then
local ok,why=roll_back(fs,dir,mark.names)
if not ok then return"fehlgeschlagen",from_format,dir,why end
end
fs.delete(MARK)
end

local function fail(text)
return"fehlgeschlagen",from_format,dir,text
end


local has_steps=false
for from=from_format,format-1 do if steps[from]then has_steps=true end end



local scope=nil
if has_steps then
scope={}
for from=from_format,format-1 do
local step=steps[from]
if step then
local list=type(step)=="table"and step.scope or nil
if type(list)~="table"then scope=nil break end
for _,name in ipairs(list)do scope[name]=true end
end
end
end


local files=list_files(fs)
local total,had_header,saved_files=0,{},{}
for _,f in ipairs(files)do
if not scope or scope[f.name]then saved_files[#saved_files+1]=f end
end
for _,f in ipairs(saved_files)do
if f.size>MAX_FILE then return fail("Die Datei "..f.name.." ist zu gross fuer die Sicherung vor der Anpassung der Daten ("..f.size.." Byte).")end
total=total+f.size
end
if total>MAX_TOTAL then return fail("Die Daten sind zu gross fuer die Sicherung vor der Anpassung ("..total.." Byte, hoechstens "..MAX_TOTAL..").")end
local need=0
for _,f in ipairs(saved_files)do need=need+math.max(f.size,500)end
if fs.getFreeSpace("/")<need+MARGIN then
return fail("Zu wenig Platz fuer die Sicherung vor der Anpassung der Daten: "..(need+MARGIN).." Byte noetig, frei "..fs.getFreeSpace("/")..".")
end
if fs.exists(dir)then fs.delete(dir)end
fs.makeDir(dir)
local names={}
for _,f in ipairs(files)do
names[#names+1]=f.name
local head=read_all(fs,DATA.."/"..f.name)
had_header[f.name]=head~=nil and head:sub(1,7)=="-- crn "
if(not scope or scope[f.name])and not copy(fs,DATA.."/"..f.name,dir.."/"..f.name)then
fs.delete(dir)
return fail("Sicherung von "..f.name.." fehlgeschlagen.")
end
end
local done=fs.open(dir.."/"..DONE,"wb")
if not done then fs.delete(dir);return fail("Sicherung konnte nicht abgeschlossen werden.")end
done.write("ok\n")
done.close()


local marked=store.save(MARK,{from=from_format,to=format,names=names})
if not marked then return fail("Der Merker der Anpassung konnte nicht geschrieben werden.")end
local ctx=make_context(fs,store)
local function undo(reason)
local ok,why=roll_back(fs,dir,names)
if not ok then return fail(reason.." "..why)end
fs.delete(MARK)
return fail(reason)
end
for from=from_format,format-1 do
local step=steps[from]
if step then
local run,text=step_parts(step,from)
local ok,result,why=pcall(run,ctx)
if not ok then
return undo("Format "..from.." auf "..(from+1).." ("..text.."): "..tostring(result))
end
if result==false then
return undo("Format "..from.." auf "..(from+1).." ("..text..") abgelehnt: "..tostring(why or"ohne Grund"))
end
end
end

if has_steps then
for _,f in ipairs(list_files(fs))do
if f.name:match("%.lua$")then
local head=read_all(fs,DATA.."/"..f.name)
local has=head~=nil and head:sub(1,7)=="-- crn "
if has or had_header[f.name]then
local value,source=store.load(DATA.."/"..f.name)
if value==nil or source~="main"then
return undo("Anpassung der Daten gescheitert: die Datei "..f.name.." ist danach nicht lesbar.")
end
end
end
end
end
local saved_ok=store.save(FILE,{format=format,program=opts.program})
if not saved_ok then return undo("Anpassung der Daten gescheitert: der neue Stand konnte nicht eingetragen werden.")end
fs.delete(MARK)
return"migriert",from_format,dir
end


function M.restore(fs,store,format)
local dir=backup_dir(format)
if not fs.exists(dir)or not complete(fs,dir)then return nil,"Keine Sicherung fuer Datenformat "..tostring(format).." vorhanden."end
local ok,why=copy_back(fs,dir)
if not ok then return nil,"Zurueckspielen von "..tostring(why).." fehlgeschlagen."end
if fs.exists(MARK)then fs.delete(MARK)end
store.save(FILE,{format=format})
return true
end

return M
