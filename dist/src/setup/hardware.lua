











local hardware={}

hardware.SIDES={
{key="left",label="links"},{key="right",label="rechts"},{key="front",label="vorne"},
{key="back",label="hinten"},{key="top",label="oben"},{key="bottom",label="unten"},
}

function hardware.side_label(key)
for _,side in ipairs(hardware.SIDES)do
if side.key==key then return side.label .. " (" .. key .. ")" end
end
return tostring(key)
end

function hardware.classify(info)
local text=(tostring(info.name).. " " .. tostring(info.type)):lower()
for _,method in ipairs(info.methods or{})do text=text .. " " .. tostring(method):lower()end
if text:find("station",1,true)and text:find("setschedule",1,true)then return "create_station" end
if text:find("trainobserver",1,true)or text:find("istrainpassing",1,true)then return "train_observer" end
if text:find("signal",1,true)and(text:find("setforcedred",1,true)or text:find("getstate",1,true))then return "create_signal" end
if text:find("monitor",1,true)then return "monitor" end
if text:find("modem",1,true)then return "modem" end
return "other"
end

function hardware.scan(peripheral_api)
local found={}
if not(peripheral_api and peripheral_api.getNames)then return found end
local ok,names=pcall(peripheral_api.getNames)
if not ok or type(names)~="table" then return found end
table.sort(names)
for _,name in ipairs(names)do
local ptype="unknown"
if peripheral_api.getType then
local ok_type,value=pcall(peripheral_api.getType,name)
if ok_type and value then ptype=tostring(value)end
end
local methods={}
if peripheral_api.getMethods then
local ok_methods,list=pcall(peripheral_api.getMethods,name)
if ok_methods and type(list)=="table" then methods=list end
end
local info={name=name,type=ptype,methods=methods}
info.class=hardware.classify(info)
found[#found+1]=info
end
return found
end

function hardware.of_class(list,class)
local out={}
for _,info in ipairs(list)do if info.class==class then out[#out+1]=info end end
return out
end

function hardware.find(list,name)
for _,info in ipairs(list)do if info.name==name then return info end end
return nil
end

return hardware
