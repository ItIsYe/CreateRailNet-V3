








local config=require("src.shared.config")
local log=require("src.shared.log")
local shared_args=require("src.shared.args")
local peripherals=require("src.adapter.peripherals")
local monitors=require("src.adapter.monitors")
local hardware_config=require("src.adapter.hardware_config")
local cc_modem=require("src.adapter.cc_modem")
local common_node=require("src.nodes.common_node")
local bootstrap=require("src.nodes.bootstrap")
local panel_state=require("src.domain.panel_state")
local renderer=require("src.nodes.panel_renderer")
local permissions=require("src.panel.permissions")
local offline_mod=require("src.panel.offline")
local monitor_registry=require("src.panel.monitor_registry")
local multi_display=require("src.panel.multi_display")
local fault_center_mod=require("src.panel.fault_center")
local topology_sync_mod=require("src.panel.topology_sync")
local diagram=require("src.panel.diagram")
local timetable_editor_mod=require("src.panel.timetable_editor")

local panel_node={}

local function build_context(args_or_context)
if args_or_context.config and args_or_context.logger and args_or_context.peripherals and args_or_context.modem then return args_or_context end
local cfg=config.load(args_or_context.config or "configs/templates/network.example.json")
return{id=args_or_context.id,role="panel",config=cfg,logger=log.new("INFO",200),peripherals=peripherals.new(),hardware=hardware_config.new(cfg),modem=cc_modem.for_node(cfg,args_or_context.id)}
end

local function find_panel_config(cfg,node_id)
for _,node in ipairs(cfg.nodes or{})do if node.id==node_id then return node end end
return{id=node_id,role="panel"}
end

function panel_node.render_status(monitor,state)
renderer.render(monitor,state)
end

function panel_node.new_runtime(args_or_context)
local context=build_context(args_or_context)
local panel_cfg=find_panel_config(context.config,context.id)
local clock=context.clock or os.clock
local fs_api=context.fs or _G.fs


local registry=monitor_registry.new({fs=fs_api,path=panel_cfg.monitors_file or monitor_registry.DEFAULT_PATH,peripheral=context.peripheral_api or _G.peripheral,node_id=context.id})
local registry_state,registry_why=registry.load()
if registry_state=="corrupt" then context.logger.warn("monitor file",{note=registry_why})end
local multi=#registry.list()>0
local monitor
if not multi then
local monitor_note
monitor,monitor_note=monitors.resolve(context.peripherals,panel_cfg.monitor,panel_cfg.monitor_scale)
if monitor_note then context.logger.warn("monitor",{note=monitor_note})end
end

local state_model=panel_state.new(context.config,context.id)
local offline=offline_mod.new({now=clock,timeout_s=panel_cfg.offline_after_s or 10})
local level=permissions.level_of(context.config,context.id)
local pending_confirm
local confirm_window=panel_cfg.confirm_window_s or 10
local faults=fault_center_mod.new({now=clock})
local layout_store=diagram.store({fs=fs_api,path=panel_cfg.layout_file or "state/panel_layout.json"})
layout_store.load()
local topology
local drawn_version,current_layout


local function layout_now()
local graph=topology and topology.graph()
if not graph then return nil end
if drawn_version==graph.version and current_layout then return current_layout end
local data=layout_store.data()
local layout
if data and data.active and data.active.topology_version==graph.version then
layout=data.active
else
local old_graph=topology.previous_graph()
if data and data.active and old_graph and old_graph.version==data.active.topology_version then

