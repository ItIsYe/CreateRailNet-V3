



















local state_delta=require("src.domain.state_delta")
local json=require("src.shared.json")
local checksum=require("src.shared.checksum")

local replica={}

local MAX_STATE_BYTES=400000
local MAX_PARTS=200
local MAX_PENDING_ASSEMBLIES=4

function replica.new(opts)
local self={}
local journal,network,ha=opts.journal,opts.network,opts.ha
local now_ms=opts.now_ms
local logger=opts.logger
local peer=opts.peer
local peer_timeout=opts.peer_timeout_ms or 6000
local resend_ms=opts.resend_ms or 1500
local part_bytes=opts.part_bytes or 2800

local state={}
local last_idx,last_term=0,0
local metas={}
local snap_idx,snap_committed_idx,snap_state=0,0,{}
local committed_idx=0
local max_entries=opts.max_entries or 300
local peer_idx,peer_seen=0,nil
local last_ping,last_send=nil,nil
local assemblies,assembly_order={},{}
local sync_sent_at=nil
local last_catchup=nil
local catchup_gap_ms=opts.catchup_gap_ms or 1000
local counter=0

local function log(level,text,data)if logger and logger[level] then logger[level](text,data)end end


local function build(upto_idx)
local out=state_delta.copy(snap_state)
for _,entry in ipairs(journal.recovered().entries)do
if entry.kind=="state" and entry.data.idx and entry.data.idx<=upto_idx then out=state_delta.apply(out,entry.data.delta)end
end
return out
end

local function committed_idx_now()return committed_idx end

local function wrapper()return{s=state,idx=last_idx,term=last_term,committed_idx=committed_idx}end


