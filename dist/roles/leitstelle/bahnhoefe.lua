





local forms=require("ui.forms")
local label=require("core.label")

return function(ctx)
local role=ctx.role
local closed=ctx.closed


local page=forms.page({
id="bahnhoefe",title="Bahnhoefe",empty="Noch kein Bahnhof mit mehreren Gleisen. Einzelne Gleise brauchen keinen Eintrag.",
new_label="Neu",
items=function()
local items,records={},{}
for i,g in ipairs(role.stations.list())do
local parts={}
for _,member in ipairs(g.members)do parts[#parts+1]=member..(closed[member]and" (gesperrt)"or"")end
items[i]={text=g.name,detail=table.concat(parts,", ")}
records[i]=g
end
return items,records
end,
fields={
{id="name",label="Name (z.B. Hauptbahnhof)",max=30,width=34},
{id="members",label="Gleise (Create-Namen mit ; trennen)",max=160,width=48},
},
edit=function(g)return{name=g.name,members=table.concat(g.members,"; ")}end,
on_save=function(values,record)
local members={}
for part in(values.members or""):gmatch("[^;]+")do
local name=part:match("^%s*(.-)%s*$")
if name~=""then members[#members+1]=name end
end
if record then return role.update_station_group(record.name,values.name,members)end
if role.stations.get(values.name)then return nil,"Einen Bahnhof "..tostring(values.name).." gibt es schon: mit Aendern bearbeiten."end
return role.stations.set(values.name,members)
end,
extra={
{id="loeschen",label="Loeschen",kind="danger",run=function(v,g)
local using=role.orders.templates_using(g.name)
local ok,err=role.stations.remove(g.name)
if not ok then return err end
return#using>0 and("Bahnhof geloescht. Die Vorlage "..using[1].title.." nennt ihn noch.")or"Bahnhof geloescht (die Gleise bleiben)."
end},
{id="sperren",label="Sperre",run=function(v,g)
local name=g.members[1]
local ok,err=role.set_closed(name,not closed[name])
return ok and(name..(closed[name]and" ist gesperrt."or" ist frei."))or err
end},
},
})

return page
end
