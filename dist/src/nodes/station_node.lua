




local config=require("src.shared.config")
local log=require("src.shared.log")
local shared_args=require("src.shared.args")
local peripherals=require("src.adapter.peripherals")
local monitors=require("src.adapter.monitors")
local hardware_config=require("src.adapter.hardware_config")
local create_sensors=require("src.adapter.create_sensors")
local create_train_schedule=require("src.adapter.create_train_schedule")
local cc_modem=require("src.adapter.cc_modem")
local common_node=require("src.nodes.common_node")
local once_log=require("src.shared.once_log")
local cargo_meter_mod=require("src.domain.cargo_meter")
local bootstrap=require("src.nodes.bootstrap")

local station_node={}


local function destination_name(cfg,station_id,platform_id)
for _,node in ipairs(cfg.nodes or{})do

if node.role=="depot" and(node.depot_id or node.id)==station_id then
for _,track in ipairs(node.tracks or node.slots or{})do
if(track.id or track.track_id or track.name)==platform_id and(track.create_station_name or track.create_destination)then return track.create_station_name or track.create_destination end
end
return node.create_station_name or node.create_destination or station_id
end
if node.role=="station" and(node.station_id or node.id)==station_id then
for _,platform in ipairs(node.platforms or node.tracks or{})do
if(platform.id or platform.track_id or platform.name)==platform_id and(platform.create_station_name or platform.create_destination)then return platform.create_station_name or platform.create_destination end
end
return node.create_station_name or node.create_destination or station_id
end
end
return station_id
end
station_node.destination_name=destination_name

local PLATFORM_EMPTY="EMPTY"
local PLATFORM_OCCUPIED="OCCUPIED"
local PLATFORM_DWELLING="DWELLING"
local PLATFORM_READY="READY_TO_DEPART"
local PLATFORM_FAULT="FAULT"

local function find_station_config(cfg,node_id)
for _,node in ipairs(cfg.nodes or{})do if node.id==node_id then return node end end
return{id=node_id,role="station",station_type="mixed",platforms={}}
end

local function build_context(args_or_context)
if args_or_context.config and args_or_context.logger and args_or_context.peripherals and args_or_context.modem then return args_or_context end
local cfg=config.load(args_or_context.config or "configs/templates/network.example.json")
return{id=args_or_context.id,role="station",config=cfg,logger=log.new("INFO",200),peripherals=peripherals.new(),hardware=hardware_config.new(cfg),modem=cc_modem.for_node(cfg,args_or_context.id)}
end

function station_node.build_platform_map(station_config)
local platforms={}
for _,platform in ipairs(station_config.platforms or station_config.tracks or{})do
local id=platform.id or platform.track_id or platform.name
if id then platforms[id]={id=id,track_id=platform.track_id or id,kind=platform.kind or platform.type or station_config.station_type or "mixed",sensor_id=platform.sensor_id,block_id=platform.block_id,create_station=platform.create_station,dwell_seconds=platform.dwell_seconds or station_config.dwell_seconds or 15,cargo=platform.cargo,state=platform.state or PLATFORM_EMPTY,train_id=platform.train_id,train_name=platform.train_name,occupied_since=nil,last_occupied=false}end
end
return platforms
end

function station_node.render_status(monitor,state)
if not monitor then return end
monitor.clear()
monitor.setCursorPos(1,1);monitor.write("CreateRailNet Station")
monitor.setCursorPos(1,3);monitor.write("Station: " .. tostring(state.station_id or state.node_id or "-"))
monitor.setCursorPos(1,4);monitor.write("Type: " .. tostring(state.station_type or "mixed"))
monitor.setCursorPos(1,5);monitor.write("State: " .. tostring(state.state or "ONLINE"))
local row=7
for platform_id,platform in pairs(state.platforms or{})do monitor.setCursorPos(1,row);monitor.write(platform_id .. " " .. tostring(platform.kind or "mixed").. " " .. tostring(platform.state or "-").. " " .. tostring(platform.train_name or platform.train_id or ""));row=row+1 end
end

