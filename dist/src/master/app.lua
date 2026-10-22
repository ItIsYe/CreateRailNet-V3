




local config=require("src.shared.config")
local log=require("src.shared.log")
local registry=require("src.shared.registry")
local trains=require("src.domain.trains")
local stations=require("src.domain.stations")
local depots=require("src.domain.depots")
local route_resolver=require("src.domain.route_resolver")
local service_plans=require("src.domain.service_plans")
local audit_log=require("src.domain.audit_log")
local maintenance_mode=require("src.domain.maintenance")
local dispatcher=require("src.master.dispatcher")
local route_integration=require("src.master.route_integration")
local update_control_module=require("src.master.update_control")
local aux_display_module=require("src.master.aux_display")
local op_state_module=require("src.domain.op_state")
local update_trust=require("src.shared.update_trust")
local replacement_setup_module=require("src.master.replacement_setup")
local manual_control=require("src.master.manual_control")
local runtime_factory=require("src.master.runtime")
local ui_core=require("src.master.ui.ui_core")
local status_panel=require("src.master.ui.panels.status")
local alerts_panel=require("src.master.ui.panels.alerts")
local alerts_module=require("src.domain.alerts")
local logs_panel=require("src.master.ui.panels.logs")
local log_collector=require("src.domain.log_collector")
local trace_recorder=require("src.domain.trace_recorder")
local overview_panel=require("src.master.ui.panels.overview")
local diagnostics_panel=require("src.master.ui.panels.diagnostics")
local trains_panel=require("src.master.ui.panels.trains")
local stations_panel=require("src.master.ui.panels.stations")
local depots_panel=require("src.master.ui.panels.depots")
local ota_status_panel=require("src.master.ui.panels.ota_status")
local service_plans_panel=require("src.master.ui.panels.service_plans")
local cargo_panel=require("src.master.ui.panels.cargo")
local gleisbild_panel=require("src.master.ui.panels.gleisbild")
local peripherals=require("src.adapter.peripherals")
local monitors=require("src.adapter.monitors")
local pairing_module=require("src.master.pairing")
local plan_service_module=require("src.master.plan_service")
local restart_module=require("src.master.restart")
local setup_panel=require("src.master.ui.panels.setup")
local hardware_config=require("src.adapter.hardware_config")
local create_signals=require("src.adapter.create_signals")
local net_signals=require("src.master.net_signals")
local fleet_bridge_module=require("src.master.fleet_bridge")
local create_switches=require("src.adapter.create_switches")
local cc_modem=require("src.adapter.cc_modem")
local net=require("src.shared.net")
local auth_setup=require("src.shared.auth_setup")
local ha_wiring=require("src.master.ha_wiring")
local ota_manager=require("src.master.ota_manager")
local cargo_module=require("src.domain.cargo")
local startup_guard=require("src.shared.startup_guard")

local app={}

local function fallback_monitor()
return{clear=function()end,setCursorPos=function()end,write=function()end}
end

function app.new(args)
local parsed=args or{}
local cfg=config.load(parsed.config or "configs/templates/network.example.json")
local logger=log.new("INFO",200)
startup_guard.ensure({logger=logger,enabled=cfg.startup_autoupgrade~=false})
local reg=registry.new()
local train_registry=trains.new(cfg)
local station_registry=stations.new(cfg)
local depot_registry=depots.new(cfg)
local service_plan_registry=service_plans.new(cfg)
local resolver=route_resolver.new(cfg.routes or{})
local audits=audit_log.new(300)
local maintenance=maintenance_mode.new({path=cfg.maintenance_file or "state/maintenance.json",fs=_G.fs})
local maintenance_load,maintenance_why=maintenance.load()
if maintenance_load=="corrupt" then logger.error("maintenance file unreadable: lock stays on",{error=maintenance_why})end
local peri=peripherals.new()
local hw=hardware_config.new(cfg)
local modem=cc_modem.for_node(cfg,parsed.id or cfg.master_id)
local ok,err=modem:open(cfg.channel)
if ok==false then
logger.error("master modem open failed",{error=err})
error("master modem open failed: " .. tostring(err))
end


