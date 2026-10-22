





















package.path="/?.lua;/?/init.lua;" ..(package.path or "")

local shared_args=require("src.shared.args")
local ota_targets=require("src.master.ota_targets")
local config=require("src.shared.config")
local log=require("src.shared.log")
local cc_modem=require("src.adapter.cc_modem")
local net=require("src.shared.net")
local ota_manager=require("src.master.ota_manager")
local ticker=require("src.shared.ticker")
local time=require("src.shared.time")

local parsed=shared_args.parse({...},{config={},node={},version={},wait={},legacy={boolean=true},
role={},limit={},["dry-run"]={boolean=true}})
local cfg=config.load(parsed.config or "configs/templates/network.full.example.json")


local nodes
if parsed.node or parsed.role or parsed.limit then
local chosen,why=ota_targets.select(cfg,{node=parsed.node,role=parsed.role,limit=parsed.limit})
if not chosen then error(why,0)end
nodes=chosen
end
if parsed.legacy and not nodes then

nodes={}
for _,node in ipairs(cfg.nodes or{})do
if node.id and node.role~="master" and node.id~=cfg.master_id then nodes[#nodes+1]=node.id end
end
table.sort(nodes)
end
if parsed["dry-run"] then
print((parsed.legacy and "LEGACY: " or "").. ota_targets.describe(nodes,{role=parsed.role,limit=parsed.limit and#nodes}))
print("Nichts wurde gesendet (--dry-run).")
return
end

local logger=log.new("INFO",200)
local modem=cc_modem.new({channel=cfg.channel})
local opened,open_err=modem:open(cfg.channel)
if not opened then error("modem open failed: " .. tostring(open_err))end

local network=net.new(modem,cfg.channel,"OTA-TOOL",logger)
local manager=ota_manager.new(network,nil,logger)

local version=parsed.version or("ota-" .. tostring(time.now_s()))
print("CreateRailNet OTA Push")
print("Version: " .. version)
print("Targets: " ..(nodes and table.concat(nodes,", ")or "every node that answers on the channel"))

local results,start_err
if parsed.legacy then
print("LEGACY mode: one message per node, no rollback on the old nodes (try one node first with --node)")
results,start_err=manager.push_legacy({nodes=nodes,version=version})
else
results,start_err=manager.push_runtime({nodes=nodes,version=version,discover=nodes==nil})
end
if start_err then error("OTA not started: " .. tostring(start_err))end
for node_id,r in pairs(results)do
if not r.ok then print(node_id .. ": FAILED " .. tostring(r.error))end
end

local function print_status()
for _,s in ipairs(manager.status())do
print(string.format("%-14s %-11s %d/%d %s",s.node_id,s.state,s.acked or s.sent,s.total,s.error and("(" .. s.error .. ")")or ""))
end
end

local loop=ticker.new({})
loop.every("net",0.5,network.tick)
loop.every("ota",0.5,manager.tick)
loop.every("status",3,print_status)
loop.start()

local deadline=time.now_ms()+(tonumber(parsed.wait)or 300)*1000
while not manager.finished(true)and time.now_ms()<deadline do
local event={os.pullEvent()}
loop.handle_event(event)
if event[1]=="modem_message" then
local msg=event[5]
if network.receive(msg)=="ok" and msg.type=="event" and type(msg.payload)=="table" then
local kind=msg.payload.type
if kind=="ota_need" then manager.on_need(msg)
elseif kind=="ota_result" then manager.on_result(msg)
elseif kind=="ota_confirmed" then manager.on_confirmed(msg)end
network.ack_for(msg)
end
end
end

print_status()
local failed=0
for _,s in ipairs(manager.status())do if s.state=="FAILED" then failed=failed+1 end end
print(failed==0 and "Done." or(failed .. " node(s) failed."))
