






local config=require("src.shared.config")
local log=require("src.shared.log")
local shared_args=require("src.shared.args")
local common_node=require("src.nodes.common_node")
local cc_modem=require("src.adapter.cc_modem")
local bootstrap=require("src.nodes.bootstrap")
local election_store=require("src.shared.election_store")
local ha_module=require("src.shared.ha")
local time=require("src.shared.time")

local arbiter_node={}

local function build_context(args_or_context)
if args_or_context.config and args_or_context.logger and args_or_context.modem then return args_or_context end
local cfg=config.load(args_or_context.config or "configs/templates/network.example.json")
return{id=args_or_context.id,role="arbiter",config=cfg,logger=log.new("INFO",200),modem=cc_modem.for_node(cfg,args_or_context.id)}
end

function arbiter_node.new_runtime(args_or_context)
local context=build_context(args_or_context)
local node=common_node.new({
id=context.id,role="arbiter",config=context.config,modem=context.modem,logger=context.logger,
clock=context.clock,start_timer=context.start_timer,tick_grace=context.tick_grace,
fence_fs=context.fence_fs,journal_fs=context.journal_fs,topology_fs=context.topology_fs,ledger=false,
handlers={on_cmd=function(payload)return false,"the arbiter takes no commands: " .. tostring(payload and payload.cmd)end}
})

local function start_voting()
if node.ha or not ha_module.is_ha(node.config)then return end
node.config.arbiter=node.config.arbiter or node.id
node.ha=ha_module.new({
id=node.id,config=node.config,network=node.net,now_ms=time.now_ms,logger=node.logger,
store=context.election_store or election_store.new(context.election_path,{fs=context.election_fs}),
lease_ms=node.config.election_lease_ms,beat_ms=node.config.election_beat_ms
})
node.logger.info("arbiter: voting between the masters",{masters=table.concat(node.config.masters,",")})
end
node.on_topology=start_voting
start_voting()


node.ticker.every("election",0.5,function()if node.ha then node.ha.tick()end end)
return node
end

local args=shared_args.parse({...},{config={},id={}})
if args.id then
arbiter_node.new_runtime(bootstrap.create_context({...},"arbiter")).run()
end

return arbiter_node
