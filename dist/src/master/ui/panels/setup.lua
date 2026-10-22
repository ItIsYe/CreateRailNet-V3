




















local ui_utils=require("src.master.ui.ui_utils")
local time=require("src.shared.time")

local setup_panel={}

local LAST_LIST_ROW=13
local ACTION_ROW=14
local BUTTON_ROW=15
local CONFIRM_S=8
local MESSAGE_S=12

local MESSAGE_ROWS=3


local function wrap(text,width,rows)
local lines,line={},""
for word in tostring(text):gmatch("%S+")do
while#word>width do
if line~="" then lines[#lines+1]=line;line="" end
lines[#lines+1]=word:sub(1,width)
word=word:sub(width+1)
end
if line=="" then line=word
elseif#line+1+#word<=width then line=line .. " " .. word
else lines[#lines+1]=line;line=word end
end
if line~="" then lines[#lines+1]=line end
if#lines>rows then
local kept={}
for i=1,rows do kept[i]=lines[i] end
local last=kept[rows]
kept[rows]=(#last>width - 3 and last:sub(1,width - 3)or last).. "..."
return kept
end
return lines
end

local ROLE_WORD={
master="Master",signal="Signal",sensor="Melder",switch="Weiche",station="Bahnhof",depot="Depot",train="Zug",panel="Monitor",
}

function setup_panel.new(sources)
local src=sources or{}
local panel={page=1}
local C=ui_utils.colors
local now=src.now_s or time.now_s
local selected,confirming,message=nil,nil,nil
local confirming_action=nil
local rows={}
local action_zones={}
local first_row,list_rows=10,4
local height,width=19,51
local pages=1

local function plan_nodes()
local list={}
local master_id=src.config and src.config.master_id
for _,node in ipairs((src.config and src.config.nodes)or{})do
if node.id and node.id~=master_id and node.role~="master" then list[#list+1]=node end
end
return list
end


function panel.model()
local lines={}
local blocks,routes=#((src.config and src.config.blocks)or{}),#((src.config and src.config.routes)or{})
if blocks==0 or routes==0 then
lines[#lines+1]={word="OFFEN",text="Netzplan: noch keine Bloecke oder Routen"}
else
lines[#lines+1]={word="OK",text="Netzplan: " .. blocks .. " Block/Bloecke, " .. routes .. " Route(n)"}
end

local nodes=plan_nodes()
local registry=src.registry and src.registry.all and src.registry.all()or{}
local offline={}
for _,node in ipairs(nodes)do
local entry=registry[node.id]
if not(entry and tostring(entry.status):upper()=="UP")then offline[#offline+1]=node.id end
end
table.sort(offline)
if#nodes==0 then
lines[#lines+1]={word="OFFEN",text="Computer: noch keiner im Netzplan"}
elseif#offline==0 then
lines[#lines+1]={word="OK",text="Computer online: " ..#nodes .. " von " ..#nodes}
else
local names=table.concat(offline,", ",1,math.min(2,#offline))..(#offline>2 and ", ..." or "")
lines[#lines+1]={word="FEHLER",text="Computer offline: " ..#offline .. " von " ..#nodes .. " (" .. names .. ")"}
end

local clean,open,unknown=0,0,0
for _,node in ipairs(nodes)do
local setup=src.pairing and src.pairing.setup_of and src.pairing.setup_of(node.id)
if not setup then unknown=unknown+1
elseif setup.state=="GEPRUEFT" then clean=clean+1
else open=open+1 end
end
if#nodes==0 then
lines[#lines+1]={word="OFFEN",text="Selbsttest: nichts zu pruefen"}
elseif open>0 then
lines[#lines+1]={word="FEHLER",text="Selbsttest: " .. open .. " Computer mit offener Pruefung"}
elseif unknown>0 then
lines[#lines+1]={word="OFFEN",text="Selbsttest: " .. unknown .. " Computer ohne Pruefprotokoll"}
else
lines[#lines+1]={word="OK",text="Selbsttest: alle " .. clean .. " Computer lokal geprueft"}
end


local tested,failed_hw=0,0
for _,node in ipairs(nodes)do
local setup=src.pairing and src.pairing.setup_of and src.pairing.setup_of(node.id)
if setup and setup.hw=="ok" then tested=tested+1 elseif setup and setup.hw=="fail" then failed_hw=failed_hw+1 end
end
if#nodes==0 then
lines[#lines+1]={word="OFFEN",text="Hardwaretest: nichts zu testen"}
elseif failed_hw>0 then
lines[#lines+1]={word="FEHLER",text="Hardwaretest: " .. failed_hw .. " Computer mit Fehler"}
elseif tested==#nodes then
lines[#lines+1]={word="OK",text="Hardwaretest: alle " .. tested .. " Computer getestet"}
else
lines[#lines+1]={word="OFFEN",text="Hardwaretest: " .. tested .. " von " ..#nodes .. " Computern getestet"}
end

local waiting=src.pairing and src.pairing.count and src.pairing.count()or 0
if waiting>0 then
lines[#lines+1]={word="OFFEN",text="Neue Computer: " .. waiting .. " warten auf Annahme"}
else
lines[#lines+1]={word="OK",text="Neue Computer: keiner wartet"}
end
local release=src.release and src.release()or nil
if release and release.required then
if release.released then lines[#lines+1]={word="OK",text="Betrieb: freigegeben"}
else lines[#lines+1]={word="OFFEN",text="Betrieb: nicht freigegeben (verlangt)"}end
end
return{lines=lines,nodes=#nodes,offline=#offline}
end

local function candidates()
return(src.pairing and src.pairing.list and src.pairing.list())or{}
end

local function find(list,id)
for _,candidate in ipairs(list)do if candidate.id==id then return candidate end end
return nil
end

local function detail(candidate)
local entry=candidate.entry or{}
local bits={(ROLE_WORD[candidate.role] or tostring(candidate.role))}
if entry.adapter=="redstone" then bits[#bits+1]="Redstone " .. tostring(entry.side)
elseif entry.peripheral then bits[#bits+1]=tostring(entry.peripheral)
elseif entry.create_station_name then bits[#bits+1]=tostring(entry.create_station_name)
elseif entry.display_name then bits[#bits+1]=tostring(entry.display_name)end
if candidate.setup and candidate.setup.state then bits[#bits+1]=candidate.setup.state=="GEPRUEFT" and "Selbsttest ok" or "Selbsttest offen" end
return table.concat(bits,", ")
end

local WORD_COLOR={OK=C.lime,OFFEN=C.yellow,FEHLER=C.red}


local function actions()
local list={}
if src.restart_needed and src.restart and src.restart_needed()then
list[#list+1]={
key="restart",x=1,label="[MASTER NEU STARTEN]",sure="[SICHER? SIGNALE ROT]",
ask=function()
local busy=src.busy_blocks and src.busy_blocks()or 0
return "Neustart: Signale gehen auf ROT, der Wiederanlauf muss bestaetigt werden." ..(busy>0 and(" ACHTUNG: " .. busy .. " Bloecke belegt!")or "")
.. " Nochmal tippen zum Bestaetigen."
end,
run=function()return src.restart("MASTER-UI")end,
}
end
local release=src.release and src.release()or nil
if release and release.required and not release.released and src.release_now then
list[#list+1]={
key="release",label="[BETRIEB FREIGEBEN]",sure="[SICHER? FREIGEBEN]",
ask=function()return "Freigabe: Zuege duerfen ab jetzt Fahrten anfordern. Alle Computer muessen laufen, kein Block gestoert sein. Nochmal tippen zum Bestaetigen." end,
run=function()return src.release_now("MASTER-UI")end,
}
end
return list
end

local function action_width(action)return math.max(#action.label,#action.sure)end

function panel.draw(monitor)
if not monitor then return end
local u=ui_utils.new(monitor)
local w,h=u.size()
width,height=w,h
local t=now()
if message and t - message.at>MESSAGE_S then message=nil end
if confirming and t - confirming.at>CONFIRM_S then confirming=nil end
if confirming_action and t - confirming_action.at>CONFIRM_S then confirming_action=nil end
u.clear(C.black)
u.header(1,"EINRICHTUNG",src.config and("Kanal " .. tostring(src.config.channel))or nil,w)

local function put(x,y,text,color)u.write_at(x,y,text:sub(1,math.max(0,w - x+1)),color)end

local model=panel.model()
for index,line in ipairs(model.lines)do
local row=2+index
local tag=string.format("%-6s ",line.word)
put(1,row,tag,WORD_COLOR[line.word] or C.white)
put(8,row,line.text:sub(1,w - 8),line.word=="OK" and C.lightGray or C.white)
end


local heading_row=3+#model.lines+1
first_row=heading_row+1
list_rows=math.max(2,LAST_LIST_ROW - first_row+1)
local list=candidates()
local waiting=#list
put(1,heading_row,string.format("WARTENDE COMPUTER (%d)",waiting),C.cyan)
pages=math.max(1,math.ceil(waiting/list_rows))
if panel.page>pages then panel.page=pages end
rows={}
if waiting==0 then
put(2,first_row,"Keine. Neue Computer melden sich nach der",C.lightGray)
put(2,first_row+1,"Einrichtung hier von selbst.",C.lightGray)
end
if selected and not find(list,selected)then selected=nil end
local first=(panel.page - 1)*list_rows+1
for i=first,math.min(waiting,first+list_rows - 1)do
local candidate=list[i]
local row=first_row+(i - first)
rows[row]=candidate.id
local marker=candidate.id==selected and ">" or " "
local color=candidate.state=="conflict" and C.red or(candidate.id==selected and C.white or C.yellow)
local text=string.format("%s %-10s %s",marker,candidate.id:sub(1,10),detail(candidate))
if candidate.state=="conflict" then text=string.format("%s %-10s Rolle passt nicht zum Netzplan",marker,candidate.id:sub(1,10))end
put(1,row,text:sub(1,w),color)
end


action_zones={}
local x=1
for _,action in ipairs(actions())do
local asking=confirming_action and confirming_action.key==action.key
put(x,ACTION_ROW,asking and action.sure or action.label,asking and C.orange or C.cyan)
action_zones[#action_zones+1]={from=x,to=x+action_width(action)- 1,action=action}
x=x+action_width(action)+2
end

local chosen=selected and find(list,selected)
if chosen then
local accept_label=(confirming and confirming.id==chosen.id)and "[SICHER?]" or "[ANNEHMEN]"
if chosen.state~="conflict" then put(1,BUTTON_ROW,accept_label,(confirming and C.orange)or C.lime)end
put(12,BUTTON_ROW,"[ABLEHNEN]",C.red)
elseif waiting>0 then
put(1,BUTTON_ROW,"Zeile antippen, dann annehmen oder ablehnen.",C.lightGray)
end
if message then

local lines=wrap(message.text,w,MESSAGE_ROWS)
local color=message.warn and C.yellow or(message.ok and C.lime or C.red)
for i,line in ipairs(lines)do put(1,h - MESSAGE_ROWS+i - 1,line,color)end
end
u.footer(h,string.format("<  Seite %d/%d  >",panel.page,pages),w)
end

function panel.touch(x,y)
local list=candidates()
if y==height then
if x<=math.floor(width/2)then panel.page=math.max(1,panel.page - 1)else panel.page=math.min(pages,panel.page+1)end
return
end
if y==ACTION_ROW then
for _,zone in ipairs(action_zones)do
if x>=zone.from and x<=zone.to then
local action=zone.action
if confirming_action and confirming_action.key==action.key and now()- confirming_action.at<=CONFIRM_S then
confirming_action=nil
local ok,text=action.run()
message={text=text or(ok and "Erledigt." or "Fehlgeschlagen."),ok=ok,at=now()}
else
confirming_action={key=action.key,at=now()}
message={text=action.ask(),warn=true,at=now()}
end
return
end
end
confirming_action=nil
return
end
local id=rows[y]
if id then
selected=id
confirming=nil
confirming_action=nil
return
end
local chosen=selected and find(list,selected)
if y==BUTTON_ROW and chosen and src.decide then
if x<=10 and chosen.state~="conflict" then
if confirming and confirming.id==chosen.id and now()- confirming.at<=CONFIRM_S then
local ok,text=src.decide("accept",chosen.id,"MASTER-UI")
message={text=text or(ok and "Angenommen." or "Fehlgeschlagen."),ok=ok,at=now()}
confirming=nil
if ok then selected=nil end
else
confirming={id=chosen.id,at=now()}
end
elseif x>=12 and x<=21 then
local ok,text=src.decide("reject",chosen.id,"MASTER-UI")
message={text=text or(ok and "Abgelehnt." or "Fehlgeschlagen."),ok=ok,at=now()}
confirming=nil
selected=nil
end
end
end

return panel
end

return setup_panel
