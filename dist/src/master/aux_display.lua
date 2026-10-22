








local aux_display={}

local function size(monitor)
if monitor and monitor.getSize then
local ok,w,h=pcall(monitor.getSize)
if ok and type(w)=="number" and type(h)=="number" then return w,h end
end
return 51,19
end

function aux_display.new(opts)
local sources=opts.sources or{}
local now=opts.now or function()return 0 end
local self={}

local function read(name,...)
local fn=sources[name]
if type(fn)~="function" then return nil end
local ok,a,b=pcall(fn,...)
if not ok then return nil end
return a,b
end

function self.lines(width,height)
local lines={}
local function add(text)lines[#lines+1]=tostring(text)end
local role=read("role")
add("MASTER-AUX  " .. tostring(opts.id or "").. "  " ..(type(role)=="string" and role or "?"))
local state,why=read("op")
add("Zustand: " ..(type(state)=="string" and(state ..(why and(" - " .. tostring(why))or ""))or "?"))
local blocks=read("blocks")
if type(blocks)=="table" then
add("Bloecke: frei " .. tostring(blocks.free or 0).. "  unklar " .. tostring(blocks.unknown or 0).. "  Stoerung " .. tostring(blocks.fault or 0).. "  belegt " .. tostring(blocks.reserved or 0))
else
add("Bloecke: ?")
end
local nodes=read("nodes")
if type(nodes)=="table" then
add("Knoten: " .. tostring(nodes.up or 0).. " da, " .. tostring(nodes.down or 0).. " weg" ..((nodes.down_ids and#nodes.down_ids>0)and(": " .. table.concat(nodes.down_ids,",",1,math.min(#nodes.down_ids,4)))or ""))
else
add("Knoten: ?")
end
local locks=read("locks")
if type(locks)=="table" then
add("Sperren: " ..#locks)
for i=1,math.min(#locks,2)do add("  " .. tostring(locks[i].node_id).. ": " .. tostring(locks[i].reason))end
else
add("Sperren: ?")
end
local journal_ok,journal_why=read("journal")
add("Journal: " ..(journal_ok==true and "ok" or(journal_ok==false and("FEHLER " .. tostring(journal_why))or "?")))
local space=read("space")
add("Platz: " ..(type(space)=="number" and(tostring(math.floor(space)).. " Byte frei")or "?"))
local alerts=read("alerts")
if type(alerts)=="table" then
add("Rot, nicht gesehen:")
local shown=0
for _,alert in ipairs(alerts)do
if alert.severity=="RED" and not alert.acked and shown<math.max(1,height -#lines - 2)then add("  " .. tostring(alert.text));shown=shown+1 end
end
if shown==0 then add("  keine")end
else
add("Meldungen: ?")
end
add("Stand " .. tostring(math.floor(now())).. " s")
for i,text in ipairs(lines)do if#text>width then lines[i]=text:sub(1,width)end end
return lines
end

function self.draw()
local monitor=opts.monitor
if not monitor then return false end
local w,h=size(monitor)
local ok=pcall(function()
monitor.clear()
for row,text in ipairs(self.lines(w,h))do
if row>h then break end
monitor.setCursorPos(1,row)
monitor.write(text)
end
end)
return ok
end

return self
end

return aux_display
