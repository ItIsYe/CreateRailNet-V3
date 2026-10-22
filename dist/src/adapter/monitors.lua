














local monitors={}

function monitors.valid_scale(scale)
return type(scale)=="number" and scale>=0.5 and scale<=5 and scale*2==math.floor(scale*2)
end

local function say(note,text)
if note then return note .. "; " .. text end
return text
end


local function scaled(found,note,scale)
if not found or scale==nil then return found,note end
if not monitors.valid_scale(scale)then
return found,say(note,"monitor_scale " .. tostring(scale).. " is not valid (0.5 to 5 in steps of 0.5), ignored")
end
if type(found.setTextScale)~="function" then return found,say(note,"monitor_scale: this monitor has no setTextScale")end
local ok,err=pcall(found.setTextScale,scale)
if not ok then return found,say(note,"monitor_scale " .. tostring(scale).. " failed: " .. tostring(err))end
return found,note
end

function monitors.resolve(peripherals,name,scale)
local found,note=monitors.find(peripherals,name)
return scaled(found,note,scale)
end

function monitors.find(peripherals,name)
if not(peripherals and peripherals.wrap)then return nil,"no peripheral access" end
local note=nil
if type(name)=="string" and name~="" then
local wanted=peripherals.wrap(name)
if wanted then return wanted end
note="monitor '" .. name .. "' not found"
end
if name~="monitor" then
local legacy=peripherals.wrap("monitor")
if legacy then return legacy,note end
end
if peripherals.list and peripherals.get_type then
local ok,names=pcall(peripherals.list)
if ok and type(names)=="table" then
local sorted={}
for _,candidate in ipairs(names)do sorted[#sorted+1]=tostring(candidate)end
table.sort(sorted)
for _,candidate in ipairs(sorted)do
if peripherals.get_type(candidate)=="monitor" then
local found=peripherals.wrap(candidate)
if found then return found,note end
end
end
end
end
return nil,note or "no monitor found"
end

return monitors
