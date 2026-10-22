








local cc_modem={}

function cc_modem.new(opts)
local options=opts or{}
local peripheral_api=options.peripheral_api or _G.peripheral
local modem=options.modem
local reply_channel=options.reply_channel

if not modem and type(options.modem_name)=="string" and options.modem_name~="" then
if peripheral_api and peripheral_api.wrap then
local ok,wrapped=pcall(peripheral_api.wrap,options.modem_name)
if ok then modem=wrapped end
end
elseif not modem and peripheral_api and peripheral_api.find then
local ok,found=pcall(peripheral_api.find,"modem")
if ok then
modem=found
end
end

local self={modem=modem,reply_channel=reply_channel or options.channel,modem_name=options.modem_name}

function self:open(channel)
if not self.modem then
return false,"modem unavailable"
end
local ok,err=pcall(self.modem.open,channel)
if not ok then
return false,"modem open failed: " .. tostring(err)
end
return true
end

function self:send(channel,dst,msg)
if not self.modem then
return false,"modem unavailable"
end
local ok,err=pcall(self.modem.transmit,channel,self.reply_channel,msg)
if not ok then
return false,"modem transmit failed: " .. tostring(err)
end
return true
end

function self:broadcast(channel,msg)
return self:send(channel,"broadcast",msg)
end

function self:poll(event)
if type(event)~="table" or event[1]~="modem_message" then
return nil
end
return event[5]
end

return self
end


function cc_modem.for_node(cfg,node_id,opts)
local o={}
for key,value in pairs(opts or{})do o[key]=value end
o.channel=o.channel or(cfg and cfg.channel)
for _,node in ipairs((cfg and cfg.nodes)or{})do
if node.id==node_id and type(node.modem)=="string" and node.modem~="" then o.modem_name=node.modem end
end
return cc_modem.new(o)
end

return cc_modem
