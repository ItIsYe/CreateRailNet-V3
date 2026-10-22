






















local json=require("src.shared.json")
local checksum=require("src.shared.checksum")
local safe_write=require("src.shared.safe_write")

local journal={}

local HEADER="#CRNJ1"
local SNAPSHOT_VERSION=1

local function crc_of(text)return checksum.hex(checksum.adler32(text))end

local function split_lines(text)
local lines,position={},1
while position<=#text do
local newline=text:find("\n",position,true)
if newline then
lines[#lines+1]={text=text:sub(position,newline - 1),complete=true}
position=newline+1
else
lines[#lines+1]={text=text:sub(position),complete=false}
position=#text+1
end
end
return lines
end

local function parse_header(line)
local base,crc=line:match("^" .. HEADER .. "\t(%d+)\t(%x%x%x%x%x%x%x%x)$")
if not base then return nil end
if crc_of(HEADER .. "\t" .. base)~=crc then return nil end
return tonumber(base)
end

local function parse_entry(line)
local seq,kind,body,crc=line:match("^(%d+)\t([%w_%.%-]+)\t(.*)\t(%x%x%x%x%x%x%x%x)$")
if not seq then return nil end
if crc_of(seq .. "\t" .. kind .. "\t" .. body)~=crc then return nil end
local ok,data=pcall(json.decode,body)
if not ok or type(data)~="table" then return nil end
return{seq=tonumber(seq),kind=kind,data=data}
end

local function encode_entry(seq,kind,data)
local ok,body=pcall(json.encode,data or{})
if not ok then return nil,"entry cannot be written: " .. tostring(body)end
if body:find("[\t\r\n]")then return nil,"entry contains a control character" end
if type(kind)~="string" or not kind:match("^[%w_%.%-]+$")then return nil,"bad entry kind" end
local head=seq .. "\t" .. kind .. "\t" .. body
return head .. "\t" .. crc_of(head).. "\n"
end

local function header_line(base)
local head=HEADER .. "\t" .. base
return head .. "\t" .. crc_of(head).. "\n"
end

function journal.new(path,opts)
opts=opts or{}
local fsys=opts.fs or _G.fs
local max_entries=opts.max_entries or 2000
local max_bytes=opts.max_bytes or 65536
local hard_stop=max_bytes*(opts.hard_factor or 2)
local max_snapshot=opts.max_snapshot_bytes
local now=opts.now or function()return os.time and os.time()or 0 end
local snap_path=path .. ".snap"
local io_opts={fs=opts.fs}

local self={}
local entries={}
local base,snapshot_seq,snapshot_state=0,0,nil
local last,committed=0,0
local bytes=0
local state,locked,failed,last_error="closed",false,false,nil
local full=false

local function fail(err)
failed=true
last_error=tostring(err)
return nil,last_error
end

local function read_snapshot()
local body,source=safe_write.read_with_backup(snap_path,io_opts)
if not body then return nil,nil end
local ok,decoded=pcall(json.decode,body)
if ok and type(decoded)=="table" and decoded.v==SNAPSHOT_VERSION and type(decoded.seq)=="number" then return decoded,source end

local prev=safe_write.read(safe_write.backup_path(snap_path),io_opts)
if prev then
ok,decoded=pcall(json.decode,prev)
if ok and type(decoded)=="table" and decoded.v==SNAPSHOT_VERSION and type(decoded.seq)=="number" then return decoded,"backup" end
end
return nil,"damaged"
end

local function rewrite_journal(base_seq,kept)
local parts={header_line(base_seq)}
for _,entry in ipairs(kept)do
local line=encode_entry(entry.seq,entry.kind,entry.data)
parts[#parts+1]=line
end
local text=table.concat(parts)
local ok,err=safe_write.write(path,text,{fs=opts.fs,keep_backup=false})
if not ok then return nil,err end
return#text
end

function self.open()
entries,base,snapshot_seq,snapshot_state,last,committed,bytes={},0,0,nil,0,0,0
locked,failed,last_error,full=false,false,nil,false
local info={}

local snap,snap_source=read_snapshot()
if snap_source=="damaged" then
locked,state=true,"corrupt"
info.reason="snapshot unreadable"
return state,info
end
if snap then
snapshot_seq,snapshot_state,committed=snap.seq,snap.state,tonumber(snap.committed)or snap.seq
last=snap.seq
info.snapshot_from=snap_source
end

local text=safe_write.read(path,io_opts)
if not text then

base=snapshot_seq
local size,err=rewrite_journal(base,{})
if not size then fail(err);state="failed";info.reason=last_error;return state,info end
bytes=size
state=snap and "ok" or "fresh"
return state,info
end

local lines=split_lines(text)
local file_base=lines[1] and lines[1].complete and parse_header(lines[1].text)
if not file_base then
locked,state=true,"corrupt"
info.reason="journal header unreadable"
return state,info
end
base=file_base
if snapshot_seq>0 and base>snapshot_seq then

locked,state=true,"corrupt"
info.reason="journal starts after the snapshot"
return state,info
end

local expected=base+1
local kept,good_lines={},1
local damaged_at=nil
for index=2,#lines do
local line=lines[index]
local entry=line.complete and parse_entry(line.text)or nil
if entry and entry.seq==expected then
expected=expected+1
good_lines=index
if entry.seq>snapshot_seq then kept[#kept+1]=entry end
if entry.kind=="commit" and type(entry.data.upto)=="number" and entry.data.upto>committed then committed=entry.data.upto end
else
damaged_at=index
break
end
end

if damaged_at then
if damaged_at~=#lines then
locked,state=true,"corrupt"
info.reason="damaged line " .. damaged_at .. " of " ..#lines .. " is followed by more"
return state,info
end
state="tail_repaired"
info.cut=lines[damaged_at].text:sub(1,40)
else
state="ok"
end

last=math.max(snapshot_seq,expected - 1)
entries=kept
local needs_rewrite=damaged_at~=nil or base<snapshot_seq
if needs_rewrite then

local size,err=rewrite_journal(math.max(base,snapshot_seq),kept)
if not size then fail(err);state="failed";info.reason=last_error;return state,info end
base=math.max(base,snapshot_seq)
bytes=size
if state=="ok" then info.finished_compaction=true end
else
bytes=#text
end
return state,info
end

function self.reopen()return self.open()end

local function write_line(line)
if locked then return nil,"journal is locked (" .. state .. ")" end
if failed then return nil,"journal is failed: " .. tostring(last_error)end
if bytes+#line>hard_stop then full=true;return nil,"journal is full" end
local ok,handle=pcall(fsys.open,path,"a")
if not ok or not handle then return fail(ok and "cannot open journal" or handle)end
local wrote,err=pcall(function()handle.write(line);handle.close()end)
if not wrote then return fail(err)end
bytes=bytes+#line
return true
end

local function maybe_compact()
if not opts.state_fn then return end
if#entries<max_entries and bytes<max_bytes then return end
local ok,current=pcall(opts.state_fn)
if ok and type(current)=="table" then self.snapshot(current)end
end

function self.append(kind,data)
local seq=last+1
local line,err=encode_entry(seq,kind,data)
if not line then return nil,err end
local ok,werr=write_line(line)
if not ok then return nil,werr end
last=seq
entries[#entries+1]={seq=seq,kind=kind,data=data or{}}
maybe_compact()
return seq
end

function self.commit(seq)
if type(seq)~="number" or seq>last then return nil,"cannot commit what was never appended" end
if seq<=committed then return true end
local marker,err=self.append("commit",{upto=seq})
if not marker then return nil,err end
committed=seq
return true
end

function self.snapshot(new_state)
if locked then return nil,"journal is locked (" .. state .. ")" end
local body=json.encode({v=SNAPSHOT_VERSION,seq=last,committed=committed,saved_at=now(),state=new_state})
if max_snapshot and#body>max_snapshot then return nil,"snapshot too large: " ..#body .. " bytes (limit " .. max_snapshot .. ")" end
local ok,err=safe_write.write(snap_path,body,io_opts)
if not ok then return fail(err)end
local size,rerr=rewrite_journal(last,{})
if not size then return fail(rerr)end
snapshot_seq,snapshot_state,base,bytes,entries=last,new_state,last,size,{}
failed,full=false,false
return true
end


function self.install_snapshot(seq,new_state,new_committed)
if locked then return nil,"journal is locked (" .. state .. ")" end
if type(seq)~="number" or seq<0 then return nil,"bad sequence number" end
local body=json.encode({v=SNAPSHOT_VERSION,seq=seq,committed=new_committed or seq,saved_at=now(),state=new_state})
if max_snapshot and#body>max_snapshot then return nil,"snapshot too large: " ..#body .. " bytes (limit " .. max_snapshot .. ")" end
local ok,err=safe_write.write(snap_path,body,io_opts)
if not ok then return fail(err)end
local size,rerr=rewrite_journal(seq,{})
if not size then return fail(rerr)end
snapshot_seq,snapshot_state,base,last,committed,bytes,entries=seq,new_state,seq,seq,new_committed or seq,size,{}
failed,full=false,false
return true
end


function self.truncate_to(seq)
if locked then return nil,"journal is locked (" .. state .. ")" end
if type(seq)~="number" or seq>last or seq<committed or seq<snapshot_seq then return nil,"cannot cut below the committed entries" end
if seq==last then return true end
local kept={}
for _,entry in ipairs(entries)do if entry.seq<=seq then kept[#kept+1]=entry end end
local size,err=rewrite_journal(base,kept)
if not size then return fail(err)end
entries,last,bytes=kept,seq,size

if committed>0 then
local marked,merr=self.append("commit",{upto=committed})
if not marked then return nil,merr end
end
return true
end

function self.committed()return committed end
function self.last_seq()return last end
function self.base_seq()return base end
function self.snapshot_seq()return snapshot_seq end

function self.recovered()
local copy={}
for i,entry in ipairs(entries)do copy[i]=entry end
return{state=snapshot_state,snapshot_seq=snapshot_seq,entries=copy,committed=committed}
end

function self.entries_after(seq)
local out={}
for _,entry in ipairs(entries)do if entry.seq>seq then out[#out+1]=entry end end
return out
end

function self.status()
return{state=state,locked=locked,failed=failed,entries=#entries,bytes=bytes,last_seq=last,committed=committed,last_error=last_error,
writable=not locked and not failed and not full}
end

return self
end

return journal