local function platform_payload(state,platform)
return{type="platform_status",station_id=state.station_id,platform_id=platform.id,kind=platform.kind,state=platform.state,train_id=platform.train_id,train_name=platform.train_name,block_id=platform.block_id,sensor_id=platform.sensor_id}
end

function station_node.new_runtime(args_or_context)
local context=build_context(args_or_context)
local station_cfg=find_station_config(context.config,context.id)
local station_id=station_cfg.station_id or context.id
local station_type=station_cfg.station_type or station_cfg.type or "mixed"
local display_name=station_cfg.display_name or station_id
local monitor,monitor_note=monitors.resolve(context.peripherals,station_cfg.monitor,station_cfg.monitor_scale)
if monitor_note then context.logger.warn("monitor",{note=monitor_note})end
local sensor_adapter=create_sensors.new(context.peripherals,{hardware=context.hardware})
local schedule_adapter=create_train_schedule.new(context.peripherals,{hardware=context.hardware})
local state={node_id=context.id,station_id=station_id,display_name=display_name,station_type=station_type,state="ONLINE",platforms=station_node.build_platform_map(station_cfg)}

local node=common_node.new({id=context.id,role=context.role,config=context.config,modem=context.modem,logger=context.logger,clock=context.clock,start_timer=context.start_timer,tick_grace=context.tick_grace,journal_fs=context.journal_fs,fence_fs=context.fence_fs,handlers={on_cmd=function(payload)
local cmd=payload and payload.cmd
local platform=payload and payload.platform_id and state.platforms[payload.platform_id]
if cmd=="reserve_platform" and platform then platform.state="RESERVED";platform.train_id=payload.train_id;platform.train_name=payload.train_name
elseif cmd=="clear_platform" and platform then platform.state=PLATFORM_EMPTY;platform.train_id=nil;platform.train_name=nil;platform.occupied_since=nil
elseif cmd=="mark_ready_departure" and platform then
platform.state=PLATFORM_READY;platform.occupied_since=nil;platform.train_id=payload.train_id or platform.train_id;platform.train_name=payload.train_name or platform.train_name
node.net.send_reliable("event",context.config.master_id,{type="station_ready_departure",station_id=station_id,platform_id=platform.id,train_id=platform.train_id,train_name=platform.train_name,route_id=payload.route_id,destination=payload.destination})
elseif cmd=="set_station_message" then state.message=payload.message
elseif cmd=="apply_schedule" then

local origin
for _,candidate in pairs(state.platforms)do
if candidate.create_station and(candidate.train_id==payload.train_id or candidate.train_name==payload.train_id)then origin=candidate end
end
if not origin then return false,"train " .. tostring(payload.train_id).. " is not on a platform with a Create station here" end
local destination=destination_name(context.config,payload.destination,payload.platform)
local ok,err=schedule_adapter.apply_stops(payload.train_id,{{create_destination=destination,dwell_seconds=origin.dwell_seconds}},{station=origin.create_station})
if not ok then return false,tostring(err)end
return true
else return false,"unknown station cmd: " .. tostring(cmd)end
station_node.render_status(monitor,state)
return true
end}})

local function station_status_payload(reason)
return{role="station",station_id=station_id,display_name=display_name,station_type=station_type,state=state.state,reconnect_reason=reason,platforms=state.platforms}
end

local function send_platform(platform)node.net.send_reliable("event",context.config.master_id,platform_payload(state,platform))end

local function send_full_status(reason)
node.net.send_reliable("register",context.config.master_id,station_status_payload(reason))
node.net.send("event",context.config.master_id,{type="station_status",station_id=station_id,station_type=station_type,display_name=display_name,state=state.state,reconnect_reason=reason})
for _,platform in pairs(state.platforms or{})do node.net.send("event",context.config.master_id,platform_payload(state,platform))end
end

node.station_state=state
node.register=function()return send_full_status("register")end
node.heartbeat=function()return node.net.heartbeat(context.config.master_id,station_status_payload("heartbeat"))end

