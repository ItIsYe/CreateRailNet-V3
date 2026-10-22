











local priority={}

priority.KINDS={"REPLACEMENT_PASSENGER","SCHEDULED_PASSENGER","REPLACEMENT_FREIGHT","SCHEDULED_FREIGHT","EXTRA_PASSENGER","EXTRA_FREIGHT"}

local RANK={}
for i,kind in ipairs(priority.KINDS)do RANK[kind]=i end

function priority.new(opts)
opts=opts or{}
local now=opts.now or function()return 0 end
local aging_s=opts.aging_s or 600
local max_promotion=opts.max_promotion
if max_promotion==nil then max_promotion=2 end
local self={}
local orders,seq={},0

local function effective(order)
local steps=0
if aging_s>0 and max_promotion>0 then steps=math.min(max_promotion,math.floor((now()- order.queued_at)/aging_s))end
return math.max(1,order.rank - steps)
end

local function refresh(order)order.effective=effective(order);return order end

function self.push(order)
if type(order)~="table" or type(order.id)~="string" or order.id=="" then return false,"order needs an id" end
if not RANK[order.kind] then return false,"unknown kind " .. tostring(order.kind)end
if orders[order.id] then return false,"order " .. order.id .. " already exists" end
seq=seq+1
local stored={}
for k,v in pairs(order)do stored[k]=v end
stored.rank,stored.seq,stored.queued_at=RANK[order.kind],seq,now()
orders[order.id]=stored
return true
end

function self.get(id)
local order=orders[id]
return order and refresh(order)or nil
end

function self.remove(id)
if not orders[id] then return false end
orders[id]=nil
return true
end

function self.size()
local n=0
for _ in pairs(orders)do n=n+1 end
return n
end

function self.list()
local out={}
for _,order in pairs(orders)do out[#out+1]=refresh(order)end
table.sort(out,function(a,b)
if a.effective~=b.effective then return a.effective<b.effective end
if a.rank~=b.rank then return a.rank<b.rank end
return a.seq<b.seq
end)
return out
end

function self.next(filter)
for _,order in ipairs(self.list())do
if not filter or filter(order)then return order end
end
return nil
end

function self.snapshot()
local out={seq=seq,orders={}}
for id,order in pairs(orders)do
local c={}
for k,v in pairs(order)do c[k]=v end
out.orders[id]=c
end
return out
end

function self.restore(snap)
orders,seq={},(snap and snap.seq)or 0
for id,order in pairs((snap and snap.orders)or{})do
local c={}
for k,v in pairs(order)do c[k]=v end
orders[id]=c
end
end

return self
end

return priority
