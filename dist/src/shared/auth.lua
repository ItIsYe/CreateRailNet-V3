


















local sha256=require("src.shared.sha256")
local canon=require("src.shared.canon")

local auth={}

local MARKER="crn1"
local MAC_BYTES=16
local WINDOW=256
local MAX_FIELD=64
local CHALLENGE_REUSE_MS=10000
local CHALLENGE_GAP_MS=250
local SUSPECT_FAILS=10
local SUSPECT_WINDOW_MS=10000
local SUSPECT_RATE=5
local MAX_PEERS=2048

auth.WINDOW=WINDOW
auth.MAC_BYTES=MAC_BYTES

local function short_text(value)return type(value)=="string" and value~="" and#value<=MAX_FIELD end


local function number_text(value)
if type(value)~="number" then return "" end
return string.format("%.17g",value)
end


local function signed_text(msg)
local payload,err=canon.encode(msg.payload or{})
if not payload then return nil,err end
return table.concat({
MARKER,msg.src,msg.dst,msg.type,msg.id,number_text(msg.pv),number_text(msg.ts),
tostring(msg.ss or ""),number_text(msg.sq),number_text(msg.ke),tostring(msg.ch or ""),payload
},"\n")
end

local function mac_of(key,msg)
local text,err=signed_text(msg)
if not text then return nil,err end
return sha256.hmac_hex(key,text):sub(1,MAC_BYTES*2)
end

function auth.new(opts)
local self={mode=opts.mode or "off",node_id=opts.node_id,keyring=opts.keyring,stats={}}
local now_ms=opts.now_ms or function()return 0 end
local logger=opts.logger
local open_events,open_cmds=opts.open_events or{},opts.open_cmds or{}
local budget_rate=opts.budget or 400
local entropy_counter=0

local function entropy_text()
entropy_counter=entropy_counter+1
local extra=opts.entropy and opts.entropy()or ""
local random=math.random and math.random(0,2147483646)or 0
return table.concat({tostring(now_ms()),tostring(os.clock and os.clock()or 0),tostring(random),tostring(entropy_counter),tostring(extra)},"|")
end

local function new_session()
return sha256.hex(entropy_text().. "|session|" .. tostring(self.node_id)):sub(1,16)
end

self.session=opts.session or new_session()
local sequence={}
local peer_nonce={}
local peers={}
local pending={}
local peer_count=0
local bucket,bucket_at=budget_rate,nil
local suspects={}

local function count(name)self.stats[name]=(self.stats[name] or 0)+1 end

local function take_budget(src)
local now=now_ms()
if bucket_at then
bucket=math.min(budget_rate,bucket+(now - bucket_at)/1000*budget_rate)
end
bucket_at=now
local suspect=suspects[src]
if suspect and suspect.fails>=SUSPECT_FAILS and now - suspect.since<SUSPECT_WINDOW_MS then
suspect.tokens=math.min(SUSPECT_RATE,suspect.tokens+(now - suspect.at)/1000*SUSPECT_RATE)
suspect.at=now
if suspect.tokens<1 then return false end
suspect.tokens=suspect.tokens - 1
end
if bucket<1 then return false end
bucket=bucket - 1
return true
end

local function note_failure(src)
local now=now_ms()
local suspect=suspects[src]
if not suspect or now - suspect.since>=SUSPECT_WINDOW_MS then
if not suspect then

local n=0
for _ in pairs(suspects)do n=n+1 end
if n>=MAX_PEERS then suspects={}end
end
suspect={fails=0,since=now,tokens=SUSPECT_RATE,at=now}
suspects[src]=suspect
end
suspect.fails=suspect.fails+1
end



local function apply_mac(msg,keep_sequence)
if self.mode=="off" or not self.keyring then return false,"off" end
local key,reason=self.keyring.pair_key(msg.src,msg.dst)
if not key then return false,reason end
if not keep_sequence then
sequence[msg.dst]=(sequence[msg.dst] or 0)+1
msg.sq=sequence[msg.dst]
end
msg.ss=self.session
msg.ke=self.keyring.epoch_for and self.keyring.epoch_for(msg.dst=="broadcast" and msg.src or msg.dst)or nil
msg.ch=peer_nonce[msg.dst]
local mac,err=mac_of(key,msg)
if not mac then return false,err end
msg.at=mac
return true
end

function self.sign(msg)

return apply_mac(msg,false)
end


function self.resign(msg)
msg.at=nil
return apply_mac(msg,true)
end

