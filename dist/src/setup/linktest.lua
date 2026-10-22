



















local linktest={}

linktest.PART_BYTES=3300
linktest.QUICK_S=0.35

local DEFAULT_SIZES={256,1024,2048,3300,4000}
local ANSWERS={known=true,pending=true,conflict=true,rejected=true,old_master=true}

function linktest.run(ctx,o)
local opts=o or{}
local cfg,entry=ctx.cfg or{},ctx.entry or{}
local pings=opts.pings or 10
local wait_s=opts.wait_s or 2
local result={sent=0,answered=0,quick=0}
local function progress(...)if opts.on_progress then pcall(opts.on_progress,...)end end

local function ask(extra)
local probe={channel=cfg.channel,master_id=cfg.master_id,id=ctx.id,role=ctx.role,entry=ctx.entry,
setup={state="KONFIGURIERT"},modem_name=entry.modem,peripheral=opts.peripheral,wait_s=wait_s}
for key,value in pairs(extra or{})do probe[key]=value end
local called,answer=pcall(opts.link,probe)
if not called or type(answer)~="table" then return{state="no_answer"}end
return answer
end



local total,lowest,highest,misses,acked_only=0,nil,nil,0,0
local function note(rtt)
total=total+rtt
if lowest==nil or rtt<lowest then lowest=rtt end
if highest==nil or rtt>highest then highest=rtt end
if rtt<linktest.QUICK_S then result.quick=result.quick+1 end
end
local acked_rtt={}
for index=1,pings do
local answer=ask()
result.sent=result.sent+1
if answer.state=="no_modem" then result.state="no_modem";return result end
if answer.state=="old_master" then
misses=0
acked_only=acked_only+1
acked_rtt[#acked_rtt+1]=tonumber(answer.rtt_s)or 0
progress("ping",index,pings,nil)
elseif ANSWERS[answer.state] then
misses=0
result.answered=result.answered+1
local rtt=tonumber(answer.rtt_s)or 0
note(rtt)
progress("ping",index,pings,rtt)
else
misses=misses+1
progress("ping",index,pings,nil)

if misses>=3 and result.answered==0 and acked_only==0 then result.aborted=true;break end
end
end
if result.answered==0 and acked_only>0 then

result.old_master,result.answered=true,acked_only
for _,rtt in ipairs(acked_rtt)do note(rtt)end
end

if result.answered>0 then
result.rtt_min,result.rtt_max,result.rtt_avg=lowest,highest,total/result.answered
end
if result.answered==0 then result.state="none";return result end
if result.answered==result.sent and result.quick*10>=result.sent*9 then result.state="ok"
elseif result.answered*5>=result.sent*4 then result.state="shaky"
else result.state="bad" end


if result.old_master then
result.state=result.state=="ok" and "old_master" or result.state
return result
end

result.sizes,result.largest={},0
local tries=opts.tries or 2
for _,bytes in ipairs(opts.sizes or DEFAULT_SIZES)do
local went=false
for _=1,tries do
local answer=ask({pad_bytes=bytes,echo_bytes=bytes})
if ANSWERS[answer.state] and answer.state~="old_master" and answer.echoed==bytes then went=true;break end
end
result.sizes[#result.sizes+1]={bytes=bytes,ok=went}
progress("size",bytes,went)
if not went then break end
result.largest=bytes
end
result.part_ok=result.largest>=linktest.PART_BYTES
return result
end

return linktest
