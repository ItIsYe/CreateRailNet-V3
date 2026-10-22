
















local time=require("src.shared.time")

local alerts={}

local RANK={RED=2,YELLOW=1}

function alerts.new(opts)
local options=opts or{}
local now_s=options.now_s or time.now_s
local capacity=options.capacity or 200
local clear_ttl=options.clear_ttl_s or 600
local self={}
local entries={}
local dropped=0

local function size()
local n=0
for _ in pairs(entries)do n=n+1 end
return n
end


local function keep_score(e)
if e.state=="CLEARED" and e.acked then return 1 end
if e.state=="CLEARED" and e.severity~="RED" then return 2 end
if e.state=="CLEARED" then return 3 end
if e.acked and e.severity~="RED" then return 4 end
if e.acked then return 5 end
if e.severity~="RED" then return 6 end
return 7
end

local function enforce_capacity()
while size()>capacity do
local worst
for _,e in pairs(entries)do
if not worst or keep_score(e)<keep_score(worst)or(keep_score(e)==keep_score(worst)and e.last_at<worst.last_at)then worst=e end
end
if keep_score(worst)>=6 then dropped=dropped+1 end
entries[worst.key]=nil
end
end

function self.raise(key,severity,text,data,raise_opts)
local now=now_s()
local sev=RANK[severity] and severity or "YELLOW"
local e=entries[key]
if e then
e.count=e.count+1
e.last_at=now
e.text=text or e.text
e.data=data or e.data
if RANK[sev]>RANK[e.severity] then e.severity=sev end
if e.state=="CLEARED" then
e.state="ACTIVE";e.acked=false;e.acked_by=nil;e.cleared_at=nil
end
else
e={key=key,severity=sev,text=text or key,data=data,state="ACTIVE",count=1,first_at=now,last_at=now,acked=false}
entries[key]=e
enforce_capacity()
end
e.expires_at=raise_opts and raise_opts.ttl_s and(now+raise_opts.ttl_s)or nil
return e
end

function self.clear(key)
local e=entries[key]
if not e or e.state~="ACTIVE" then return false end
e.state="CLEARED"
e.cleared_at=now_s()
e.expires_at=nil
if e.acked then entries[key]=nil end
return true
end

function self.ack(key,who)
local e=entries[key]
if not e then return false end
e.acked=true
e.acked_by=who
e.acked_at=now_s()
if e.state=="CLEARED" then entries[key]=nil end
return true
end

function self.ack_all(who)
local keys={}
for key,e in pairs(entries)do if not e.acked then keys[#keys+1]=key end end
for _,key in ipairs(keys)do self.ack(key,who)end
return#keys
end

function self.tick()
local now=now_s()
local expire,remove={},{}
for key,e in pairs(entries)do
if e.state=="ACTIVE" and e.expires_at and now>=e.expires_at then expire[#expire+1]=key end
if e.state=="CLEARED" and e.severity~="RED" and e.cleared_at and now - e.cleared_at>=clear_ttl then remove[#remove+1]=key end
end
for _,key in ipairs(expire)do self.clear(key)end
for _,key in ipairs(remove)do entries[key]=nil end
end

function self.get(key)return entries[key] end

function self.list(list_opts)
local o=list_opts or{}
local out={}
for _,e in pairs(entries)do
if not(o.active_only and e.state~="ACTIVE")then out[#out+1]=e end
end
table.sort(out,function(a,b)
local ga=(a.acked and 1 or 0)+(a.state=="CLEARED" and 2 or 0)
local gb=(b.acked and 1 or 0)+(b.state=="CLEARED" and 2 or 0)
if ga~=gb then return ga<gb end
if a.severity~=b.severity then return RANK[a.severity]>RANK[b.severity] end
if a.last_at~=b.last_at then return a.last_at>b.last_at end
return a.key<b.key
end)
local first=(o.offset or 0)+1
local last=o.limit and math.min(#out,first+o.limit - 1)or#out
local page={}
for i=first,last do page[#page+1]=out[i] end
return page
end

function self.counts()
local c={total=0,active_red=0,active_yellow=0,unacked=0,dropped=dropped}
for _,e in pairs(entries)do
c.total=c.total+1
if e.state=="ACTIVE" then
if e.severity=="RED" then c.active_red=c.active_red+1 else c.active_yellow=c.active_yellow+1 end
end
if not e.acked then c.unacked=c.unacked+1 end
end
return c
end

return self
end

return alerts
