











local cargo_meter={}

function cargo_meter.new(opts)
local api=opts.peripheral
local now=opts.now or function()return 0 end
local tries=opts.tries or 4
local self={}
local started={}
local counter=0

function self.total(name,item)
if not(api and api.call)then return nil,"no peripheral api" end
local ok,list=pcall(api.call,name,"list")
if not ok or type(list)~="table" then return nil,"inventory " .. tostring(name).. " cannot be read" end
local total=0
for _,stack in pairs(list)do
if type(stack)~="table" or type(stack.count)~="number" or stack.count<0 then return nil,"inventory " .. tostring(name).. " answers nonsense" end
if item==nil or stack.name==item then total=total+stack.count end
end
return total
end

function self.begin(key,name,item)
local total,err=self.total(name,item)
if not total then started[key]=nil;return false,err end
started[key]={name=name,item=item,total=total,at=now()}
return true
end

function self.pending(key)return started[key]~=nil end

function self.finish(key,kind)
local s=started[key]
started[key]=nil
if not s then return{ok=false,reason="no start reading"}end
if kind~="loaded" and kind~="unloaded" then return{ok=false,reason="unknown kind " .. tostring(kind)}end
local previous
for _=1,tries do
local total,err=self.total(s.name,s.item)
if not total then return{ok=false,reason=err}end
if previous~=nil and total==previous then
local qty=(kind=="loaded")and(s.total - total)or(total - s.total)
if qty<0 then return{ok=false,reason="the inventory moved the wrong way for '" .. kind .. "' (" .. s.total .. " -> " .. total .. ")"}end
counter=counter+1
return{ok=true,qty=qty,quality="AUTO_INVENTORY",ref=tostring(key).. "#" .. counter .. "@" .. tostring(math.floor(now()))}
end
previous=total
end
return{ok=false,reason="the inventory does not hold still"}
end

return self
end

return cargo_meter
