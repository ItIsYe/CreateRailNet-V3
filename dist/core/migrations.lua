





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