local my_id=parsed.id or cfg.master_id
local ha_prep=ha_wiring.prepare(cfg,my_id,{now_ms=require("src.shared.time").now_ms,logger=logger})

local network_ref,disp_ref,net_signal_adapter={},{},nil
local signal_adapter
if cfg.signal_transport=="network" then
net_signal_adapter=net_signals.new({
network={send_reliable=function(...)return network_ref.net.send_reliable(...)end},
config=cfg,logger=logger,
on_failure=function(signal_id,_,reason)if disp_ref.d then disp_ref.d.signal_failed(signal_id,reason)end end
})
signal_adapter=net_signal_adapter
else
signal_adapter=create_signals.new(peri,{hardware=hw})
end
local switch_adapter=create_switches.new(peri,{hardware=hw})
if ha_prep then signal_adapter,switch_adapter=ha_prep.signals(signal_adapter),ha_prep.switches(switch_adapter)end
local disp=dispatcher.new(cfg,{signals=signal_adapter,switches=switch_adapter})
disp_ref.d=disp


local trace=trace_recorder.new({capacity=cfg.trace_capacity or 500})
trace.attach(disp)

local network=net.new(modem,cfg.channel,parsed.id or cfg.master_id,logger,nil,
{auth=auth_setup.build(cfg,parsed.id or cfg.master_id,{master=true,logger=logger})})
network_ref.net=network

local ha,replica,barrier
if ha_prep then
local wired=ha_wiring.finish(ha_prep,{network=network,dispatcher=disp,logger=logger,now_ms=require("src.shared.time").now_ms})
ha,replica,barrier=wired.ha,wired.replica,wired.barrier
end

network.on_drop=function(msg)
logger.error("net message dropped after max retries",{type=msg.type,dst=msg.dst,id=msg.id})
if reg and reg.mark_down and msg.dst then reg.mark_down(msg.dst)end
end
if net_signal_adapter then net_signal_adapter.install(network)end
local monitor_found,monitor_note=monitors.resolve(peri,hw.value(parsed.id or cfg.master_id,"monitor")or cfg.monitor,hw.value(parsed.id or cfg.master_id,"monitor_scale")or cfg.monitor_scale)
if monitor_note then logger.warn("master monitor",{note=monitor_note,using=monitor_found and "first monitor found" or "none (no display)"})end
local monitor=monitor_found or fallback_monitor()

local context,instance
local alerts=alerts_module.new()
local logs=log_collector.new()

local pairing=pairing_module.new({
config=cfg,plan_path=parsed.config or "configs/templates/network.example.json",fs=_G.fs,
audit=function(kind,data)audits.record(kind,data)end,
})
local ui=ui_core.new(monitor,{
alerts=alerts_panel.new(alerts,nil),
setup=setup_panel.new({
config=cfg,registry=reg,pairing=pairing,
decide=function(action,id,operator)
if instance and instance.runtime then return instance.runtime.pair_decide(action,id,operator)end
return false,"Der Master startet noch."
end,

restart_needed=function()return instance and instance.runtime and instance.runtime.restart_needed==true end,
restart=function(operator)
if instance and instance.runtime then return instance.runtime.restart_master(operator)end
return false,"Der Master startet noch."
end,
busy_blocks=function()return instance and instance.runtime and instance.runtime.busy_blocks()or 0 end,
release=function()return instance and instance.runtime and instance.runtime.release or nil end,
release_now=function(operator)
if instance and instance.runtime then return instance.runtime.release_operation(operator)end
return false,"Der Master startet noch."
end,
}),
status=status_panel.new({
alerts=alerts,
registry=reg,
dispatcher=disp,
maintenance=maintenance,
ota=function()return context and context.ota end,
recovery=function()return instance and instance.runtime and instance.runtime.recovery end
}),
overview=overview_panel.new(disp,reg,nil),
gleisbild=gleisbild_panel.new(disp,reg,nil),
trains=trains_panel.new(train_registry,nil),
stations=stations_panel.new(station_registry,nil,network,function()return parsed.id or cfg.master_id end),
depots=depots_panel.new(depot_registry,nil,network),
fahrplan=service_plans_panel.new(service_plan_registry,train_registry),
cargo=cargo_panel.new(nil,nil),
diag=diagnostics_panel.new(logger,disp),
logs=logs_panel.new(logs),
ota=ota_status_panel.new(reg,audits)
},{logger=logger})

