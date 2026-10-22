















local ota_recovery={}

local JOURNAL="ota_journal.txt"
local STAGE_LIST="ota_stage.txt"
local MAGIC="OTAJ1"

ota_recovery.JOURNAL=JOURNAL
ota_recovery.STAGE_LIST=STAGE_LIST
ota_recovery.NEW_SUFFIX=".ota_new"
ota_recovery.BACKUP_SUFFIX=".ota_bak"

local function fsys_or_default(fsys)return fsys or _G.fs end

local function read(fsys,path)
if not fsys.exists(path)then return nil end
local fh=fsys.open(path,"r")
if not fh then return nil end
local body=fh.readAll()
fh.close()
return body
end

local function write(fsys,path,body)
local fh=fsys.open(path,"w")
if not fh then return false end
fh.write(body)
fh.close()
return read(fsys,path)==body
end

local function remove(fsys,path)
if fsys.exists(path)then fsys.delete(path)end
end


local function adler32(text)
local a,b=1,0
local length,position=#text,1
while position<=length do
local last=math.min(position+4095,length)
local bytes={string.byte(text,position,last)}
for i=1,#bytes do a=a+bytes[i];b=b+a end
a,b=a%65521,b%65521
position=last+1
end
return b*65536+a
end

local function encode(journal)
local lines={MAGIC,"state=" .. tostring(journal.state),"boots=" .. tostring(journal.boots or 0),"version=" .. tostring(journal.version or "")}
for _,entry in ipairs(journal.files or{})do
lines[#lines+1]=string.format("file=%s\t%d\t%d\t%d",entry.path,entry.had_old and 1 or 0,entry.old_size or 0,entry.old_adler or 0)
end
lines[#lines+1]="END"
return table.concat(lines,"\n").. "\n"
end

local function decode(body)
if type(body)~="string" or body:sub(1,#MAGIC+1)~=MAGIC .. "\n" or body:sub(-4)~="END\n" then return nil end
local journal={files={}}
for line in body:gmatch("[^\n]+")do
local key,value=line:match("^(%a+)=(.*)$")
if key=="state" then journal.state=value
elseif key=="boots" then journal.boots=tonumber(value)or 0
elseif key=="version" then journal.version=value
elseif key=="file" then
local path,had_old,old_size,old_adler=value:match("^([^\t]+)\t(%d)\t(%d+)\t(%d+)$")
if not path then return nil end
journal.files[#journal.files+1]={path=path,had_old=had_old=="1",old_size=tonumber(old_size),old_adler=tonumber(old_adler)}
end
end
if journal.state~="applying" and journal.state~="trial" then return nil end
return journal
end

function ota_recovery.write_journal(fsys,journal)
fsys=fsys_or_default(fsys)
local tmp=JOURNAL .. ".tmp"
if not write(fsys,tmp,encode(journal))then remove(fsys,tmp);return false,"journal write failed" end
remove(fsys,JOURNAL)
fsys.move(tmp,JOURNAL)
return true
end

function ota_recovery.read_journal(fsys)
fsys=fsys_or_default(fsys)

return decode(read(fsys,JOURNAL))or decode(read(fsys,JOURNAL .. ".tmp"))
end


function ota_recovery.write_stage_list(fsys,paths)
fsys=fsys_or_default(fsys)
local body=table.concat(paths,"\n").. "\nEND\n"
return write(fsys,STAGE_LIST,body)
end

local function staged_paths(fsys)
local body=read(fsys,STAGE_LIST)
local paths={}
if body and body:sub(-4)=="END\n" then
for line in body:gmatch("[^\n]+")do if line~="END" then paths[#paths+1]=line end end
end
return paths
end

function ota_recovery.clear_stage_list(fsys)
fsys=fsys_or_default(fsys)
for _,path in ipairs(staged_paths(fsys))do
remove(fsys,path .. ota_recovery.NEW_SUFFIX)
remove(fsys,path .. ota_recovery.NEW_SUFFIX .. ".tmp")
end
remove(fsys,STAGE_LIST)
end

local function drop_leftovers(fsys,journal)
for _,entry in ipairs(journal.files)do
remove(fsys,entry.path .. ota_recovery.NEW_SUFFIX)
remove(fsys,entry.path .. ota_recovery.NEW_SUFFIX .. ".tmp")
remove(fsys,entry.path .. ota_recovery.BACKUP_SUFFIX)
remove(fsys,entry.path .. ota_recovery.BACKUP_SUFFIX .. ".tmp")
end
remove(fsys,JOURNAL)
remove(fsys,JOURNAL .. ".tmp")
ota_recovery.clear_stage_list(fsys)
end

local function rollback(fsys,journal)
local problems={}
for _,entry in ipairs(journal.files)do
local live,backup=entry.path,entry.path .. ota_recovery.BACKUP_SUFFIX
if entry.had_old then
local saved=read(fsys,backup)
if saved and#saved==entry.old_size and adler32(saved)==entry.old_adler then
remove(fsys,live)
fsys.move(backup,live)
elseif not fsys.exists(live)then
problems[#problems+1]=live .. " is gone and its backup is unusable"
end

else
remove(fsys,live)
end
end
drop_leftovers(fsys,journal)
return problems
end

function ota_recovery.recover(fsys)
fsys=fsys_or_default(fsys)
local journal=ota_recovery.read_journal(fsys)
if not journal then

remove(fsys,JOURNAL .. ".tmp")
if fsys.exists(STAGE_LIST)then ota_recovery.clear_stage_list(fsys);return "cleaned" end
return "none"
end
if journal.state=="applying" or(journal.state=="trial" and(journal.boots or 0)>=1)then
local problems=rollback(fsys,journal)
if#problems>0 then return "failed",table.concat(problems,"; ")end
return "rolled_back",journal.state
end

journal.boots=(journal.boots or 0)+1
local ok=ota_recovery.write_journal(fsys,journal)
if not ok then return "failed","journal update failed" end
return "kept",journal.version
end

function ota_recovery.confirm(fsys)
fsys=fsys_or_default(fsys)
local journal=ota_recovery.read_journal(fsys)
if not journal then return false end
if journal.state~="trial" then return false end
drop_leftovers(fsys,journal)
return true
end

return ota_recovery