local function read_train_name(platform)
local ok,train_name=sensor_adapter.readTrainName(platform.sensor_id)
if ok and train_name and train_name~="" then return train_name end
return platform.train_name or platform.train_id
end



local meter=cargo_meter_mod.new({peripheral=context.peripheral_api or _G.peripheral,now=function()return(context.clock or os.clock)()end})
local function report_cargo(platform,result,train_id)
local targets=(find_station_config(context.config,context.id).cargo_report_to)or{}
local ev={type="cargo_measure",station=station_id,platform=platform.id,train_id=train_id,kind=platform.cargo.kind}
if result.ok then ev.qty,ev.quality,ev.ref=result.qty,result.quality,result.ref else ev.failed,ev.reason=true,result.reason end
for _,target in ipairs(targets)do node.net.send_reliable("event",target,{type="fleet_event",ev=ev})end
if not result.ok then context.logger.warn("loading point: no measurement",{platform=platform.id,reason=result.reason})end
end


local fault_once=once_log.new(context.logger,{repeat_ms=30000})

local function check_platforms()
for _,platform in pairs(state.platforms)do
if platform.sensor_id then
local ok,occupied=sensor_adapter.readOccupied(platform.sensor_id)
if ok and platform.state==PLATFORM_FAULT then

platform.state=platform.state_before_fault or PLATFORM_EMPTY
platform.state_before_fault=nil
fault_once.ok("platform:" .. platform.id,"platform sensor " .. tostring(platform.sensor_id).. " answers again")
send_platform(platform)
end
if ok then
if occupied~=platform.last_occupied then
platform.last_occupied=occupied
if occupied then
platform.train_name=read_train_name(platform);platform.train_id=platform.train_id or platform.train_name;platform.state=PLATFORM_DWELLING;platform.occupied_since=os.clock()
node.net.send_reliable("event",context.config.master_id,{type="train_arrived_station",station_id=station_id,platform_id=platform.id,train_id=platform.train_id,train_name=platform.train_name,block_id=platform.block_id})
if platform.cargo then
local started,why=meter.begin(station_id .. "/" .. platform.id,platform.cargo.inventory,platform.cargo.item)
if not started then report_cargo(platform,{ok=false,reason=why},platform.train_id)end
end
else
local leaving_train_id=platform.train_id;local leaving_train_name=platform.train_name
node.net.send_reliable("event",context.config.master_id,{type="train_left_station",station_id=station_id,platform_id=platform.id,train_id=leaving_train_id,train_name=leaving_train_name,block_id=platform.block_id})

if platform.cargo and meter.pending(station_id .. "/" .. platform.id)then
report_cargo(platform,meter.finish(station_id .. "/" .. platform.id,platform.cargo.kind),leaving_train_id or leaving_train_name)
end
platform.state=PLATFORM_EMPTY;platform.train_id=nil;platform.train_name=nil;platform.occupied_since=nil
end
send_platform(platform)
elseif occupied and platform.state==PLATFORM_DWELLING and platform.occupied_since and os.clock()- platform.occupied_since>=platform.dwell_seconds then
platform.state=PLATFORM_READY
node.net.send_reliable("event",context.config.master_id,{type="station_ready_departure",station_id=station_id,platform_id=platform.id,train_id=platform.train_id,train_name=platform.train_name,block_id=platform.block_id})
send_platform(platform)
end
else
if platform.state~=PLATFORM_FAULT then platform.state_before_fault=platform.state end
platform.state=PLATFORM_FAULT
if fault_once.first("platform:" .. platform.id)then
node.net.send("event",context.config.master_id,{type="station_fault",station_id=station_id,platform_id=platform.id,error=occupied})
end
end
end
end
end

node.ticker.every("platforms",0.5,function()check_platforms();station_node.render_status(monitor,state)end)

local old_start=node.start
node.start=function()
old_start();station_node.render_status(monitor,state);send_full_status("start")
end

return node
end

local args=shared_args.parse({...},{config={},id={}})
if args.id then station_node.new_runtime(bootstrap.create_context({...},"station")).run()end

return station_node
