









local time=require("src.shared.time")

local log_collector={}

local LEVELS={DEBUG=10,INFO=20,WARN=30,ERROR=40}
local MAX_ENTRIES_PER_BATCH=20
local MAX_TEXT=140

function log_collector.new(opts)
local options=opts or{}
local total=options.total or 300
local rate=options.rate_per_min or 120
local max_nodes=options.max_nodes or 1024
local now_s=options.now_s or time.now_s
local now_ms=options.now_ms or time.now_ms

local self={}
local ring={}
local buckets,bucket_count={},0
local rejected,dropped_by_nodes=0,0

local function take_token(node_id)
local now=now_ms()
local bucket=buckets[node_id]
if not bucket then
if bucket_count>=max_nodes then return false end
bucket={tokens=rate,at=now}
buckets[node_id]=bucket
bucket_count=bucket_count+1
end
bucket.tokens=math.min(rate,bucket.tokens+(now - bucket.at)*rate/60000)
bucket.at=now
if bucket.tokens<1 then return false end
bucket.tokens=bucket.tokens - 1
return true
end

function self.ingest(node_id,payload)
if type(node_id)~="string" or type(payload)~="table" or type(payload.entries)~="table" then rejected=rejected+1;return 0 end
if type(payload.dropped)=="number" and payload.dropped>0 then dropped_by_nodes=dropped_by_nodes+math.floor(payload.dropped)end
local stored=0
for i,entry in ipairs(payload.entries)do
if i>MAX_ENTRIES_PER_BATCH then rejected=rejected+1;break end
if type(entry)=="table" and type(entry.msg)=="string" and LEVELS[entry.lvl] then
if take_token(node_id)then
ring[#ring+1]={
node=node_id,lvl=entry.lvl,msg=entry.msg:sub(1,MAX_TEXT),ts=now_s(),
n=(type(entry.n)=="number" and entry.n>=1)and math.floor(entry.n)or 1,
ctx=type(entry.ctx)=="table" and entry.ctx or nil
}
stored=stored+1
if#ring>total then table.remove(ring,1)end
else
dropped_by_nodes=dropped_by_nodes+1
end
else
rejected=rejected+1
end
end
return stored
end

function self.recent(query)
local q=query or{}
local min_level=LEVELS[q.min_level or "WARN"] or LEVELS.WARN
local out={}
local skip=q.offset or 0
for i=#ring,1,-1 do
local e=ring[i]
if LEVELS[e.lvl]>=min_level and(not q.node or e.node==q.node)then
if skip>0 then skip=skip - 1 else out[#out+1]=e end
if q.limit and#out>=q.limit then break end
end
end
return out
end

function self.stats()
return{total=#ring,nodes=bucket_count,rejected=rejected,dropped_by_nodes=dropped_by_nodes}
end

return self
end

return log_collector