local carried=diagram.carry_over(data.active,old_graph,graph)
layout=carried.layout
context.logger.info("layout carried over",{added=#carried.added,changed=#carried.changed,removed=#carried.removed})
else
layout=diagram.propose(graph)
end
layout_store.save({active=layout,previous=data and data.active or nil})
end
drawn_version,current_layout=graph.version,layout
return layout
end


local editor=timetable_editor_mod.new({fs=fs_api,path=panel_cfg.draft_file or "state/panel_timetable_draft.json"})
editor.load()
local request_counter,publish_request=0,nil

local display
if multi then
display=multi_display.new({
registry=registry,level=function()return level end,now=function()return os.time and os.time()or 0 end,
model=function()return state_model.snapshot()end,
layout=layout_now,
faults=function()return faults.list()end,
editor=function()return editor end,
op_text=function()return state_model.snapshot().op_text end
})
end


local function after_results()
local results=(state_model.snapshot().fleet or{}).results or{}
if publish_request and results[publish_request] then
if results[publish_request].ok then editor.reset();editor.save()end
publish_request=nil
end
end

local function draw()
after_results()
if display then
local report=display.refresh()
if#report.missing>0 then
local why={}
for id,text in pairs(report.errors)do why[#why+1]=id .. ": " .. text end
table.sort(why)
context.logger.warn("panel monitors missing",{monitors=table.concat(report.missing,","),errors=table.concat(why,"; ")})
end
else
panel_node.render_status(monitor,state_model.snapshot())
end
end

local node=common_node.new({
id=context.id,
role=context.role,
config=context.config,
modem=context.modem,
logger=context.logger,
clock=context.clock,
start_timer=context.start_timer,
tick_grace=context.tick_grace,
handlers={
on_cmd=function(payload)
local cmd=payload and payload.cmd
offline.heard({id=context.config.master_id,epoch=payload and payload.epoch,authenticated=true})
if cmd=="panel_update" then
state_model.update(payload)
if type(payload.faults)=="table" then faults.sync(payload.faults)end
if topology and payload.topology_version then topology.announce(payload.topology_version)end
elseif cmd=="plan_part" then
if topology then topology.on_part(payload)end
elseif cmd=="set_page" then state_model.set_page(payload.page)
elseif cmd=="next_page" then state_model.next_page()
elseif cmd=="previous_page" then state_model.previous_page()
else return false,"unknown panel cmd: " .. tostring(cmd)end
draw()
return true
end
}
})

topology=topology_sync_mod.new({network=node.net,master_id=context.config.master_id,panel_id=context.id,now=clock,fs=fs_api,path=panel_cfg.topology_file or "state/panel_topology.json"})

node.register=function()
return node.net.send_reliable("register",context.config.master_id,{role="panel",panel_id=context.id,display_name=panel_cfg.display_name or context.id,page=state_model.snapshot().page})
end

node.heartbeat=function()
return node.net.heartbeat(context.config.master_id,{role="panel",panel_id=context.id,display_name=panel_cfg.display_name or context.id,page=state_model.snapshot().page})
end

local function request_snapshot()
node.net.send("event",context.config.master_id,{type="panel_request_snapshot",panel_id=context.id,page=state_model.snapshot().page})
end

local function send_manual_action(action)
if not action then return false end
offline.tick()

local publishing=action.action=="timetable_draft" or action.action=="timetable_publish"
local may,why=offline.may(publishing and "publish" or "control")
if not may then context.logger.warn("panel_offline",{reason=why});return false end
local allowed,denial=permissions.check(context.config,context.id,action.action,{confirm=true})
if not allowed then context.logger.warn("panel_denied",{reason=denial});return false end
if permissions.is_critical(action.action)then
local key=tostring(action.action).. ":" .. tostring(action.train_id or action.node_id or action.id or action.target or "").. ":" .. tostring(action.matches)
if not(pending_confirm and pending_confirm.key==key and clock()- pending_confirm.at<=confirm_window)then
pending_confirm={key=key,at=clock()}
return false
end
pending_confirm=nil
action.confirm=true
end
action.type="manual_control"
action.panel_id=context.id
if publishing then
request_counter=request_counter+1
action.request_id=context.id .. "-" .. tostring(request_counter).. "-" .. tostring(math.floor(clock()))
if action.action=="timetable_draft" then editor.sent(action.request_id)else publish_request=action.request_id end
end

node.net.send_reliable("event",context.config.master_id,action)
return true
end

node.ticker.every("refresh",panel_cfg.refresh_seconds or 2,function()
offline.tick()
request_snapshot()
topology.tick()
draw()
end)

local old_start=node.start
node.start=function()
old_start()
topology.load()
draw()
request_snapshot()
end

node.handlers.on_event=function(event)
if event[1]=="monitor_touch" then
local x=event[3]
local y=event[4]
if display then
local result=display.touch(event[2],x,y)
if result and result.action then send_manual_action(result.action)end
if result and result.edit then
local cmd=result.edit.cmd
if cmd=="adjust" then editor.adjust(result.edit.field,result.edit.delta)
elseif cmd=="reset" then editor.reset()
elseif cmd=="rebase" then editor.rebase(result.edit.version)end
editor.save()
end
if result and result.selected and result.selected.key=="line" and level=="admin" then

local lines=(state_model.snapshot().fleet or{}).lines or{}
local line=lines[result.selected.value]
if line and(not editor.line_id()or not editor.dirty())and editor.line_id()~=result.selected.value then
editor.open(result.selected.value,line)
editor.save()
end
end
if result then request_snapshot();draw()end
return
end
local snapshot=state_model.snapshot()
if y<=3 then
if x<=10 then state_model.previous_page()else state_model.next_page()end
request_snapshot()
draw()
elseif snapshot.page=="manual" then
send_manual_action(state_model.action_at(y))
request_snapshot()
draw()
end
elseif event[1]=="peripheral" or event[1]=="peripheral_detach" then
draw()
end
end

node.offline=offline
node.level=level
node.registry=registry
node.faults=faults
node.topology=topology
node.display=display
node.editor=editor
return node
end

local args=shared_args.parse({...},{config={},id={}})
if args.id then panel_node.new_runtime(bootstrap.create_context({...},"panel")).run()end

return panel_node
