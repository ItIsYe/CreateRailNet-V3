





local M={}

local ACTIVE={freigegeben=true,eingefahren=true,ausgefahren=true}
M.LONG=300
local HISTORY_MAX=20

function M.new(spec)
local a={}
local now=spec.now
local moves=spec.moves or{}
local data=(spec.store and spec.path and spec.store.load(spec.path))or{counter=0,uses={},history={}}
data.uses=data.uses or{}
data.history=data.history or{}

local function save()
if spec.store and spec.path then return spec.store.save(spec.path,data)end
return true
end

local conflict_set={}
for _,c in ipairs(spec.conflicts or{})do
local x,y=c.moves[1],c.moves[2]
conflict_set[x..":"..y]=true
conflict_set[y..":"..x]=true
end

local function moves_from(entry)
local out={}
for i,m in ipairs(moves)do if m.from==entry then out[#out+1]=i end end
return out
end

function a.entries_conflict(x,y)
if x==y then return true end
for _,i in ipairs(moves_from(x))do
for _,j in ipairs(moves_from(y))do
if conflict_set[i..":"..j]or moves[i].to==moves[j].to then return true end
end
end
return false
end

local function expected_exits(entry)
local out={}
for _,i in ipairs(moves_from(entry))do out[moves[i].to]=true end
return out
end

local function sorted()
local list={}
for _,u in pairs(data.uses)do list[#list+1]=u end
table.sort(list,function(p,q)return p.number<q.number end)
return list
end

local function log(use,how)
data.history[#data.history+1]={id=use.id,entry=use.entry,train=use.train,how=how,t=now()}
while#data.history>HISTORY_MAX do table.remove(data.history,1)end
end

function a.announce(entry,train,track)
if not spec.connections[entry]then return nil,"unbekannter Anschluss "..tostring(entry)end
for _,u in pairs(data.uses)do
if u.entry==entry and u.train==train then return u end
end
data.counter=data.counter+1
local use={id="N-"..data.counter,number=data.counter,entry=entry,train=train,track=track,state="angekuendigt",t_announced=now()}
data.uses[use.id]=use
save()
return use
end


function a.next_grants()
local granted={}
for _,u in ipairs(sorted())do
if u.state=="angekuendigt"then
local free=true
for _,other in pairs(data.uses)do
if other~=u and ACTIVE[other.state]and a.entries_conflict(u.entry,other.entry)then free=false break end
end
if free then
u.state,u.t_granted="freigegeben",now()
granted[#granted+1]=u
end
end
end
if#granted>0 then save()end
return granted
end

function a.entered(entry,train,track)
local candidate
for _,u in ipairs(sorted())do
if u.entry==entry and u.train==train and(u.state=="freigegeben"or u.state=="angekuendigt")then candidate=u break end
end
local unplanned=false
if not candidate then
data.counter=data.counter+1
candidate={id="N-"..data.counter,number=data.counter,entry=entry,train=train,track=track,t_announced=now()}
data.uses[candidate.id]=candidate
unplanned=true
elseif candidate.state=="angekuendigt"then
unplanned=true
end
candidate.state,candidate.t_entered,candidate.unplanned="eingefahren",now(),unplanned or nil
save()
return candidate,unplanned
end


function a.exited(exit,train,kind)
if train==nil then return nil,"Zugname fehlt: keine Raeumungsmeldung"end
for _,u in ipairs(sorted())do
if u.train==train and(u.state=="eingefahren"or u.state=="ausgefahren")and expected_exits(u.entry)[exit]then
if kind=="passed"then
data.uses[u.id]=nil
u.state="freigemeldet"
log(u,"freigemeldet")
save()
return u,"freigemeldet"
end
u.state,u.t_exited="ausgefahren",now()
save()
return u,"ausgefahren"
end
end
return nil,"keine passende Nutzung fuer "..tostring(train).." am Ausgang "..tostring(exit)
end

function a.withdraw(entry,train)
for _,u in pairs(data.uses)do
if u.entry==entry and u.train==train and u.state=="angekuendigt"then
data.uses[u.id]=nil
log(u,"zurueckgenommen")
save()
return true
end
end
return false
end

function a.clear(id,reason)
local u=data.uses[id]
if not u then return nil,"Die Nutzung gibt es nicht."end
data.uses[id]=nil
log(u,"vom Bediener aufgeloest: "..tostring(reason))
save()
return true
end

function a.status()
local out={}
for _,u in ipairs(sorted())do
local since=u.t_exited or u.t_entered or u.t_granted or u.t_announced
out[#out+1]={
id=u.id,entry=u.entry,train=u.train,track=u.track,state=u.state,unplanned=u.unplanned,since=since,
long=ACTIVE[u.state]and(now()-since)>=M.LONG or false,
}
end
return out
end

function a.history()return data.history end

return a
end

return M