local function load()
local recovered=journal.recovered()
local wrapped=recovered.state
state,last_idx,last_term,snap_idx,snap_committed_idx={},0,0,0,0
if type(wrapped)=="table" and type(wrapped.s)=="table" then
state=state_delta.copy(wrapped.s)
last_idx,last_term,snap_idx=tonumber(wrapped.idx)or 0,tonumber(wrapped.term)or 0,tonumber(wrapped.idx)or 0
snap_committed_idx=tonumber(wrapped.committed_idx)or 0
end
snap_state=state_delta.copy(state)
metas={}
committed_idx=snap_committed_idx
for _,entry in ipairs(recovered.entries)do
if entry.kind=="state" and type(entry.data.idx)=="number" and type(entry.data.delta)=="table" then
state=state_delta.apply(state,entry.data.delta)
last_idx,last_term=entry.data.idx,entry.data.term or last_term
metas[#metas+1]={idx=entry.data.idx,seq=entry.seq,term=entry.data.term or 0}
elseif entry.kind=="rcommit" and type(entry.data.idx)=="number" and entry.data.idx>committed_idx then
committed_idx=entry.data.idx
end
end
if committed_idx>last_idx then committed_idx=last_idx end
end
load()

local function term_of(idx)
if idx==last_idx then return last_term end
for _,meta in ipairs(metas)do if meta.idx==idx then return meta.term end end
return nil
end



local function maybe_compact()
local status=journal.status()
local forced=status.bytes>=(opts.max_bytes or 60000)
if status.entries<max_entries and not forced then return end
if committed_idx==last_idx then
local ok=journal.snapshot(wrapper())
if ok then snap_idx,snap_committed_idx,snap_state,metas=last_idx,committed_idx,state_delta.copy(state),{}end
elseif forced then


local keep=build(committed_idx)
local ok=journal.snapshot({s=keep,idx=last_idx,term=last_term,committed_idx=committed_idx})
if ok then
state,snap_idx,snap_committed_idx,snap_state,metas=keep,last_idx,committed_idx,state_delta.copy(keep),{}
if network.cancel_pending then
network.cancel_pending(function(msg)return msg.payload and msg.payload.cmd=="repl" and(msg.payload.kind=="entry" or msg.payload.kind=="part")end)
end
log("warn","replication: the unconfirmed tail was dropped (the other master did not answer for long)")
end
end
end



local function send_body(kind,body,reliable)
local text=json.encode(body)
local function transmit(payload)
payload.cmd="repl"
if reliable and network.send_reliable then return network.send_reliable("cmd",peer,payload)end
return network.send("cmd",peer,payload)
end
if#text<=part_bytes then
transmit({kind=kind,body=body})
return
end
counter=counter+1
local id=tostring(now_ms()).. "." .. counter
local total=math.ceil(#text/part_bytes)
for index=1,total do
transmit({kind="part",id=id,idx=index,total=total,k=kind,sum=checksum.hex(checksum.adler32(text)),data=text:sub((index - 1)*part_bytes+1,index*part_bytes)})
end
end

local function send_small(kind,body)send_body(kind,body,false)end

local function entry_body(meta,data)
return{idx=data.idx,term=data.term,prev_idx=data.prev_idx,prev_term=data.prev_term,delta=data.delta,committed_idx=committed_idx_now()}
end

local function send_entries_after(after_idx)
local sent=0
for _,entry in ipairs(journal.recovered().entries)do
if entry.kind=="state" and entry.data.idx>after_idx then
send_body("entry",entry_body(nil,entry.data),true)
sent=sent+1
end
end
return sent
end

local function send_sync()
sync_sent_at=now_ms()
send_body("sync",{idx=last_idx,term=last_term,committed_idx=committed_idx_now(),state=state},true)
end



function self.capture()
if not ha.is_leader()then return nil,"not the leader" end
local snapshot=opts.snapshot_fn()
local delta=state_delta.diff(state,snapshot)
if not delta then return last_idx end
local data={idx=last_idx+1,term=ha.term(),prev_idx=last_idx,prev_term=last_term,delta=delta}
local seq,err=journal.append("state",data)
if not seq then
log("error","replication: the change could not be written, nothing that depends on it is sent",{error=err})
return nil,err
end
state=state_delta.apply(state,delta)
last_idx,last_term=data.idx,data.term
metas[#metas+1]={idx=data.idx,seq=seq,term=data.term}
send_body("entry",entry_body(nil,data),true)
last_send=now_ms()
maybe_compact()
return last_idx
end

local function commit_up_to(idx)
if idx<=committed_idx then return true end
if idx>last_idx then return false end
local seq,err=journal.append("rcommit",{idx=idx})
if not seq then log("error","replication: commit could not be written",{error=err});return false end
committed_idx=idx
maybe_compact()
return true
end

function self.confirmed(idx)return idx<=committed_idx_now()end
function self.prepared_idx()return peer_idx end



local function accept_entry(body)
if type(body.idx)~="number" or type(body.term)~="number" or type(body.delta)~="table" then return end
if ha.is_leader()then return end
if body.term<last_term and body.idx>committed_idx_now()then
send_small("nack",{last_idx=last_idx,last_term=last_term,committed_idx=committed_idx_now(),why="old_term"})
return
end
if body.idx<=last_idx then
if body.idx<=committed_idx_now()or term_of(body.idx)==body.term then
send_small("ack",{idx=math.min(last_idx,body.idx),term=last_term,committed_idx=committed_idx_now()})
if type(body.committed_idx)=="number" then commit_up_to(math.min(body.committed_idx,last_idx))end
else
send_small("nack",{last_idx=last_idx,last_term=last_term,committed_idx=committed_idx_now(),why="diverged"})
end
return
end
if body.prev_idx~=last_idx or(last_idx>0 and body.prev_term~=last_term)then
send_small("nack",{last_idx=last_idx,last_term=last_term,committed_idx=committed_idx_now(),why="gap"})
return
end
local seq,err=journal.append("state",{idx=body.idx,term=body.term,prev_idx=body.prev_idx,prev_term=body.prev_term,delta=body.delta})
if not seq then
log("error","replication: entry could not be written, not acknowledged",{error=err})
return
end
state=state_delta.apply(state,body.delta)
last_idx,last_term=body.idx,body.term
metas[#metas+1]={idx=body.idx,seq=seq,term=body.term}
if type(body.committed_idx)=="number" then commit_up_to(math.min(body.committed_idx,last_idx))end
maybe_compact()
send_small("ack",{idx=last_idx,term=last_term,committed_idx=committed_idx_now()})
end

local function accept_sync(body)
if ha.is_leader()then return end
if type(body.idx)~="number" or type(body.state)~="table" or type(body.term)~="number" then return end
if body.idx<committed_idx_now()then return end
local committed=math.min(tonumber(body.committed_idx)or 0,body.idx)
local seq=journal.last_seq()
local ok,err=journal.install_snapshot(seq,{s=body.state,idx=body.idx,term=body.term,committed_idx=committed},seq)
if not ok then log("error","replication: synchronisation could not be written",{error=err});return end
state=state_delta.copy(body.state)
last_idx,last_term,snap_idx,snap_committed_idx,snap_state,metas,committed_idx=body.idx,body.term,body.idx,committed,state_delta.copy(body.state),{},committed
send_small("ack",{idx=last_idx,term=last_term,committed_idx=committed_idx_now(),synced=true})
end



local function leader_ack(body)
if not ha.is_leader()then return end
peer_seen=now_ms()
if type(body.idx)=="number" and body.idx>peer_idx then peer_idx=body.idx end
if type(body.idx)=="number" and body.idx<=last_idx and commit_up_to(body.idx)then
send_small("commit",{idx=committed_idx_now()})
end
if type(body.idx)=="number" and body.idx<last_idx and not body.synced then

end
end

local function leader_nack(body)
if not ha.is_leader()then return end
peer_seen=now_ms()

if last_catchup and now_ms()- last_catchup<catchup_gap_ms then return end
last_catchup=now_ms()
local have=tonumber(body.last_idx)or 0
peer_idx=have
local first_needed=have+1
local covered=first_needed>snap_idx and have<=last_idx and(have==0 and snap_idx==0 or have>=snap_idx)
if body.why=="diverged" or body.why=="old_term" then covered=false end
if covered then
send_entries_after(have)
else
send_sync()
end
end



local function dispatch(kind,body)
if type(body)~="table" then return end
if kind=="entry" then accept_entry(body)
elseif kind=="sync" then accept_sync(body)
elseif kind=="ack" then leader_ack(body)
elseif kind=="nack" then leader_nack(body)
elseif kind=="commit" then
if not ha.is_leader()and type(body.idx)=="number" then commit_up_to(math.min(body.idx,last_idx))end
elseif kind=="ping" then
if not ha.is_leader()then
if type(body.last_idx)=="number" and body.last_idx>last_idx then
send_small("nack",{last_idx=last_idx,last_term=last_term,committed_idx=committed_idx_now(),why="gap"})
else
if type(body.committed_idx)=="number" then commit_up_to(math.min(body.committed_idx,last_idx))end
send_small("ack",{idx=last_idx,term=last_term,committed_idx=committed_idx_now()})
end
end
end
end

function self.handle(msg)
local payload=msg and msg.payload
if not payload or payload.cmd~="repl" then return false end
if msg.src~=peer then return true end

if network.ack_for and(payload.kind=="entry" or payload.kind=="part" or payload.kind=="sync")then network.ack_for(msg,true)end
if payload.kind=="part" then
if type(payload.id)~="string" or type(payload.idx)~="number" or type(payload.total)~="number" or type(payload.data)~="string" or type(payload.k)~="string" then return true end
if payload.total<1 or payload.total>MAX_PARTS or payload.idx<1 or payload.idx>payload.total or#payload.data>8192 then return true end
local assembly=assemblies[payload.id]
if not assembly then
assembly={total=payload.total,parts={},count=0,k=payload.k,sum=payload.sum,bytes=0}
assemblies[payload.id]=assembly
assembly_order[#assembly_order+1]=payload.id
while#assembly_order>MAX_PENDING_ASSEMBLIES do assemblies[table.remove(assembly_order,1)]=nil end
end
if assembly.total~=payload.total then return true end
if not assembly.parts[payload.idx] then
assembly.parts[payload.idx]=payload.data
assembly.count=assembly.count+1
assembly.bytes=assembly.bytes+#payload.data
if assembly.bytes>MAX_STATE_BYTES then assemblies[payload.id]=nil;return true end
end
if assembly.count==assembly.total then
assemblies[payload.id]=nil
local text=table.concat(assembly.parts)
if checksum.hex(checksum.adler32(text))~=assembly.sum then return true end
local ok,body=pcall(json.decode,text)
if ok then dispatch(assembly.k,body)end
end
return true
end
dispatch(payload.kind,payload.body)
return true
end

function self.tick()
if not ha.is_leader()then return end
local now=now_ms()
if not last_ping or now - last_ping>=1000 then
last_ping=now
send_small("ping",{last_idx=last_idx,last_term=last_term,committed_idx=committed_idx_now()})
end

if peer_idx<last_idx and peer_seen and now - peer_seen<peer_timeout and(not last_send or now - last_send>=resend_ms)then
last_send=now
if peer_idx>=snap_idx then send_entries_after(peer_idx)elseif not sync_sent_at or now - sync_sent_at>5000 then send_sync()end
end
end



function self.promote()
if last_idx>committed_idx then

local cut_to=journal.snapshot_seq()
for _,meta in ipairs(metas)do if meta.idx<=committed_idx and meta.seq>cut_to then cut_to=meta.seq end end
local ok,err=journal.truncate_to(cut_to)
if not ok then log("error","replication: the unconfirmed tail could not be cut",{error=err})end
local kept={}
for _,meta in ipairs(metas)do if meta.idx<=committed_idx then kept[#kept+1]=meta end end
local term_at=term_of(committed_idx)
state=build(committed_idx)
metas=kept
last_idx=committed_idx
if term_at then last_term=term_at end

if committed_idx>snap_committed_idx then journal.append("rcommit",{idx=committed_idx})end
end
peer_idx,peer_seen,last_ping,last_send=committed_idx,nil,nil,nil
return state_delta.copy(state)
end

function self.demote()
peer_idx,peer_seen=0,nil
end

function self.state()return state end
function self.committed_state()return build(committed_idx)end
function self.last_idx()return last_idx end
function self.committed_idx()return committed_idx_now()end
function self.writable()return journal.status().writable end

function self.peer_ok()
return peer_seen~=nil and now_ms()- peer_seen<peer_timeout and peer_idx>=committed_idx_now()
end

function self.status()
return{last_idx=last_idx,committed_idx=committed_idx_now(),peer_idx=peer_idx,peer_ok=self.peer_ok(),journal=journal.status()}
end

function self.wrapper()return wrapper()end

return self
end

return replica
