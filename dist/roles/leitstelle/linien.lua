





local forms=require("ui.forms")
local label=require("core.label")

return function(ctx)
local role=ctx.role
local now=ctx.now
local STATE_TEXT,STATE_KIND=ctx.state_text,ctx.state_kind


local page=forms.page({
id="linien",title="Linien",empty="Noch keine Linie. Eine Linie fuehrt eine Vorlage im Takt aus.",new_label="Neu",
items=function()
local items,records={},{}

local ist_of={}
for _,row in ipairs(role.board())do ist_of[row.line]=row.order end
for i,line in ipairs(role.lines.list())do
local text=line.title.." alle "..line.interval.." s"..(line.priority=="bevorzugt"and" (bevorzugt)"or"")..(line.active and""or" [aus]")

local order=ist_of[line.id]
local detail="in "..math.max(0,math.floor(line.next_due-now())).." s"..(line.missed>0 and(", "..line.missed.." ausgel.")or"")
..", "..(order and(order.train.." "..(STATE_TEXT[order.state]or order.state).." "..math.min(order.leg,order.legs).."/"..order.legs)or"kein Zug")
if line.note then detail=detail..". "..line.note end
items[i]={text=text,detail=detail,kind=line.active and(order and STATE_KIND[order.state]or"text")or"dim"}
records[i]=line
end
return items,records
end,
fields={
{id="id",label="Kennung (z.B. pendel)",max=16,width=24},
{id="title",label="Titel",max=30,width=34},
{id="template",label="Vorlage (Kennung)",max=16,width=24},
{id="trains",label="Zuege (Kennungen mit ; trennen)",max=80,width=48},
{id="interval",label="Takt in Sekunden (Betriebszeit)",max=6,width=12,default="300"},
{id="priority",label="Prioritaet: normal oder bevorzugt",max=10,width=14,default="normal"},
},
edit=function(line)return{id=line.id,title=line.title,template=line.template,trains=table.concat(line.trains,"; "),interval=line.interval,priority=line.priority}end,
on_save=function(values,record)

if record then values.id=record.id
elseif role.lines.get(values.id)then return nil,"Die Linie "..tostring(values.id).." gibt es schon: mit Aendern bearbeiten."end
local trains={}
for part in(values.trains or""):gmatch("[^;]+")do
local id=part:match("^%s*(.-)%s*$")
if id~=""then trains[#trains+1]=id end
end
for _,id in ipairs(trains)do
if not role.register.get(id)then return nil,"Der Zug "..id.." ist nicht angemeldet."end
end
if not role.orders.template(values.template)then return nil,"Die Vorlage "..tostring(values.template).." gibt es nicht."end
return role.lines.set({id=values.id,title=values.title,template=values.template,trains=trains,interval=tonumber(values.interval),priority=values.priority~=""and values.priority or"normal"})
end,
extra={
{id="aus",label="Ein/Aus",run=function(v,line)
line.active=not line.active
role.lines.save()
return line.active and"Linie laeuft."or"Linie angehalten: keine neuen Termine."
end},
{id="loeschen",label="Loeschen",kind="danger",run=function(v,line)local ok,err=role.lines.remove(line.id)return ok and"Linie geloescht (laufende Auftraege bleiben)."or err end},
},
})

return page
end
