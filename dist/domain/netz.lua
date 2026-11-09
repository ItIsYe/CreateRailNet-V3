





local ser=require("core.ser")

local M={}

M.MAX_NODES=500
M.VERSION=5
M.NAME_MAX=30
M.STATION_MAX=40

local ROLE_CODE={bahnhof="BHF",anmeldung="ANM"}
local ROLE_TEXT={bahnhof="Bahnhof",anmeldung="Anmeldung"}
M.ROLE_CODE,M.ROLE_TEXT=ROLE_CODE,ROLE_TEXT

local LEGACY_ROLE={passagierbahnhof="bahnhof",gueterbahnhof="bahnhof",depot="bahnhof"}

local function copy(value)return ser.decode(ser.encode(value))end

local function clean(text)
if type(text)~="string"then return nil end
text=text:match("^%s*(.-)%s*$"):gsub("%s+"," ")
return text
end


local function valid_name(text)
text=clean(text)
if not text or text==""then return nil,"Der Name fehlt."end
if#text>M.NAME_MAX then return nil,"Der Name ist zu lang (hoechstens "..M.NAME_MAX.." Zeichen)."end
if text:find("[^A-Za-z0-9 _%-]")then return nil,"Der Name darf nur Buchstaben, Ziffern, Leerzeichen, - und _ enthalten."end
return text
end
M.valid_name=valid_name

local function same(a,b)return a:lower()==b:lower()end



local function station_part(station)
if type(station)~="string"then return""end
local text=station:gsub("[^%w _%-]",""):gsub("%s+"," "):match("^%s*(.-)%s*$")
return text~=""and(" "..text)or""
end

local ROLE_ORDER={"bahnhof","anmeldung"}
local ROLE_RANK={}
for i,r in ipairs(ROLE_ORDER)do ROLE_RANK[r]=i end





