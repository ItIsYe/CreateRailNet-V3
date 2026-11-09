





local W=require("ui.widgets")
local label=require("core.label")
local orderslib=require("domain.orders")

return function(ctx)
local role=ctx.role
local samples=ctx.samples
local drive_all=ctx.drive_all
local templates_info=ctx.templates_info
local STATE_TEXT,STATE_KIND=ctx.state_text,ctx.state_kind
local arm={}

local page={
id="vorlagen",title="Vorlagen",
render=function(v,rect)
local state=v.page_state("vorlagen")
state.list=state.list or{index=1}
state.screen=state.screen or"liste"
state.fields=state.fields or{
id={value="",max=16},title={value="",max=30},train={value="",max=16},stops={value="",max=120},
station={value="",max=40},count={value="7",max=6},
}
if state.screen=="liste"then
local items={}
state.templates={}
for i,info in ipairs(templates_info())do
items[#items+1]={text=info.title..(info.priority=="bevorzugt"and" (bevorzugt)"or""),detail=info.active and("Auftrag "..info.active.id..": "..(STATE_TEXT[info.active.state]or info.active.state))or("Zug "..info.train),kind=info.active and"wait"or"dim"}
state.templates[i]=info
end
W.list(v,"vorlagen",rect,items,state.list,{empty="Noch keine Vorlage. Mit 'Neue Vorlage' anlegen."})
elseif state.screen=="neu1"then
W.label(v,rect.x+1,rect.y,(state.edit and"Vorlage aendern"or"Neue Vorlage").." (1/2)","hell")
W.field(v,"id",rect.x+1,rect.y+2,math.min(24,rect.w-2),state.edit and"Kennung (bleibt)"or"Kennung (z.B. weizen)",state.fields.id)
W.field(v,"title",rect.x+1,rect.y+5,math.min(34,rect.w-2),"Titel (z.B. Weizen liefern)",state.fields.title)
elseif state.screen=="neu2"then
W.label(v,rect.x+1,rect.y,(state.edit and"Vorlage aendern"or"Neue Vorlage").." (2/2)","hell")
W.field(v,"train",rect.x+1,rect.y+2,math.min(24,rect.w-2),"Zug (Kennung, angemeldet)",state.fields.train)
W.field(v,"stops",rect.x+1,rect.y+5,rect.w-2,"Halte: Bahnhof:Sekunden:Menge; naechster ...",state.fields.stops)
W.label(v,rect.x+1,rect.y+8,"Beispiel: Weizenhof:5:640; Zentrallager:3","dim",rect.w-2)
W.label(v,rect.x+1,rect.y+9,"Danach faehrt der Zug zum ersten Halt zurueck.","dim",rect.w-2)
elseif state.screen=="muster"then
W.label(v,rect.x+1,rect.y,"Mengenmuster erfassen","hell")
W.label(v,rect.x+1,rect.y+1,"Lege in Create am Bahnhof einen Fahrplan mit einer Fracht-","dim",rect.w-2)
W.label(v,rect.x+1,rect.y+2,"bedingung (Gegenstand, Menge) an, z.B. Weizen, Menge 7.","dim",rect.w-2)
W.field(v,"station",rect.x+1,rect.y+4,math.min(34,rect.w-2),"Bahnhof, an dem der Zug steht (Create-Name)",state.fields.station)
W.field(v,"count",rect.x+1,rect.y+7,10,"Die Zahl, die du eingestellt hast",state.fields.count)
if role.sample_status then W.label(v,rect.x+1,rect.y+10,role.sample_status.text,role.sample_status.kind,rect.w-2)end
if samples.item_threshold and not role.sample_status then W.label(v,rect.x+1,rect.y+10,"Ein Muster ist gespeichert.","ok",rect.w-2)end
end
end,
actions=function(v)
local state=v.page_state("vorlagen")
local screen=state.screen or"liste"
if screen=="liste"then
local info=state.templates and state.templates[(state.list or{index=1}).index]
return{
{id="anfordern",label="Anfordern",enabled=info~=nil,reason="Erst eine Vorlage waehlen."},
{id="neu",label="Neu",kind="secondary"},
{id="vl_aendern",label="Aendern",kind="secondary",enabled=info~=nil,reason="Erst eine Vorlage waehlen."},
{id="prio",label="Prio",kind="secondary",enabled=info~=nil,reason="Erst eine Vorlage waehlen."},
{id="muster",label="Muster",kind="secondary"},
{id="vl_loeschen",label=arm.template==(info and info.id)and info~=nil and"Wirklich?"or"Loeschen",kind="danger",enabled=info~=nil,reason="Erst eine Vorlage waehlen."},
}
elseif screen=="muster"then
return{{id="lesen",label="Fahrplan lesen",side="rechts"},{id="vl_zurueck",label="Fertig",kind="secondary",side="rechts"}}
end
return{
{id=screen=="neu2"and"vl_speichern"or"vl_weiter",label=screen=="neu2"and"Speichern"or"Weiter",side="rechts"},
{id="vl_zurueck",label="Zurueck",kind="secondary",side="rechts"},
}
end,
on_action=function(v,id)
local state=v.page_state("vorlagen")
local f=state.fields
if id=="act:anfordern"then
local info=state.templates and state.templates[state.list.index]
if not info then return true end
local order,new=role.demand(info.id,nil)
v.hint=order and((new and"Auftrag "or"Laeuft schon: ")..order.id)or tostring(new)
drive_all()
return true
elseif id=="act:neu"then
f.id.value,f.title.value,f.train.value,f.stops.value="","","",""
state.edit=nil
state.screen="neu1"
return true
elseif id=="act:vl_aendern"then
local info=state.templates and state.templates[state.list.index]
if not info then return true end
local template=role.orders.template(info.id)
if not template then return true end
f.id.value,f.title.value,f.train.value=template.id,template.title,template.train
f.stops.value=orderslib.format_stops(template.stops)
state.edit=info.id
state.screen="neu1"
return true
elseif id=="act:prio"then
local info=state.templates and state.templates[state.list.index]
if info then
local ok,err=role.orders.set_priority(info.id,info.priority=="bevorzugt"and"normal"or"bevorzugt")
v.hint=ok and("Prioritaet: "..(info.priority=="bevorzugt"and"normal"or"bevorzugt"))or err
end
return true
elseif id=="act:vl_loeschen"then
local info=state.templates and state.templates[state.list.index]
if not info then return true end
if arm.template~=info.id then
arm.template=info.id
v.hint="Nochmal druecken: Vorlage "..info.title.." loeschen."
else
arm.template=nil
local ok,err=role.remove_template(info.id)
v.hint=ok and("Vorlage "..info.title.." geloescht.")or err
end
return true
elseif id=="act:muster"then
role.sample_status=nil
state.screen="muster"
return true
elseif id=="act:lesen"then
local ok,why=role.read_sample(f.station.value,f.count.value)
if not ok then v.hint=why end
return true
elseif id=="act:vl_weiter"then
if f.id.value==""or f.title.value==""then v.hint="Kennung und Titel sind noetig."return true end
state.screen="neu2"
return true
elseif id=="act:vl_zurueck"then
if state.screen~="neu2"then state.edit=nil end
state.screen=(state.screen=="neu2")and"neu1"or"liste"
return true
elseif id=="act:vl_speichern"then
local ok,err=role.create_template({id=state.edit or f.id.value,title=f.title.value,train=f.train.value,stops=f.stops.value},{replace=state.edit~=nil})
if ok then
v.hint="Vorlage gespeichert."
state.edit=nil
state.screen="liste"
else
v.hint=err
end
return true
end
end,
}

return page
end
