





local W=require("ui.widgets")
local label=require("core.label")

return function(ctx)
local role=ctx.role
local flags=ctx.flags
local drive_all=ctx.drive_all
local STATE_TEXT,STATE_KIND=ctx.state_text,ctx.state_kind
local arm={}

local page={
id="auftraege",title="Auftraege",
render=function(v,rect)
local state=v.page_state("auftraege")
state.list=state.list or{index=1}
local items={}
state.orders={}
local all=role.orders.list()
for i=#all,1,-1 do
local order=all[i]
local template=role.orders.template(order.template)
local text=STATE_TEXT[order.state]or order.state
if flags[order.id]and flags[order.id].unconfirmed then text=text.." - Rueckmeldung fehlt"end
items[#items+1]={text=order.id.." "..(template and template.title or order.template),detail=text..(order.reason and(": "..order.reason)or""),kind=STATE_KIND[order.state]or"text"}
state.orders[#items]=order
end
W.list(v,"auftraege",rect,items,state.list,{empty="Noch keine Auftraege."})
end,
actions=function(v)
local state=v.page_state("auftraege")
local order=state.orders and state.orders[(state.list or{index=1}).index]
local terminal=order and(order.state=="abgeschlossen"or order.state=="abgelehnt"or order.state=="storniert")
return{
{id="stornieren",label=arm.cancel and"Wirklich?"or"Abbrechen",kind="danger",enabled=order~=nil and not terminal,reason="Kein laufender Auftrag gewaehlt."},
{id="neu_pruefen",label="Neu pruefen",kind="secondary",enabled=order~=nil and(order.state=="klaerung"or order.state=="wartend"),reason="Nur fuer wartende Auftraege und Klaerungen."},
}
end,
on_action=function(v,id)
local state=v.page_state("auftraege")
local order=state.orders and state.orders[state.list.index]
if id=="act:stornieren"and order then
if not arm.cancel then
arm.cancel=true
v.hint="Nochmal druecken. Vor der Fahrplanuebergabe wird storniert, danach ist es nur ein Aenderungswunsch."
else
arm.cancel=false
local ok,text=role.orders.cancel(order.id)
v.hint=ok and text or text
end
return true
elseif id=="act:neu_pruefen"and order then
role.orders.transition(order.id,"in_pruefung","vom Bediener neu angestossen")
drive_all()
return true
end
end,
}

return page
end
