















local cc_modem=require("src.adapter.cc_modem")
local net=require("src.shared.net")

local link={}

local DEFAULT_WAIT_S=6


local function default_pull(timeout)
local timer=os.startTimer(timeout)
while true do
local event={os.pullEvent()}
if event[1]=="timer" and event[2]==timer then return nil end
if event[1]=="modem_message" then
if os.cancelTimer then pcall(os.cancelTimer,timer)end
return event
end
end
end

local REPLIES={known="known",pending="pending",conflict="conflict",rejected="rejected",muted="rejected",full="pending"}

function link.probe(opts)
local o=opts or{}
local modem=o.modem or cc_modem.new({channel=o.channel,modem_name=o.modem_name,peripheral_api=o.peripheral})
if not modem.modem and not o.modem then return{state="no_modem"}end
local opened=modem:open(o.channel)
if opened==false then return{state="no_modem"}end

local silent={info=function()end,warn=function()end,error=function()end,debug=function()end}
local network=net.new(modem,o.channel,o.id,silent,o.time)
local answer,acked=nil,false
network.on_ack=function(_,original)
if original and original.payload and original.payload.type=="pair_probe" then acked=true end
end
local event={type="pair_probe",role=o.role,entry=o.entry,setup=o.setup}
if type(o.pad_bytes)=="number" and o.pad_bytes>=1 then event.pad=string.rep("x",math.floor(o.pad_bytes))end
if type(o.echo_bytes)=="number" and o.echo_bytes>=1 then event.echo=math.floor(o.echo_bytes)end
local now=o.now or function()return(os.epoch and os.epoch("utc")/1000)or os.clock()end
local started=now()
local sent=network.send_reliable("event",o.master_id,event)
if not sent then return{state="no_answer",detail="nothing could be sent"}end
local question=sent.id

local pull=o.pull_event or default_pull
local deadline=started+(o.wait_s or DEFAULT_WAIT_S)
while true do
local remaining=deadline - now()
if remaining<=0 then break end
local event=pull(math.min(0.5,remaining))
if event and event[1]=="modem_message" then
local msg=event[5]
local status=network.receive(msg)
if status=="ok" and type(msg)=="table" and msg.type=="cmd" and msg.src==o.master_id and type(msg.payload)=="table" and msg.payload.cmd=="pair_state" then
network.ack_for(msg,true)

local answered=msg.payload.probe_id
if answered==nil or answered==question then
local pad=msg.payload.pad
return{state=REPLIES[msg.payload.state] or "pending",detail=msg.payload.detail,rtt_s=math.max(0,now()- started),
echoed=type(pad)=="string" and#pad or 0}
end
end
end
network.tick()
end

if acked then return{state="old_master"}end
return{state="no_answer"}
end

return link
