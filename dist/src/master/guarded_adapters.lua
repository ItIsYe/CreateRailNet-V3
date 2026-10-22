








local guarded_adapters={}

local RESTRICTIVE_ASPECTS={RED=true,STOP=true}

function guarded_adapters.guard(adapter,opts)
local barrier,ha,kind=opts.barrier,opts.ha,opts.kind
local proxy=setmetatable({},{__index=function(_,name)return adapter[name] end})

if kind=="signals" then
function proxy.setAspect(signal_id,aspect)
if ha and not ha.is_leader()then return false,"not the active leader" end
if RESTRICTIVE_ASPECTS[aspect] or aspect==false then
barrier.cancel("signal:" .. tostring(signal_id))
return adapter.setAspect(signal_id,aspect)
end
barrier.hold("signal:" .. tostring(signal_id),function()adapter.setAspect(signal_id,aspect)end)
return true
end
elseif kind=="switches" then
function proxy.setPosition(switch_id,position)
if ha and not ha.is_leader()then return false,"not the active leader" end
barrier.hold("switch:" .. tostring(switch_id),function()adapter.setPosition(switch_id,position)end)
return true
end
end
return proxy
end

return guarded_adapters
