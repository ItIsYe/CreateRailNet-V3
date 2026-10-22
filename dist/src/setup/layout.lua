























local json=require("src.shared.json")

local layout={}

layout.STATION_TYPES={passenger=true,freight=true,mixed=true}
layout.KINDS={passenger=true,freight=true,mixed=true,depot=true}
layout.MAX_BLOCKS=20
layout.MAX_BERTHS=6
local MAX_TEXT=60000
local MAX_ERRORS=20
local MAX_NAME=40
local SIDES={left=true,right=true,front=true,back=true,top=true,bottom=true}

local TYPE_WORDS={passenger="passenger",personen="passenger",freight="freight",fracht="freight",mixed="mixed",gemischt="mixed"}
local KIND_WORDS={passenger="passenger",personen="passenger",freight="freight",fracht="freight",mixed="mixed",gemischt="mixed",depot="depot"}
local ONEWAY_WORDS={einrichtung=true,eingleisig=true,oneway=true}
local KEYWORDS="netz, kanal, master, bahnhof, depot, strecke, zug, panel, standard"



local function collector()
local list,extra={},0
return{
add=function(loc,text)
if#list<MAX_ERRORS then list[#list+1]=(loc and(loc .. ": ")or "").. text else extra=extra+1 end
end,
list=function()
if extra>0 then list[#list+1]="... und " .. extra .. " weitere Fehler" end
return list
end,
count=function()return#list+extra end,
}
end

local function whole(value,low,high)
return type(value)=="number" and value==math.floor(value)and value>=low and value<=high
end

local function has_non_ascii(text)return text:find("[\128-\255]")~=nil end

local function check_id(errors,loc,value,what)
if type(value)~="string" or value=="" then errors.add(loc,what .. " braucht eine ID");return false end
if has_non_ascii(value)then errors.add(loc,"in der ID '" .. value .. "' stehen Umlaute oder Sonderzeichen (ae, oe, ue, ss schreiben)");return false end
if#value>20 or not value:match("^[%w_%-%.]+$")then errors.add(loc,"die ID '" .. value .. "' darf nur Buchstaben, Ziffern und _ - . enthalten und hoechstens 20 Zeichen lang sein");return false end
return true
end




local function tokenize(line)
local tokens,i,n={},1,#line
while i<=n do
local c=line:sub(i,i)
if c==" " or c=="\t" or c=="\r" then
i=i+1
elseif c=="#" then
break
elseif c=='"' then
local close=line:find('"',i+1,true)
if not close then return nil,"ein Anfuehrungszeichen wird nicht geschlossen" end
tokens[#tokens+1]={text=line:sub(i+1,close - 1),quoted=true}
i=close+1
else
local j=i
while j<=n and not line:sub(j,j):match("[ \t\r#]")do j=j+1 end
tokens[#tokens+1]={text=line:sub(i,j - 1),quoted=false}
i=j
end
end
return tokens
end

local function new_raw()
return{stations={},depots={},lines={},trains={},defaults={}}
end

local function parse_stop(token)
local id,platform=token:match("^(.-):(%d+)$")
if id and id~="" then return{id=id,platform=tonumber(platform)}end
return{id=token}
end


local function statement(raw,errors,loc,tokens)
local word=tokens[1].text:lower()
local rest={}
for i=2,#tokens do rest[#rest+1]=tokens[i] end

if word=="netz" then
local parts={}
for _,t in ipairs(rest)do parts[#parts+1]=t.text end
raw.name=table.concat(parts," ")
elseif word=="kanal" then
local value=rest[1] and tonumber(rest[1].text)
if not whole(value,1,65535)then errors.add(loc,"Der Kanal (kanal) muss eine ganze Zahl von 1 bis 65535 sein (kanal 777)")else raw.channel=value end
elseif word=="master" then
if not rest[1] then errors.add(loc,"master braucht eine ID (master MASTER-1)")
elseif check_id(errors,loc,rest[1].text,"master")then raw.master_id=rest[1].text end
elseif word=="panel" then
local value=rest[1] and rest[1].text:lower()
if value=="ja" or value=="an" or value=="true" then raw.panel=true
elseif value=="nein" or value=="aus" or value=="false" then raw.panel=false
else errors.add(loc,"panel braucht ja oder nein (panel ja)")end
elseif word=="bahnhof" or word=="depot" then
if not rest[1] then errors.add(loc,word .. " braucht eine ID (" .. word .. ' ST-A "Name")');return end
local item={id=rest[1].text,loc=loc}
for i=2,#rest do
local t=rest[i]
local number=(not t.quoted)and t.text:match("^%d+$")and tonumber(t.text)or nil
if number then
if word=="bahnhof" then item.platforms=number else item.tracks=number end
elseif(not t.quoted)and word=="bahnhof" and TYPE_WORDS[t.text:lower()] then
if item.type then errors.add(loc,"bahnhof hat nur einen Typ (passenger, freight oder mixed)")else item.type=TYPE_WORDS[t.text:lower()] end
elseif t.quoted or not item.name then
item.name=t.text
else
errors.add(loc,"'" .. t.text .. "' ist unbekannt (Name in Anfuehrungszeichen, Zahl, Typ)")
end
end
local list=word=="bahnhof" and raw.stations or raw.depots
list[#list+1]=item
elseif word=="strecke" then
if not(rest[1] and rest[2])then errors.add(loc,"strecke braucht zwei Bahnhoefe (strecke ST-A ST-B 2)");return end
local item={from=rest[1].text,to=rest[2].text,loc=loc,oneway=false}
for i=3,#rest do
local t=rest[i]
local text=t.text:lower()
if t.text:match("^%d+$")then item.blocks=tonumber(t.text)
elseif KIND_WORDS[text] then
if item.kind then errors.add(loc,"strecke hat nur eine Art (passenger, freight, mixed oder depot)")else item.kind=KIND_WORDS[text] end
elseif ONEWAY_WORDS[text] then item.oneway=true
else errors.add(loc,"'" .. t.text .. "' ist bei strecke unbekannt (Bloecke, Art, einrichtung)")end
end
raw.lines[#raw.lines+1]=item
elseif word=="zug" then
if not rest[1] then errors.add(loc,"zug braucht eine ID (zug TRAIN-1 ST-A ST-B)");return end
local item={id=rest[1].text,stops={},loc=loc}
local index=2
if rest[2] and rest[2].quoted then item.name=rest[2].text;index=3 end
for i=index,#rest do
local text=rest[i].text
local lowered=text:lower()
local pause=lowered:match("^pause=(.*)$")
if pause then
item.dwell=tonumber(pause)
if not whole(item.dwell,0,3600)then errors.add(loc,"pause=" .. pause .. " ist keine Zahl von 0 bis 3600 Sekunden");item.dwell=nil end
elseif lowered=="wiederholen" then item.repeat_=true
elseif lowered=="einmalig" then item.repeat_=false
else item.stops[#item.stops+1]=parse_stop(text)end
end
raw.trains[#raw.trains+1]=item
elseif word=="standard" then
local what=rest[1] and rest[1].text:lower()
local key=({signal="signal",melder="sensor",sensor="sensor",weiche="switch",switch="switch"})[what or ""]
local adapter=rest[2] and rest[2].text:lower()
local value=rest[3] and rest[3].text
if not key or(adapter~="redstone" and adapter~="peripheral")or not value then
errors.add(loc,"standard braucht Signal/Melder/Weiche und redstone <Seite> oder peripheral <Name> (standard weiche redstone back)")
return
end
if adapter=="redstone" then
if not SIDES[value] then errors.add(loc,"die Seite '" .. value .. "' gibt es nicht (left right front back top bottom)");return end
raw.defaults[key]={adapter="redstone",side=value}
else
raw.defaults[key]={adapter="peripheral",peripheral=value}
end
else
errors.add(loc,"'" .. tokens[1].text .. "' kenne ich nicht (moeglich: " .. KEYWORDS .. ")")
end
end

local function raw_from_text(text,errors)
local raw=new_raw()
local number=0
for line in(text .. "\n"):gmatch("([^\n]*)\n")do
number=number+1
local loc="Zeile " .. number
local tokens,problem=tokenize(line)
if not tokens then errors.add(loc,problem)
elseif#tokens>0 then statement(raw,errors,loc,tokens)end
end
return raw
end



local function list_of(errors,value,name,fn)
if value==nil then return{}end
if type(value)~="table" or(next(value)~=nil and value[1]==nil)then
errors.add(nil,name .. " muss eine Liste sein")
return{}
end
local out={}
for i,item in ipairs(value)do
local loc=name .. "[" .. i .. "]"
if type(item)~="table" then errors.add(loc,"muss ein Objekt sein")else out[#out+1]=fn(item,loc)end
end
return out
end

local function raw_from_json(text,errors)
local ok,value=pcall(json.decode,text)
if not ok or type(value)~="table" then errors.add(nil,"Das ist keine gueltige JSON-Beschreibung");return nil end
if value[1]~=nil then errors.add(nil,"Die JSON-Beschreibung muss ein Objekt sein, keine Liste");return nil end
local raw=new_raw()
raw.name,raw.channel,raw.master_id,raw.panel=value.name,value.channel,value.master_id,value.panel
raw.stations=list_of(errors,value.stations,"stations",function(s,loc)return{id=s.id,name=s.name,type=s.type,platforms=s.platforms,loc=loc}end)
raw.depots=list_of(errors,value.depots,"depots",function(d,loc)return{id=d.id,name=d.name,tracks=d.tracks,loc=loc}end)
raw.lines=list_of(errors,value.lines,"lines",function(l,loc)return{from=l.from,to=l.to,blocks=l.blocks,kind=l.kind,oneway=l.oneway==true,loc=loc,json=true}end)
raw.trains=list_of(errors,value.trains,"trains",function(t,loc)
local stops={}
if type(t.stops)=="table" then
for _,stop in ipairs(t.stops)do
if type(stop)=="string" then stops[#stops+1]=parse_stop(stop)
elseif type(stop)=="table" then stops[#stops+1]={id=stop.id,platform=stop.platform}
else stops[#stops+1]={id=tostring(stop)}end
end
elseif t.stops~=nil then errors.add(loc,"stops muss eine Liste sein")end
return{id=t.id,name=t.name,stops=stops,dwell=t.dwell,repeat_=t["repeat"],loc=loc}
end)
if type(value.defaults)=="table" then raw.defaults=value.defaults end
return raw
end



local function check_name(errors,loc,value,fallback)
if value==nil then return fallback end
if type(value)~="string" then errors.add(loc,"der Name (name) muss Text sein");return fallback end
if has_non_ascii(value)then errors.add(loc,"im Namen '" .. value .. "' stehen Umlaute oder Sonderzeichen (ae, oe, ue, ss schreiben)");return fallback end
if#value>MAX_NAME then errors.add(loc,"Der Name darf hoechstens " .. MAX_NAME .. " Zeichen haben");return fallback end
return value
end

local function check_count(errors,loc,value,high,one,many,key)
if value==nil then return 1 end
if not whole(value,1,high)then
errors.add(loc,many .. " (" .. key .. ") muessen eine ganze Zahl von 1 bis " .. high .. " sein. Hoechstens " .. high .. " " .. many)
return 1
end
return value
end

local function default_kind(a,b,a_depot,b_depot)
if a_depot or b_depot then return "depot" end
if a=="freight" and b=="freight" then return "freight" end
if a=="passenger" and b=="passenger" then return "passenger" end
return "mixed"
end

local function finish(raw,errors)
local result={
given={channel=raw.channel~=nil,master_id=raw.master_id~=nil},
name="",channel=777,master_id="MASTER-1",panel=true,
stations={},depots={},lines={},trains={},
defaults={
signal={adapter="peripheral",peripheral="Create_Signal_0"},
sensor={adapter="peripheral",peripheral="Create_TrainObserver_0"},
switch={adapter="redstone",side="back"},
},
}
if raw.name~=nil then
if type(raw.name)~="string" then errors.add(nil,"name muss Text sein")else result.name=check_name(errors,nil,raw.name,"")end
end
if raw.channel~=nil then
if not whole(raw.channel,1,65535)then errors.add(nil,"Der Kanal (kanal) muss eine ganze Zahl von 1 bis 65535 sein, nicht '" .. tostring(raw.channel).. "'")else result.channel=raw.channel end
end
if raw.master_id~=nil and check_id(errors,nil,raw.master_id,"master")then result.master_id=raw.master_id end
if raw.panel~=nil then
if type(raw.panel)~="boolean" then errors.add(nil,"panel muss ja oder nein sein")else result.panel=raw.panel end
end
for key,value in pairs(raw.defaults or{})do
if result.defaults[key] and type(value)=="table" and(value.adapter=="redstone" or value.adapter=="peripheral")then
if value.adapter=="redstone" and SIDES[value.side] then result.defaults[key]={adapter="redstone",side=value.side}
elseif value.adapter=="peripheral" and type(value.peripheral)=="string" and value.peripheral~="" then result.defaults[key]={adapter="peripheral",peripheral=value.peripheral}end
end
end

local ends,seen_line={},{}
local function claim(item,kind,loc)
if ends[item.id] then errors.add(loc,"die ID " .. item.id .. " gibt es doppelt (" .. ends[item.id].loc .. ")");return false end
ends[item.id]={kind=kind,loc=loc}
return true
end

for _,s in ipairs(raw.stations)do
local loc=s.loc
if check_id(errors,loc,s.id,"bahnhof")and claim(s,"station",loc)then
local stype=s.type or "passenger"
if not layout.STATION_TYPES[stype] then errors.add(loc,"der Typ '" .. tostring(stype).. "' gibt es nicht (passenger, freight, mixed)");stype="passenger" end
local entry={id=s.id,name=check_name(errors,loc,s.name,s.id),type=stype,
platforms=check_count(errors,loc,s.platforms,layout.MAX_BERTHS,"Bahnsteig","Bahnsteige","platforms")}
ends[s.id].item=entry
result.stations[#result.stations+1]=entry
end
end
for _,d in ipairs(raw.depots)do
local loc=d.loc
if check_id(errors,loc,d.id,"depot")and claim(d,"depot",loc)then
local entry={id=d.id,name=check_name(errors,loc,d.name,d.id),
tracks=check_count(errors,loc,d.tracks,layout.MAX_BERTHS,"Gleis","Gleise","tracks")}
ends[d.id].item=entry
result.depots[#result.depots+1]=entry
end
end

for _,l in ipairs(raw.lines)do
local loc=l.loc
local a,b=ends[l.from],ends[l.to]
local ok=true
if type(l.from)~="string" or not a then errors.add(loc,"der Bahnhof " .. tostring(l.from).. " ist nicht beschrieben (bahnhof oder depot davor eintragen)");ok=false end
if type(l.to)~="string" or not b then errors.add(loc,"der Bahnhof " .. tostring(l.to).. " ist nicht beschrieben (bahnhof oder depot davor eintragen)");ok=false end
if ok and l.from==l.to then errors.add(loc,"eine Strecke braucht zwei verschiedene Enden, nicht zweimal " .. l.from .. " (die selben)");ok=false end
local blocks=l.blocks
if blocks==nil then blocks=1 elseif not whole(blocks,1,layout.MAX_BLOCKS)then
errors.add(loc,"Bloecke (blocks) muessen eine ganze Zahl von 1 bis " .. layout.MAX_BLOCKS .. " sein, nicht '" .. tostring(blocks).. "'. Hoechstens " .. layout.MAX_BLOCKS .. " Bloecke")
ok=false
end
local kind=l.kind
if kind~=nil and not layout.KINDS[kind] then errors.add(loc,"die Art '" .. tostring(kind).. "' gibt es nicht (passenger, freight, mixed, depot)");ok=false end
if ok then
local key=l.from .. ">" .. l.to
if seen_line[key] then errors.add(loc,"die Strecke " .. l.from .. " -> " .. l.to .. " gibt es schon (" .. seen_line[key] .. ")");ok=false end
seen_line[key]=loc
end
if ok then
kind=kind or default_kind(a.item and a.item.type,b.item and b.item.type,a.kind=="depot",b.kind=="depot")
result.lines[#result.lines+1]={from=l.from,to=l.to,blocks=blocks,kind=kind,oneway=l.oneway==true}
if not l.oneway then seen_line[l.to .. ">" .. l.from]=seen_line[l.to .. ">" .. l.from] or loc end
end
end


local drivable={}
for _,l in ipairs(result.lines)do
drivable[l.from .. ">" .. l.to]=true
if not l.oneway then drivable[l.to .. ">" .. l.from]=true end
end
local train_ids={}
for _,t in ipairs(raw.trains)do
local loc=t.loc
local ok=check_id(errors,loc,t.id,"zug")
if ok and(ends[t.id] or train_ids[t.id])then errors.add(loc,"die ID " .. t.id .. " gibt es doppelt (" ..(ends[t.id] and ends[t.id].loc or train_ids[t.id]).. ")");ok=false end
if ok then train_ids[t.id]=loc end
local stops={}
if ok and#t.stops<2 then errors.add(loc,"ein Zug braucht mindestens zwei Halte (zug " .. t.id .. " ST-A ST-B)");ok=false end
if ok then
for _,stop in ipairs(t.stops)do
local target=type(stop.id)=="string" and ends[stop.id] or nil
if not target then errors.add(loc,"der Halt " .. tostring(stop.id).. " ist nicht beschrieben");ok=false
else
local berths=target.item and(target.item.platforms or target.item.tracks)or 1
local platform=stop.platform or 1
if not whole(platform,1,berths)then
errors.add(loc,stop.id .. " hat nur " .. berths ..(target.kind=="station" and " Bahnsteig(e)" or " Gleis(e)").. ", nicht " ..(target.kind=="station" and "Bahnsteig " or "Gleis ").. tostring(stop.platform))
ok=false
end
stops[#stops+1]={id=stop.id,platform=platform}
end
end
end
if ok then
for i=1,#stops - 1 do
local a,b=stops[i].id,stops[i+1].id
if a==b then errors.add(loc,a .. " steht zweimal nacheinander als Halt");ok=false
elseif not drivable[a .. ">" .. b] then
if drivable[b .. ">" .. a] then errors.add(loc,"die Strecke " .. b .. " -> " .. a .. " ist nur in der Richtung " .. b .. " -> " .. a .. " befahrbar, nicht " .. a .. " -> " .. b .. " (Richtung)")
else errors.add(loc,"es gibt keine Strecke von " .. a .. " nach " .. b .. " (strecke " .. a .. " " .. b .. "), nehmt dazwischen den Halt mit auf")end
ok=false
end
end
end
local dwell=t.dwell
if dwell~=nil and not whole(dwell,0,3600)then errors.add(loc,"pause muss eine ganze Zahl von 0 bis 3600 Sekunden sein");ok=false end
if ok then
local repeat_=t.repeat_
if repeat_==nil then repeat_=stops[1].id==stops[#stops].id end
result.trains[#result.trains+1]={id=t.id,name=check_name(errors,loc,t.name,t.id),stops=stops,dwell=dwell or 10,repeat_plan=repeat_==true}
end
end

if#result.stations+#result.depots==0 then
errors.add(nil,"Es fehlt mindestens ein Bahnhof (bahnhof ST-A \"Station A\" passenger)")
elseif#result.lines==0 and errors.count()==0 then
errors.add(nil,"Es fehlt eine Strecke zwischen zwei Bahnhoefen (strecke ST-A ST-B 2)")
end
return result
end


layout.EXAMPLE=[=[
# Beschreibung eines Netzes: jede Zeile eine Angabe, # beginnt einen Kommentar.
netz Mein erstes Netz
bahnhof ST-A "Station A" passenger
bahnhof ST-B "Station B" passenger 2
depot DEPOT-1 "Depot 1"
# Strecke: von nach Anzahl-Bloecke; ohne "einrichtung" in beide Richtungen
strecke ST-A ST-B 2
strecke ST-B DEPOT-1 1 depot
# Zug: ID "Name" und die Halte; ST-B:2 = Bahnsteig 2; pause=Sekunden am Halt
zug TRAIN-1 "Regio 1" ST-A ST-B:1 ST-A pause=15
]=]



function layout.parse(text)
if type(text)~="string" or text:match("^%s*$")then return nil,{"Die Beschreibung ist leer."}end
if#text>MAX_TEXT then return nil,{"Die Beschreibung ist zu gross (hoechstens " .. MAX_TEXT .. " Zeichen)."}end
local errors=collector()
local first=text:match("^%s*(%S)")
local raw
if first=="{" or first=="[" then raw=raw_from_json(text,errors)else raw=raw_from_text(text,errors)end
if not raw then return nil,errors.list()end
local result=finish(raw,errors)
if errors.count()>0 then return nil,errors.list()end
return result
end

return layout