ui.set_panel("status")


local fleet_bridge
if cfg.fleet and cfg.fleet.pairs then
local lengths={}
for _,spec in ipairs(cfg.fleet.train_profiles or{})do lengths[spec.immutable_id]=spec.length end
fleet_bridge=fleet_bridge_module.new({dispatcher=disp,network=network,config=cfg,logger=logger,now=require("src.shared.time").now_s,train_length=function(id)return lengths[id] end})
end

context={
ha=ha,replica=replica,barrier=barrier,fleet_bridge=fleet_bridge,
config=cfg,
logger=logger,
registry=reg,
train_registry=train_registry,
station_registry=station_registry,
depot_registry=depot_registry,
service_plan_registry=service_plan_registry,
route_resolver=resolver,
dispatcher=disp,
network=network,
ui=ui,
audit_log=audits,
maintenance=maintenance,
alerts=alerts,
logs=logs,
trace=trace
}
context.route_integration=route_integration.new(context)
context.manual_control=manual_control.new(context)
context.ota=ota_manager.new(network,reg,logger,{
sign_package=network.auth and network.auth.keyring and update_trust.signer({keyring=network.auth.keyring,my_id=parsed.id or cfg.master_id,config=cfg,protocol=net.PROTOCOL_REVISION})or nil
})

local fleet_pairs_view={
pair_of=function(node_id)for _,pair in ipairs((cfg.fleet and cfg.fleet.pairs)or{})do for _,id in ipairs(pair.nodes or{})do if id==node_id then return pair.id end end end end,
partner_of=function(node_id)for _,pair in ipairs((cfg.fleet and cfg.fleet.pairs)or{})do for index,id in ipairs(pair.nodes or{})do if id==node_id then return pair.nodes[3 - index] end end end end,
status=function(pair_id)
for _,pair in ipairs((cfg.fleet and cfg.fleet.pairs)or{})do
if pair.id==pair_id then
for _,id in ipairs(pair.nodes or{})do local node=reg.get(id);if not node or node.status~="UP" then return{alive=false}end end
end
end
return{alive=true}
end
}
context.update_control=update_control_module.new({
fs=_G.fs,path=cfg.update_plan_file or "state/update_plan.json",now=require("src.shared.time").now_s,config=cfg,logger=logger,
busy=function(node_id)
local role
for _,node in ipairs(cfg.nodes or{})do if node.id==node_id then role=node.role end end
if role~="signal" and role~="switch" and role~="sensor" and role~="station" and role~="depot" then return false end
for _,train in pairs(disp.get_trains())do if train.holds_route then return true end end
return false
end,
ha=function()
if not ha then return{}end
local status=ha.status()
return{leads=ha.is_leader(),both_masters_healthy=ha.is_leader()and(status.fresh or 0)>=3}
end,
fleet_pairs=fleet_pairs_view,

on_lock=function(node_id,reason)logger.warn("update lock",{node=node_id,reason=reason});if disp.timeout_node then disp.timeout_node(node_id)end end
})
context.update_control.load()

