









local net_signals={}

function net_signals.new(opts)
local network,logger=opts.network,opts.logger
local self={}
local host={}
for _,node in ipairs((opts.config and opts.config.nodes)or{})do
if node.role=="signal" then
if type(node.signals)=="table" and#node.signals>0 then
for _,id in ipairs(node.signals)do host[id]=node.id end
else
host[node.id]=node.id
end
end
end
local state={}
local by_msg={}

function self.setAspect(signal_id,aspect)
local node_id=host[signal_id]
if not node_id then return false,"no signal node hosts signal " .. tostring(signal_id)end
local msg,err=network.send_reliable("cmd",node_id,{cmd="set_aspect",signal_id=signal_id,aspect=aspect})
if not msg then
state[signal_id]={status="FAILED",aspect=aspect,reason=tostring(err)}
return false,"signal command not sent: " .. tostring(err)
end
local previous=state[signal_id]
if previous and previous.msg_id then by_msg[previous.msg_id]=nil end
state[signal_id]={status="PENDING",aspect=aspect,msg_id=msg.id}
by_msg[msg.id]=signal_id
return true
end

function self.getState(signal_id)
local entry=state[signal_id]
if entry and entry.status=="FAILED" then return false,entry.reason end
return true,"UNKNOWN"
end

function self.status(signal_id)
local entry=state[signal_id]
if not entry then return "NONE" end
return entry.status,{aspect=entry.aspect,reason=entry.reason}
end

function self.failed()
local out={}
for id,entry in pairs(state)do if entry.status=="FAILED" then out[#out+1]=id end end
table.sort(out)
return out
end

local function resolve(msg_id)
local signal_id=msg_id and by_msg[msg_id]
local entry=signal_id and state[signal_id]
if entry and entry.msg_id==msg_id then return signal_id,entry end
return nil
end

local function fail(msg_id,reason)
local signal_id,entry=resolve(msg_id)
if not signal_id then return end
entry.status,entry.reason="FAILED",reason
by_msg[msg_id]=nil
if logger then logger.warn("signal command failed",{signal=signal_id,aspect=entry.aspect,reason=reason})end
if opts.on_failure then opts.on_failure(signal_id,entry.aspect,reason)end
end

function self.install(net)
local previous_ack,previous_err,previous_drop=net.on_ack,net.on_err,net.on_drop
net.on_ack=function(payload,original)
if previous_ack then previous_ack(payload,original)end
local signal_id,entry=resolve(payload and payload.ack_id)
if signal_id and payload.applied==true then
entry.status="APPLIED"
by_msg[payload.ack_id]=nil
end
end
net.on_err=function(payload,original,source)
if previous_err then previous_err(payload,original,source)end
fail(payload and payload.ref_id,tostring(payload and payload.error))
end
net.on_drop=function(msg)
if previous_drop then previous_drop(msg)end
fail(msg and msg.id,"no answer from " .. tostring(msg and msg.dst))
end
end

return self
end

return net_signals
