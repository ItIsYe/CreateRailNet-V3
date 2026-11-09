





local M={}




M.STEPS={




[1]={
text="Entwurf der Einrichtung verwerfen",
scope={"config.lua"},
run=function(ctx)
local c=ctx.load("config.lua")
if type(c)~="table"then return end
local lauf=type(c.pruefung)=="table"and c.pruefung.lauf or nil
local d=lauf and type(c.devices)=="table"and c.devices[lauf.device]or nil
if d and d.kind=="signal"and type(d.device)=="string"and not ctx.exists("pruefmarke.lua")then
ctx.save("pruefmarke.lua",{device=lauf.device,name=d.device,t=tonumber(lauf.t)or 0})
end
if c.status=="aktiv"then

if lauf then
c.pruefung.lauf=nil
ctx.save("config.lua",c)
end
return
end
local claim=type(c.node)=="table"and c.node.claim or nil
if type(claim)=="string"and#claim>=8 and#claim<=64 and not claim:find("[^%w%-_]")and not ctx.exists("anforderung.lua")then
ctx.save("anforderung.lua",{claim=claim})
end
ctx.delete("config.lua")
end,
},



[2]={
text="Freigabeausgang der Gleise entfernen (Freigabe laeuft ueber den Fahrplan)",
scope={"config.lua","station.lua"},
run=function(ctx)
local c=ctx.load("config.lua")
if type(c)=="table"and type(c.tracks)=="table"then
local changed=false
for _,track in pairs(c.tracks)do
if type(track)=="table"and track.release~=nil then track.release,changed=nil,true end
end
if changed then ctx.save("config.lua",c)end
end
local s=ctx.load("station.lua")
if type(s)=="table"and type(s.tracks)=="table"then
local changed=false
for _,tr in pairs(s.tracks)do
if type(tr)=="table"and tr.release_set==true then
tr.release_set,tr.release_train,tr.release_stay,tr.release_order=false,nil,nil,nil
changed=true
end
end
if changed then ctx.save("station.lua",s)end
end
end,
},




[3]={
text="Rollen Signal und Knoten entfernen (Create regelt die Strecke)",
scope={"config.lua","signal.lua","knoten.lua","pruefmarke.lua"},
run=function(ctx)
for _,name in ipairs({"signal.lua","knoten.lua","pruefmarke.lua"})do
if ctx.exists(name)then ctx.delete(name)end
end
local c=ctx.load("config.lua")
if type(c)~="table"or type(c.node)~="table"or type(c.node.roles)~="table"then return end
local kept,removed={},false
for _,role in ipairs(c.node.roles)do
if role=="signal"or role=="knoten"then removed=true else kept[#kept+1]=role end
end
if not removed then return end
if#kept==0 then
ctx.delete("config.lua")
return
end
c.node.roles=kept
c.junction,c.node.junction,c.node.junction_rev=nil,nil,nil
for id,d in pairs(type(c.devices)=="table"and c.devices or{})do
if type(d)=="table"and d.kind=="signal"then c.devices[id]=nil end
end
for _,track in pairs(type(c.tracks)=="table"and c.tracks or{})do
if type(track)=="table"then track.signals,track.junction,track.order_ok=nil,nil,nil end
end
c.tests={}
ctx.save("config.lua",c)
end,
},


[4]={
text="Bahnhofsrollen zusammenfassen, Beobachter und Gleisrichtung entfernen",
scope={"config.lua"},
run=function(ctx)
local c=ctx.load("config.lua")
if type(c)~="table"or type(c.node)~="table"then return end
local changed=false
if type(c.node.roles)=="table"then
local legacy={passagierbahnhof=true,gueterbahnhof=true,depot=true}
local out,seen={},{}
for _,role in ipairs(c.node.roles)do
if legacy[role]then role="bahnhof"end
if not seen[role]then seen[role]=true;out[#out+1]=role end
end
if table.concat(out,",")~=table.concat(c.node.roles,",")then c.node.roles,changed=out,true end
end
for id,d in pairs(type(c.devices)=="table"and c.devices or{})do
if type(d)=="table"and d.kind=="observer"then c.devices[id],changed=nil,true end
end
for _,track in pairs(type(c.tracks)=="table"and c.tracks or{})do
if type(track)=="table"and(track.observers~=nil or track.direction~=nil)then track.observers,track.direction,changed=nil,nil,true end
end
if changed then ctx.save("config.lua",c)end
end,
},
}


function M.validate(steps)
local count=0
for key in pairs(steps)do
if type(key)~="number"then return"Schluessel "..tostring(key).." ist keine Nummer"end
count=count+1
end
for i=1,count do
local step=steps[i]
if step==nil then return"Schritt "..i.." fehlt (Luecke in der Nummerierung)"end
local run=type(step)=="function"and step or(type(step)=="table"and step.run)
if type(run)~="function"then return"Schritt "..i.." hat keine Funktion"end
end
return nil
end

M.FORMAT=1+#M.STEPS

return M