if cfg.aux_monitor then
local aux_monitor=peri.wrap(cfg.aux_monitor)
if not aux_monitor then
logger.warn("aux monitor not found",{monitor=cfg.aux_monitor})
else
pcall(function()if aux_monitor.setTextScale then aux_monitor.setTextScale(cfg.aux_monitor_scale or 1)end end)
context.aux=aux_display_module.new({
monitor=aux_monitor,id=parsed.id or cfg.master_id,now=os.clock,
sources={
role=function()if not ha then return "single" end return ha.is_leader()and "leader" or "standby" end,
op=function()
local locks=context.update_control.locks()
local faulty={}
for _,lock in ipairs(locks)do faulty[#faulty+1]=lock.node_id end
return op_state_module.derive({setup_done=true,maintenance=maintenance.is_locked(),local_faults=faulty,both_masters=ha and ha.is_leader()or nil})
end,
blocks=function()
local counts={free=0,unknown=0,fault=0,reserved=0}
for id,block in pairs(disp.get_overview())do
local state=block.state
if state=="FAULT" then counts.fault=counts.fault+1
elseif state=="FREE" then counts.free=counts.free+1
elseif state=="RESERVED" or state=="OCCUPIED" then counts.reserved=counts.reserved+1 end
local occupancy=disp.get_occupancy and disp.get_occupancy(id)
if occupancy and occupancy.state=="UNKNOWN" and disp.proof_mode and disp.proof_mode()then counts.unknown=counts.unknown+1 end
end
return counts
end,
nodes=function()
local up,down,down_ids=0,0,{}
for id,node in pairs(reg.all())do
if node.status=="UP" then up=up+1 else down=down+1;down_ids[#down_ids+1]=id end
end
table.sort(down_ids)
return{up=up,down=down,down_ids=down_ids}
end,
locks=function()return context.update_control.locks()end,
alerts=function()return alerts.list({active_only=true})end,
journal=function()
if not replica then return true end
if replica.writable and not replica.writable()then return false,"nicht beschreibbar" end
return true
end,
space=function()return _G.fs and _G.fs.getFreeSpace and _G.fs.getFreeSpace("/")or nil end
}
})
end
end

context.replacement=replacement_setup_module.build({
config=cfg,fs=_G.fs,peripheral=_G.peripheral,now=require("src.shared.time").now_s,
on_hold=function(node_id)
if disp.timeout_node then disp.timeout_node(node_id)end
alerts.raise("replace:" .. node_id,"RED","Computer " .. node_id .. " wird ersetzt: seine Bloecke sind gesperrt")
end,
on_release=function(node_id)alerts.clear("replace:" .. node_id)end
})
context.pairing=pairing

context.restart=restart_module.build({dispatcher=disp,red=cfg.signal_red_on_stop~=false,logger=logger,reboot=function()if os.reboot then os.reboot()end end})

context.plan_service=plan_service_module.new({plan_path=parsed.config or "configs/templates/network.example.json",fs=_G.fs})
context.cargo=cargo_module.new(cfg)


local mc=context.manual_control
if ui.panels.alerts then ui.panels.alerts=alerts_panel.new(alerts,mc)end
if ui.panels.overview then ui.panels.overview=overview_panel.new(disp,reg,mc)end
if ui.panels.gleisbild then ui.panels.gleisbild=gleisbild_panel.new(disp,reg,disp.interlocking)end
if ui.panels.trains then ui.panels.trains=trains_panel.new(train_registry,mc)end
if ui.panels.stations then ui.panels.stations=stations_panel.new(station_registry,mc,network,function()return parsed.id or cfg.master_id end)end
if ui.panels.depots then ui.panels.depots=depots_panel.new(depot_registry,mc,network)end
if ui.panels.cargo then ui.panels.cargo=cargo_panel.new(context.cargo,mc)end

if ui.rebuild_order then ui.rebuild_order()end

instance={context=context}
instance.runtime=runtime_factory.new(context)
function instance.run()
local ok_run,run_err=pcall(instance.runtime.run)

if cfg.signal_red_on_stop~=false then
local ok_red,failed=pcall(disp.shutdown_red)
if not ok_red then logger.warn("signals to RED on stop failed",{error=tostring(failed)})
elseif failed>0 then logger.warn("signals to RED on stop: some did not answer",{failed=failed})end
end
if not ok_run then error(run_err,0)end
end
return instance
end

return app
