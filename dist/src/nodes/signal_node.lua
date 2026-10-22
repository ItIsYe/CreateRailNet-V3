






local create_signals=require("src.adapter.create_signals")
local common_node=require("src.nodes.common_node")
local bootstrap=require("src.nodes.bootstrap")
local signal_bindings=require("src.shared.signal_bindings")
local signal_host=require("src.nodes.signal_host")

local signal_node={}

local function build_context(args_or_context)
if args_or_context.config and args_or_context.logger and args_or_context.peripherals and args_or_context.modem then return args_or_context end
return bootstrap.create_context({"--id",args_or_context.id,"--config",args_or_context.config},"signal")
end

local function own_entry(config,id)
for _,node in ipairs((config and config.nodes)or{})do
if type(node)=="table" and node.id==id then return node end
end
return nil
end



local function multi_runtime(context,entry)
local peripherals=context.peripherals
local bindings=signal_bindings.new({fs=context.fs,node_id=context.id})
local state,why=bindings.load()
if state=="corrupt" then context.logger.error("signal bindings unreadable: no signal of this node is used",{reason=why})end
local host=signal_host.new({bindings=bindings,peripherals=peripherals,logger=context.logger,expected=entry.signals})

local ok_red,failed=host.all_red()
if not ok_red then context.logger.warn("signals that could not be set to RED at the start",{signals=table.concat(failed,",")})end
local node=common_node.new({
id=context.id,role=context.role,config=context.config,modem=context.modem,logger=context.logger,clock=context.clock,
start_timer=context.start_timer,tick_grace=context.tick_grace,
handlers={
on_quiesce=function()
local ok=host.all_red()
return ok
end,
on_cmd=function(payload)
if not payload or not payload.aspect then return false,"missing payload.aspect" end
if not payload.signal_id then return false,"missing payload.signal_id" end
return host.set_aspect(payload.signal_id,payload.aspect)
end
}
})
node.signal_host=host
node.signal_bindings=bindings

node.heartbeat=function()
return node.net.heartbeat(node.config.master_id,{role=node.role,signals=host.brief()})
end
return node
end

function signal_node.new_runtime(args_or_context)
local context=build_context(args_or_context)
local entry=own_entry(context.config,context.id)
if entry and type(entry.signals)=="table" and#entry.signals>0 then return multi_runtime(context,entry)end
local adapter=create_signals.new(context.peripherals,{hardware=context.hardware})


pcall(adapter.setAspect,context.id,"RED")
return common_node.new({
id=context.id,
role=context.role,
config=context.config,
modem=context.modem,
logger=context.logger,
clock=context.clock,
start_timer=context.start_timer,
tick_grace=context.tick_grace,
handlers={

on_quiesce=function()return adapter.setAspect(context.id,"RED")end,
on_cmd=function(payload)
if not payload or not payload.aspect then return false,"missing payload.aspect" end
return adapter.setAspect(context.id,payload.aspect)
end
}
})
end

local raw={...}
if raw and raw[1]=="--run" then signal_node.new_runtime(bootstrap.create_context(raw,"signal")).run()end

return signal_node
