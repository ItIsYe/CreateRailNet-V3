





local ser=require("core.ser")

local M={}

M.MAX_NODES=500
M.MAX_STATIONS=300
M.VERSION=3
M.NAME_MAX=30

local ROLE_CODE={passagierbahnhof="PBF",gueterbahnhof="GBF",depot="DEP",anmeldung="ANM"}
local ROLE_TEXT={passagierbahnhof="Personenbahnhof",gueterbahnhof="Gueterbahnhof",depot="Depot",anmeldung="Anmeldung"}
M.ROLE_CODE,M.ROLE_TEXT=ROLE_CODE,ROLE_TEXT

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

local ROLE_ORDER={"passagierbahnhof","gueterbahnhof","depot","anmeldung"}
local ROLE_RANK={}
for i,r in ipairs(ROLE_ORDER)do ROLE_RANK[r]=i end



local function upgrade(data)
data.areas,data.tracks,data.junctions=nil,nil,nil
for _,st in pairs(data.stations or{})do st.links=nil end
for _,node in pairs(data.nodes or{})do
node.area,node.junction,node.tracks=nil,nil,nil
local roles={}
for _,r in ipairs(node.roles or{node.role})do
if ROLE_CODE[r]then roles[#roles+1]=r end
end
if#roles==0 then
node.roles={}
if node.state=="reserviert"then node.state="verworfen"end
else
node.roles=roles
end
node.role=roles[1]
end
if data.counters then data.counters.bereich,data.counters.gleis,data.counters.knoten=nil,nil,nil end
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
for _,k in ipairs({"node","betriebsstelle","standort"})do data.counters[k]=data.counters[k]or 0 end
data.nodes=data.nodes or{}
data.stations,data.sites=data.stations or{},data.sites or{}


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

local function empty_text(v)return v==nil or v==false or clean(v)==""end


local STATION_KINDS={personenbahnhof=true,gueterbahnhof=true,depot=true}
M.STATION_KINDS=STATION_KINDS

local function site_by_name(name)
for id,site in pairs(data.sites)do if same(site.name,name)then return id end end
end


local function site_for(name)
if empty_text(name)then return nil end
local text,why=valid_name(name)
if not text then return nil,why end
local id=site_by_name(text)
if not id then
id=new_id("standort","S")
data.sites[id]={name=text}
end
return id
end

local function prune_sites()
for id in pairs(data.sites)do
local used=false
for _,st in pairs(data.stations)do if st.site==id then used=true end end
if not used then data.sites[id]=nil end
end
end

local function station_name_taken(name,except)
for id,st in pairs(data.stations)do
if id~=except and same(st.name,name)then return true end
end
return false
end

function n.add_station(spec2)
return change(function()
local count=0
for _ in pairs(data.stations)do count=count+1 end
if count>=M.MAX_STATIONS then return nil,"Es gibt schon "..M.MAX_STATIONS.." Betriebsstellen."end
local name,why=valid_name(spec2.name)
if not name then return nil,why end
if station_name_taken(name)then return nil,"Eine Betriebsstelle "..name.." gibt es schon."end
if not STATION_KINDS[spec2.kind]then return nil,"Die Art ist personenbahnhof, gueterbahnhof oder depot."end
local site,why_site=site_for(spec2.site)
if not site and not empty_text(spec2.site)then return nil,why_site end
local id=new_id("betriebsstelle","BF")
data.stations[id]={name=name,kind=spec2.kind,site=site,rev=1}
return id
end)
end

function n.set_station(id,fields)
return change(function()
local st=data.stations[id]
if not st then return nil,"Die Betriebsstelle gibt es nicht."end
local old=stale(st,fields.if_rev,"Betriebsstelle")
if old then return nil,old end
if fields.name~=nil then
local name,why=valid_name(fields.name)
if not name then return nil,why end
if station_name_taken(name,id)then return nil,"Eine Betriebsstelle "..name.." gibt es schon."end
st.name=name
end
if fields.kind~=nil then
if not STATION_KINDS[fields.kind]then return nil,"Die Art ist personenbahnhof, gueterbahnhof oder depot."end
st.kind=fields.kind
end
if fields.site~=nil then
local site,why=site_for(fields.site)
if not site and not empty_text(fields.site)then return nil,why end
st.site=site
end
touch(st)
prune_sites()
return true
end)
end

function n.remove_station(id)
return change(function()
local st=data.stations[id]
if not st then return nil,"Die Betriebsstelle gibt es nicht."end
for node_id,node in pairs(data.nodes)do
if node.station==id and node.state~="verworfen"then return nil,"Die Node "..node_id.." nutzt diese Betriebsstelle: erst unter Netz entfernen."end
end
data.stations[id]=nil
prune_sites()
return true
end)
end

local function station_view(id,st)
return{id=id,name=st.name,kind=st.kind,site=st.site,site_name=st.site and data.sites[st.site]and data.sites[st.site].name or nil,rev=st.rev or 0}
end

function n.stations()
local list={}
for id,st in pairs(data.stations)do list[#list+1]=station_view(id,st)end
table.sort(list,function(a,b)return a.id<b.id end)
return list
end

function n.station(id)
local st=data.stations[id]
return st and station_view(id,st)or nil
end

function n.sites()
local list={}
for id,site in pairs(data.sites)do
local c=0
for _,st in pairs(data.stations)do if st.site==id then c=c+1 end end
list[#list+1]={id=id,name=site.name,stations=c}
end
table.sort(list,function(a,b)return a.id<b.id end)
return list
end


local function view(id,node)
return{id=id,claim=node.claim,role=node.role,roles=node.roles and copy(node.roles)or{node.role},station=node.station,legacy=node.legacy,state=node.state,name=node.name,label=node.label}
end

local function claim_roles(spec2)
local list=spec2.roles
if list==nil then list={spec2.role}end
if type(list)~="table"or#list==0 or#list>4 then return nil,"Fuer diese Rolle gibt es keine Anforderung."end
local seen,out={},{}
for _,r in ipairs(list)do
if type(r)~="string"or not ROLE_CODE[r]then return nil,"Fuer diese Rolle gibt es keine Anforderung."end
if seen[r]then return nil,"Die Rolle "..r.." ist doppelt angegeben."end
seen[r]=true
out[#out+1]=r
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
local station_id,where_name,where_code
if#roles==1 and primary=="anmeldung"then
local st=type(spec2.station)=="string"and data.stations[spec2.station]or nil
if not st then return nil,"Die Betriebsstelle gibt es nicht."end
station_id,where_name,where_code=spec2.station,st.name,spec2.station
else
if spec2.station~=nil then return nil,"Nur die Rolle anmeldung allein wird fuer eine Betriebsstelle angefordert."end
end

local legacy=spec2.legacy
if legacy~=nil then
if type(legacy)~="string"or#legacy==0 or#legacy>30 or legacy:find("[^%w_%-]")then return nil,"Die bisherige Node-Kennung ist ungueltig."end
for id,node in pairs(data.nodes)do
if node.legacy==legacy and node.claim~=claim and node.state~="verworfen"then return nil,"Die Node "..legacy.." ist schon als "..id.." im Verzeichnis."end
end
end
local function naming(id)
local name=role_text..(where_name and(" "..where_name)or"").." "..id
local label=id.." | "..code..(where_code and(" | "..where_code)or"")
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