function self.accept_challenge(msg)
local payload=msg.payload or{}
if payload.kind~="challenge" then return false,"not_a_challenge" end
if payload.for_ss~=self.session then return false,"other_session" end
if not short_text(payload.nonce)then return false,"bad_nonce" end
peer_nonce[msg.src]=payload.nonce
return true,payload.ss
end




local function fresh_nonce(src,ss)
local now=now_ms()
local existing=pending[src]
if existing and existing.ss==ss then
if now - existing.sent_at<CHALLENGE_GAP_MS then return nil end
if now - existing.at<CHALLENGE_REUSE_MS then existing.sent_at=now;return existing.nonce end
end
local nonce=sha256.hex(entropy_text().. "|challenge|" .. tostring(src).. "|" .. tostring(ss)):sub(1,24)
pending[src]={ss=ss,nonce=nonce,at=now,sent_at=now}
return nonce
end


function self.counter_challenge(src,ss)
if not short_text(ss)then return nil end
return fresh_nonce(src,ss)
end


local function window_check(peer,sq)
if type(sq)~="number" or sq~=math.floor(sq)or sq<1 then return "old" end
if sq<=peer.hi - WINDOW then return "old" end
if peer.seen[sq] then return "seen" end
peer.seen[sq]=true
if sq>peer.hi then
peer.hi=sq
local cut=peer.hi - WINDOW
for seen_sq in pairs(peer.seen)do if seen_sq<=cut then peer.seen[seen_sq]=nil end end
end
return "new"
end

local function fields_sane(msg)
if msg.at~=nil and(type(msg.at)~="string" or#msg.at~=MAC_BYTES*2 or not msg.at:match("^%x+$"))then return false end
if msg.ss~=nil and not short_text(msg.ss)then return false end
if msg.ch~=nil and not short_text(msg.ch)then return false end
if msg.sq~=nil and type(msg.sq)~="number" then return false end
if msg.ke~=nil and type(msg.ke)~="number" then return false end
return true
end

local function may_be_unsigned(msg)
local payload=msg.payload or{}
if msg.type=="event" then return open_events[payload.type]==true end
if msg.type=="cmd" then return open_cmds[payload.cmd]==true end
return false
end


function self.verify(msg)
if self.mode=="off" or not self.keyring then return "open","off" end
local enforce=self.mode=="enforce"
if not fields_sane(msg)then
count("bad_field")
if enforce then return "reject","bad_field" end
return "open","bad_field"
end

if msg.at==nil then
if may_be_unsigned(msg)then count("open");return "open","unsigned_open" end
count("unsigned")
if enforce then return "reject","unsigned" end
return "open","unsigned"
end

if not take_budget(msg.src)then
count("overload")
return "reject","overload"
end

local key,reason=self.keyring.pair_key(msg.src,msg.dst,msg.ke)
if not key then
count(reason or "no_key")

if may_be_unsigned(msg)then return "open","stranger" end
if enforce then return "reject",reason or "no_key" end
return "open",reason or "no_key"
end

local expected=mac_of(key,msg)
if not expected or not sha256.equal(expected,msg.at)then
note_failure(msg.src)
count("bad_mac")
if may_be_unsigned(msg)then return "open","bad_mac_open" end
if enforce then return "reject","bad_mac" end
return "open","bad_mac"
end


if msg.type=="auth" then
local ok,why=self.accept_challenge(msg)
if not ok then count("challenge_refused");return "reject",why end
count("challenge_accepted")
return "challenge_accepted",msg.src,why
end


if msg.dst=="broadcast" then
count("broadcast")
if enforce then return "reject","broadcast" end
return "open","broadcast"
end

if type(msg.ss)~="string" or type(msg.sq)~="number" then
count("no_session")
if enforce then return "reject","no_session" end
return "open","no_session"
end

local peer=peers[msg.src]
local established=peer and peer.ss==msg.ss and msg.ch==peer.nonce
if not established then
local waiting=pending[msg.src]
if waiting and waiting.ss==msg.ss and msg.ch~=nil and msg.ch==waiting.nonce then
if not peer and peer_count>=MAX_PEERS then return "reject","overload" end
if not peer then peer_count=peer_count+1 end
peer={ss=msg.ss,nonce=waiting.nonce,hi=0,seen={}}
peers[msg.src]=peer
count("session_started")
else
local nonce=fresh_nonce(msg.src,msg.ss)
if not nonce then count("challenge_limited");return "reject","challenge_limited" end
count("challenge_sent")
return "challenge",nonce
end
end

local position=window_check(peer,msg.sq)
if position=="old" then
count("replay")
return "reject","replay"
elseif position=="seen" then
count("seen")
return "duplicate","seen"
end
count("ok")
return "ok","signed"
end

return self
end

return auth