local function upgrade(data)
data.areas,data.tracks,data.junctions=nil,nil,nil
local stations=data.stations or{}
for id,node in pairs(data.nodes or{})do
node.area,node.junction,node.tracks=nil,nil,nil
local roles,seen={},{}
for _,r in ipairs(node.roles or{node.role})do
r=LEGACY_ROLE[r]or r
if ROLE_CODE[r]and not seen[r]then seen[r]=true;roles[#roles+1]=r end
end
table.sort(roles,function(a,b)return(a=="bahnhof"and 0 or 1)<(b=="bahnhof"and 0 or 1)end)
if#roles==0 then
node.roles={}
if node.state=="reserviert"then node.state="verworfen"end
else
node.roles=roles
end
node.role=roles[1]

local st=type(node.station)=="string"and stations[node.station]or nil
node.station=st and type(st.name)=="string"and st.name or nil

if#roles>0 and type(node.name)=="string"then
local codes,texts={},{}
for _,r in ipairs(roles)do codes[#codes+1]=ROLE_CODE[r];texts[#texts+1]=ROLE_TEXT[r]end
node.name=((#roles==1)and texts[1]or table.concat(codes," "))..station_part(node.station).." "..id
node.label=id.." | "..table.concat(codes," ")
end
end
data.stations,data.sites=nil,nil
if data.counters then data.counters.bereich,data.counters.gleis,data.counters.knoten=nil,nil,nil;data.counters.betriebsstelle,data.counters.standort=nil,nil end
if data.tokens then data.tokens=nil end
end

function M.new(spec)
local n={}
local store,path=spec.store,spec.path
local data=(store and path and store.load(path))or nil
if type(data)~="table"then data={}end

n.blocked=type(data.version)=="number"and data.version>M.VERSION
if not n.blocked then
if type(data.version)=="number"and data.version<M.VERSION then upgrade(data)end
data.version=M.VERSION
end
data.revision=data.revision or 0
data.counters=data.counters or{}
data.counters.node=data.counters.node or 0
data.nodes=data.nodes or{}


local depth=0
local function change(fn)
if n.blocked then return nil,"Das Verzeichnis stammt von einem neueren Programm: nichts wird veraendert."end
if depth>0 then return fn()end
local before=copy(data)
depth=1
local ok,result,err=pcall(fn)
depth=0
if not ok then
data=before
error(result,0)
end
if result==nil then
data=before
return nil,err
end
data.revision=data.revision+1
if store and path then
local ok2,why=store.save(path,data)
if not ok2 then
data=before
return nil,"Das Verzeichnis konnte nicht gespeichert werden: "..tostring(why)
end
end
return result
end

local function touch(entity)entity.rev=(entity.rev or 0)+1 end


local function stale(entity,if_rev,what)
if if_rev~=nil and(entity.rev or 0)~=if_rev then
return"Das "..what.." wurde inzwischen geaendert (Stand "..(entity.rev or 0).."): bitte neu laden."
end
end

local function new_id(kind,prefix)
data.counters[kind]=data.counters[kind]+1
return string.format("%s%04d",prefix,data.counters[kind])
end

function n.revision()return data.revision end


local function station_text(text)
if type(text)~="string"then return nil,"Der Bahnhof ist ungueltig."end
text=clean(text)
if text==""then return nil,"Der Bahnhof fehlt."end
if#text>M.STATION_MAX then return nil,"Der Name des Bahnhofs ist zu lang (hoechstens "..M.STATION_MAX.." Zeichen)."end
if text:find("[%c]")then return nil,"Der Name des Bahnhofs enthaelt ungueltige Zeichen."end
return text
end


function n.rename_station(old,new)
return change(function()
local why
new,why=station_text(new)
if not new then return nil,why end
local count=0
for id,node in pairs(data.nodes)do
if node.station==old and node.state~="verworfen"then
node.station=new
if#(node.roles or{})==1 then node.name=ROLE_TEXT[node.roles[1]]..station_part(new).." "..id end
count=count+1
end
end
return count
end)
end


local function view(id,node)
return{id=id,claim=node.claim,role=node.role,roles=node.roles and copy(node.roles)or{node.role},station=node.station,legacy=node.legacy,state=node.state,name=node.name,label=node.label}
end

local function claim_roles(spec2)
local list=spec2.roles
if list==nil then list={spec2.role}end
if type(list)~="table"or#list==0 or#list>4 then return nil,"Fuer diese Rolle gibt es keine Anforderung."end
local seen,named,out={},{},{}
for _,r in ipairs(list)do
local given=r
if type(r)=="string"then r=LEGACY_ROLE[r]or r end
if type(r)~="string"or not ROLE_CODE[r]then return nil,"Fuer diese Rolle gibt es keine Anforderung."end

if named[given]then return nil,"Die Rolle "..r.." ist doppelt angegeben."end
named[given]=true
if not seen[r]then seen[r]=true;out[#out+1]=r end
end
table.sort(out,function(a,b)return ROLE_RANK[a]<ROLE_RANK[b]end)
return out
end



function n.claim_node(spec2)
return change(function()
local claim=spec2.claim
if type(claim)~="string"or#claim<8 or#claim>64 or claim:find("[^%w%-_]")then return nil,"Die Anforderungskennung ist ungueltig."end
local roles,why_roles=claim_roles(spec2)
if not roles then return nil,why_roles end
local codes,texts={},{}
for _,r in ipairs(roles)do codes[#codes+1]=ROLE_CODE[r];texts[#texts+1]=ROLE_TEXT[r]end
local code=table.concat(codes," ")
local role_text=(#roles==1)and texts[1]or code
local primary=roles[1]
local station_id
if#roles==1 and primary=="anmeldung"then
local why
station_id,why=station_text(spec2.station)
if not station_id then return nil,why end
else
if spec2.station~=nil then return nil,"Nur die Rolle anmeldung allein nennt einen Bahnhof."end
end

local legacy=spec2.legacy
if legacy~=nil then
if type(legacy)~="string"or#legacy==0 or#legacy>30 or legacy:find("[^%w_%-]")then return nil,"Die bisherige Node-Kennung ist ungueltig."end
for id,node in pairs(data.nodes)do
if node.legacy==legacy and node.claim~=claim and node.state~="verworfen"then return nil,"Die Node "..legacy.." ist schon als "..id.." im Verzeichnis."end
end
end
local function naming(id)
local name=role_text..station_part(station_id).." "..id
local label=id.." | "..code
return name,label
end

for id,node in pairs(data.nodes)do
if node.claim==claim then
if node.state=="verworfen"then return nil,"Diese Anforderung wurde verworfen."end
node.legacy=legacy
node.role,node.roles,node.station=primary,roles,station_id
node.name,node.label=naming(id)
return view(id,node)
end
end
local count=0
for _ in pairs(data.nodes)do count=count+1 end
if count>=M.MAX_NODES then return nil,"Es gibt schon "..M.MAX_NODES.." Nodes im Verzeichnis."end
local id=new_id("node","N")
local name,label=naming(id)
data.nodes[id]={claim=claim,role=primary,roles=roles,station=station_id,legacy=legacy,state="reserviert",name=name,label=label}
return view(id,data.nodes[id])
end)
end


function n.mark_active(id)
local node=data.nodes[id]
if not node then

for _,other in pairs(data.nodes)do
if other.legacy==id and other.state=="reserviert"then node=other break end
end
end
if not node or node.state~="reserviert"then return true end
return change(function()node.state="aktiv"return true end)
end


function n.discard_node(id)
return change(function()
local node=data.nodes[id]
if not node then return nil,"Die Node gibt es nicht."end
if node.state~="reserviert"then return nil,"Nur eine noch nicht aktivierte Anforderung laesst sich verwerfen."end
node.state="verworfen"
return true
end)
end


function n.remove_node(id)
return change(function()
local node=data.nodes[id]
if not node then
for _,other in pairs(data.nodes)do
if other.legacy==id and other.state~="verworfen"then node=other break end
end
end
if not node then return nil,"Die Node gibt es nicht."end
if node.state=="verworfen"then return nil,"Die Node ist schon entfernt."end
node.state="verworfen"
return true
end)
end

function n.nodes()
local list={}
for id,node in pairs(data.nodes)do list[#list+1]=view(id,node)end
table.sort(list,function(a,b)return a.id<b.id end)
return list
end

function n.node(id)
local node=data.nodes[id]
return node and view(id,node)or nil
end

return n
end

return M
