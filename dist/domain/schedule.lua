





local ser=require("core.ser")
local adler=require("core.adler")

local M={}

local function deepcopy(v)
if type(v)~="table"then return v end
local out={}
for k,x in pairs(v)do out[k]=deepcopy(x)end
return out
end

function M.destination(name)return{id="create:destination",data={text=name}}end
function M.delay(seconds)return{id="create:delay",data={value=seconds,time_unit=1}}end
function M.powered()return{id="create:powered",data={}}end

local function entry(station,conditions)
return{instruction=M.destination(station),conditions={conditions}}
end


function M.waiting(station,wait)
local conditions={}
if wait and wait>0 then conditions[#conditions+1]=M.delay(wait)end
conditions[#conditions+1]=M.powered()
return{cyclic=true,entries={entry(station,conditions)}}
end


function M.locate(condition,wanted)
local target=tostring(wanted)
local function walk(node,path)
if type(node)=="table"then
local keys={}
for k in pairs(node)do keys[#keys+1]=k end
table.sort(keys,function(a,b)return tostring(a)<tostring(b)end)
for _,k in ipairs(keys)do
local p={}
for i,x in ipairs(path)do p[i]=x end
p[#p+1]=k
local found=walk(node[k],p)
if found then return found end
end
elseif tostring(node)==target then
return path
end
return nil
end
return walk(condition.data or{},{"data"})
end


function M.find_cargo(sched)
for _,e in ipairs(sched and sched.entries or{})do
for _,group in ipairs(e.conditions or{})do
for _,c in ipairs(group)do
if c.id~="create:delay"and c.id~="create:powered"then return c end
end
end
end
return nil
end


function M.locate_unique(condition,wanted)
local target,found,count=tostring(wanted),nil,0
local function walk(node,path)
if type(node)=="table"then
for k,v in pairs(node)do
local p={}
for i,x in ipairs(path)do p[i]=x end
p[#p+1]=k
walk(v,p)
end
elseif tostring(node)==target then
count=count+1
found=path
end
end
walk(condition.data or{},{"data"})
if count==0 then return nil,"Der Wert "..target.." kommt in der Bedingung nicht vor."end
if count>1 then return nil,"Der Wert "..target.." kommt mehrfach vor: bitte eine eindeutige Zahl im Fahrplan verwenden (z.B. 7)."end
return found
end

local function set_path(root,path,value)
local node=root
for i=1,#path-1 do node=node[path[i]]end
node[path[#path]]=value
end

function M.cargo_condition(sample,count)
if not sample or not sample.condition or not sample.path then return nil,"Kein Musterfahrplan fuer Mengenbedingungen vorhanden."end
local cond=deepcopy(sample.condition)
local old=cond
for _,key in ipairs(sample.path)do old=old[key]end
local value=count
if type(old)=="string"then value=tostring(count)end
set_path(cond,sample.path,value)
return cond
end




function M.first_repeat(names,cyclic)
for i=1,#names-1 do
if names[i]==names[i+1]then return i,i+1 end
end
if cyclic and#names>=2 and names[#names]==names[1]then return#names,1 end
return nil
end



function M.section(own,halt,destination,samples)
halt=halt or{}
if own==destination then
return nil,"Eigener und naechster Bahnhof heissen beide "..tostring(own)..": Create schickt einen Zug nicht direkt vom selben Bahnhof wieder dorthin (erst zu einem anderen)."
end
local conditions={M.delay(math.max(1,math.floor(halt.wait or 0)))}
if halt.cargo then
local cond,err=M.cargo_condition(samples and samples.item_threshold,halt.cargo.count)
if not cond then return nil,err end
conditions[#conditions+1]=cond
end
return{cyclic=false,entries={entry(own,conditions),entry(destination,{M.powered()})}}
end

local function group_problems(e,i,problems)
if not e.instruction or e.instruction.id~="create:destination"or not e.instruction.data or type(e.instruction.data.text)~="string"then
problems[#problems+1]="Eintrag "..i.." hat kein Ziel."
end
if type(e.conditions)~="table"or#e.conditions~=1 then
problems[#problems+1]="Eintrag "..i..": es muss genau eine Bedingungsgruppe geben (keine Alternative, die die Pruefung umgeht)."
return nil
end
return e.conditions[1]
end



function M.check_section(sched)
local problems={}
if type(sched)~="table"or type(sched.entries)~="table"or#sched.entries~=2 then
return{"Der Abschnittsfahrplan braucht genau zwei Eintraege (eigener und naechster Bahnhof)."}
end
if sched.cyclic==true then problems[#problems+1]="Der Abschnittsfahrplan ist nicht umlaufend."end
local first=group_problems(sched.entries[1],1,problems)
if first then
local has_delay=false
for _,c in ipairs(first)do
if c.id=="create:delay"then has_delay=true end
if c.id=="create:powered"then problems[#problems+1]="Eintrag 1: kein create:powered, sonst fuehre der Zug nie ab."end
end
if not has_delay then problems[#problems+1]="Eintrag 1 braucht eine Wartezeit (create:delay)."end
end
local second=group_problems(sched.entries[2],2,problems)
if second then
local last=second[#second]
if not last or last.id~="create:powered"then problems[#problems+1]="Eintrag 2: die letzte Bedingung muss create:powered sein (der Zug haelt dort)."end
end
local names=M.stops(sched)
if#names==2 and names[1]==names[2]then
problems[#problems+1]="Eintrag 1 und 2 nennen beide "..names[1]..": Create schickt einen Zug nicht direkt vom selben Bahnhof wieder dorthin (erst zu einem anderen)."
end
return problems
end


function M.with_rest_wait(sched,seconds)
local copy=deepcopy(sched)
local first=copy and copy.entries and copy.entries[1]
local group=first and first.conditions and first.conditions[1]
for _,c in ipairs(group or{})do
if c.id=="create:delay"and c.data then
local value=math.max(1,math.ceil(tonumber(seconds)or 0))
if type(c.data.value)=="number"and value<c.data.value then c.data.value=value end
break
end
end
return copy
end



function M.route_hash(sched)
if type(sched)~="table"or type(sched.entries)~="table"then return nil end
local last=sched.entries[#sched.entries]
local group=last and last.conditions and last.conditions[1]
local holds=group~=nil and group[#group]~=nil and group[#group].id=="create:powered"
return adler.hex(ser.encode({stops=M.stops(sched),cyclic=sched.cyclic==true,holds=holds}))
end

function M.same(a,b)
if a==nil or b==nil then return false end
return ser.encode(a)==ser.encode(b)
end


function M.hash(sched)
return adler.hex(ser.encode(sched))
end

function M.stops(sched)
local out={}
for _,e in ipairs(sched and sched.entries or{})do
if e.instruction and e.instruction.data then out[#out+1]=e.instruction.data.text end
end
return out
end

return M
