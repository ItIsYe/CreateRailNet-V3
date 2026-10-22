









local util=require("src.shared.util")
local block_domain=require("src.domain.blocks")
local topology=require("src.domain.topology")
local signal_logic=require("src.domain.signal_logic")
local route_queue=require("src.domain.route_queue")
local switch_locks=require("src.domain.switch_locks")
local interlocking_module=require("src.domain.interlocking")
local sensor_guard_module=require("src.domain.sensor_guard")
local safety_graph=require("src.domain.safety_graph")
local occupancy_module=require("src.domain.occupancy")
local phase_module=require("src.domain.reservation_phase")
local deadlock_module=require("src.domain.deadlock")

local dispatcher={}
local STATES=block_domain.STATES
local TRAIN_STATES={QUEUED="QUEUED",RESERVED="RESERVED",RUNNING="RUNNING",WAITING="WAITING",ARRIVED="ARRIVED",FAULT="FAULT"}

local function copy_table(src)
local dst={}
for k,v in pairs(src or{})do if type(v)=="table" then dst[k]=copy_table(v)else dst[k]=v end end
return dst
end


local function sorted_keys(t)
local keys={}
for key in pairs(t or{})do keys[#keys+1]=key end
table.sort(keys,function(a,b)return tostring(a)<tostring(b)end)
return keys
end

local function sort_pair(a,b)
a=tostring(a or "")
b=tostring(b or "")
if a<b then return a .. "<->" .. b end
return b .. "<->" .. a
end

local function route_direction(route)
return tostring(route.from or "?").. "->" .. tostring(route.to or "?")
end

local function route_conflict_groups(route)
local groups={}
if route.conflict_group then table.insert(groups,route.conflict_group)end
if route.conflict_groups then for _,group in ipairs(route.conflict_groups)do table.insert(groups,group)end end



if route.from and route.to then
table.insert(groups,"opp:" .. sort_pair(route.from,route.to))
end

for _,block_id in ipairs(route.blocks or{})do table.insert(groups,"block:" .. tostring(block_id))end
return groups
end


local function same_direction(route_a,route_b)
return route_a.from==route_b.from and route_a.to==route_b.to
end

function dispatcher.new(config,adapters)
local sw_locks=switch_locks.new()
local self={blocks=block_domain.build_map(config.blocks),routes=util.index_by(config.routes or{},"id"),trains={},adapters=adapters or{},queue=route_queue.new(),switch_locks=sw_locks,active_routes={},active_conflicts={},deadlocks={}}
self.sensor_to_block=topology.build_sensor_to_block(self.blocks)
self.interlocking=interlocking_module.new(config,sw_locks,self.blocks)
self.sensor_guard=sensor_guard_module.new(config)
self.proof=config.occupancy_proof=="on"
self.graph=safety_graph.build(config)
self.occupancy=occupancy_module.new({blocks=sorted_keys(self.blocks)})
self.clearing={}
self.commit_required=false
local function now_ms()
if self.adapters.now_ms then return self.adapters.now_ms()end
return math.floor(os.clock()*1000)
end
local function advance_phase(train,to)
if train and train.phase_rec then return phase_module.advance(train.phase_rec,to)end
return false
end

local function signal_adapter()return self.adapters.signals end
local function switch_adapter()return self.adapters.switches end
local function set_switch(switch_id,position)if not switch_adapter()then return true end;return switch_adapter().setPosition(switch_id,position)end
local function set_signal(signal_id,aspect)if not signal_id then return true end;return signal_logic.set_aspect(signal_id,aspect,signal_adapter())end


local function set_proceed_aspect(signal_id,aspect)
if not signal_id then return true end
if aspect~="RED" then
local allowed,why=self.interlocking.is_signal_green_allowed(signal_id)
if not allowed then
set_signal(signal_id,"RED")
return false,"interlocking refuses " .. tostring(aspect).. " on " .. tostring(signal_id).. ": " .. tostring(why)
end
end
return set_signal(signal_id,aspect)
end
local function set_block_red(block)
local ok,err=signal_logic.set_block_red(block,signal_adapter())
if not ok and block then

if block.state~=STATES.FAULT then block.fault_cause={kind="signal"}end
block_domain.fault(block)
self.occupancy.set_flag(block.id,"fault",true)
if self.logger then self.logger.warn("set_block_red hardware failure",{block=block.id,error=err})end
end
return ok,err
end

local function mark_fault(block,cause)
if block.state~=STATES.FAULT then block.fault_cause={kind=cause or "event"}end
block_domain.fault(block)
self.occupancy.set_flag(block.id,"fault",true)
set_block_red(block)
end
local function route_owner(train_id,route_id)return tostring(train_id).. ":" .. tostring(route_id)end
local function get_route(_,route_id)local route=self.routes[route_id];if not route then return nil,"route not found" end;return route end

local function conflict_reason(route,train_id)
local groups=route_conflict_groups(route)
for _,group in ipairs(groups)do
local active=self.active_conflicts[group]
if active and active.train_id~=train_id then
if string.sub(group,1,4)=="opp:" then

local active_route=self.routes[active.route_id]
local is_same_dir=active_route and same_direction(active_route,route)
if not is_same_dir then
return false,"opposite direction conflict: " .. tostring(group),{active.train_id},group
end

else

return false,"route conflict group busy: " .. tostring(group),{active.train_id},group
end
end
end
return true,nil,nil,nil
end

local function lock_conflicts(route,train)
for _,group in ipairs(route_conflict_groups(route))do self.active_conflicts[group]={owner=train.owner,train_id=train.id,route_id=train.route,direction=train.direction}end
end



local function other_holder(group,leaving)
for _,owner in ipairs(sorted_keys(self.active_routes))do
local other=self.active_routes[owner]
if other~=leaving and(other.state==TRAIN_STATES.RESERVED or other.state==TRAIN_STATES.RUNNING)then
for _,held in ipairs(other.conflict_groups or{})do if held==group then return other end end
end
end
return nil
end

local function release_conflicts(train)
if not train then return end
for group,active in pairs(self.active_conflicts)do
if active.owner==train.owner then
local heir=string.sub(group,1,4)=="opp:" and other_holder(group,train)or nil
if heir then
self.active_conflicts[group]={owner=heir.owner,train_id=heir.id,route_id=heir.route,direction=heir.direction}
else
self.active_conflicts[group]=nil
end
end
end
end

local function blocked_by_blocks(route)
local out={}
for _,block_id in ipairs(route.blocks or{})do local block=self.blocks[block_id];if block and not block_domain.is_free(block)then table.insert(out,block.reserved_by or block.occupied_by or block_id)end end
return out
end

local function collect_route_blocks(route,train_id)
local touched={}
for _,block_id in ipairs(route.blocks or{})do
local block=self.blocks[block_id]
if not block then return nil,"block not found: " .. tostring(block_id),nil end

if block.state==STATES.FAULT or(not block_domain.is_free(block)and block.reserved_by~=train_id)then return nil,"block not free: " .. tostring(block_id),blocked_by_blocks(route)end
if self.proof and block.reserved_by~=train_id then
local proven,why=self.occupancy.is_free(block_id)
if not proven then return nil,"block not proven free: " .. tostring(why),blocked_by_blocks(route)end
end
table.insert(touched,block)
end
return touched
end

local function collect_switch_requirements(route_blocks)
local requirements,seen={},{}
for _,block in ipairs(route_blocks or{})do
for _,switch_def in ipairs(block.switches or{})do
local key=tostring(switch_def.id)
if not seen[key] then table.insert(requirements,{id=switch_def.id,position=switch_def.position});seen[key]=true end
end
end
return requirements
end

local function apply_switches(requirements)
for _,req in ipairs(requirements or{})do local ok,err=set_switch(req.id,req.position);if not ok then return false,"switch set failed: " .. tostring(req.id).. ": " .. tostring(err)end end
return true
end

local function reserve_blocks(route_blocks,train_id)for _,block in ipairs(route_blocks)do block_domain.reserve(block,train_id);set_block_red(block)end end
local function release_blocks(route_blocks)for _,block in ipairs(route_blocks)do block_domain.release(block);set_block_red(block)end end



local function waiting_aspect(train)
if not train or not train.route_blocks or train.state~=TRAIN_STATES.RESERVED then return nil end
local current_index=train.route_index or 1
local next_block=train.route_blocks[current_index]
if not(next_block and next_block.state==STATES.RESERVED and next_block.reserved_by==train.id)then return nil end
local lookahead=train.route_blocks[current_index+1]
local aspect="GREEN"
if lookahead and lookahead.state~=STATES.FREE and lookahead.reserved_by~=train.id then aspect="YELLOW" end
return next_block,aspect
end

local function update_route_signals(train)
if not train or not train.route_blocks then return true end

for _,block in ipairs(train.route_blocks)do
local holder=block.reserved_by or block.occupied_by
if holder==nil or holder==train.id then set_block_red(block)end
end
local next_block,aspect=waiting_aspect(train)
if next_block then

if train.gated and train.phase_rec and not phase_module.may_actuate(train.phase_rec.phase)then
return set_proceed_aspect(next_block.entry_signal,"RED")
end
local ok,err=set_proceed_aspect(next_block.entry_signal,aspect)
if ok~=false and aspect~="RED" and train.phase_rec and train.phase_rec.phase=="ACTUATION_ELIGIBLE" then advance_phase(train,"ACTUATED")end
return ok,err
end
return true
end

local function rebuild_route_blocks(route_id)
local route=self.routes[route_id]
local blocks={}
for _,block_id in ipairs((route and route.blocks)or{})do if self.blocks[block_id] then table.insert(blocks,self.blocks[block_id])end end
return blocks
end



local function sweep_held_blocks(train)
for _,block in ipairs(train.route_blocks or{})do
if block.state~=STATES.FAULT and(block.reserved_by==train.id or block.occupied_by==train.id)then
if self.proof and block.state==STATES.OCCUPIED then
set_block_red(block)
else
block_domain.release(block)
set_block_red(block)
end
end
end
end


local function close_account(train)
local rec=train.phase_rec
if not rec then return end
if not phase_module.can(rec.phase,"CLEARANCE_PENDING")then
if phase_module.can(rec.phase,"FAULT")then phase_module.advance(rec,"FAULT")end
end
phase_module.advance(rec,"CLEARANCE_PENDING")
local open={}
for _,block in ipairs(train.route_blocks or{})do
local held=block.reserved_by==train.id or block.occupied_by==train.id
if held or not self.occupancy.is_free(block.id)then open[block.id]=true end
end
if next(open)==nil then
phase_module.advance(rec,"RELEASED_PROVEN")
self.clearing[train.id]=nil
elseif self.proof then
self.clearing[train.id]={rec=rec,blocks=open}
end
end

local function settle_clearing()
for train_id,record in pairs(self.clearing)do
for block_id in pairs(record.blocks)do
local block=self.blocks[block_id]
local held=block and(block.reserved_by==train_id or block.occupied_by==train_id)
if not held and self.occupancy.is_free(block_id)then record.blocks[block_id]=nil end
end
if next(record.blocks)==nil then
phase_module.advance(record.rec,"RELEASED_PROVEN")
self.clearing[train_id]=nil
end
end
end

local function finish_train(train)
sweep_held_blocks(train)
train.state=TRAIN_STATES.ARRIVED
train.current_block=nil
train.route_index=#(train.route_blocks or{})+1
self.switch_locks.release_by_route(train.owner)
self.interlocking.cancel_route(train.route,train.owner)
release_conflicts(train)
self.active_routes[train.owner]=nil
close_account(train)
end

local function record_deadlock(item,err)
self.deadlocks[item.train_id]={train_id=item.train_id,route_id=item.route_id,reason=err,attempts=item.attempts or 0,blocked_by=item.blocked_by,conflict_group=item.conflict_group}
end


function self.reserve_route(train_id,route_id,opts)
local route,route_err=get_route(train_id,route_id)
if not route then return false,route_err end
if self.proof then

local ends,why=self.graph.route_end(route_id,{length=opts and opts.length})
if not ends then return false,why end
end
local existing=self.trains[train_id]
if existing and existing.state==TRAIN_STATES.FAULT then


self.release_route(train_id,existing.route)
end
if existing and(existing.state==TRAIN_STATES.RESERVED or existing.state==TRAIN_STATES.RUNNING)then
if existing.route==route_id then return true end
if existing.state==TRAIN_STATES.RESERVED and(existing.route_index or 1)==1 and not(opts and opts.queued)then

self.release_route(train_id,existing.route)
else
return false,"train busy: active route " .. tostring(existing.route),{train_id}
end
end
local ok_conflict,conflict_err,conflict_blockers,conflict_group=conflict_reason(route,train_id)
if not ok_conflict then return false,conflict_err,conflict_blockers,conflict_group end
local route_blocks,collect_err,blockers=collect_route_blocks(route,train_id)
if not route_blocks then return false,collect_err,blockers end
local owner=route_owner(train_id,route_id)
local switch_requirements=collect_switch_requirements(route_blocks)
local ok_lock,lock_err=self.switch_locks.lock_many(switch_requirements,owner)
if not ok_lock then return false,lock_err end
local ok_switch,switch_err=apply_switches(switch_requirements)
if not ok_switch then self.switch_locks.release_by_route(owner);for _,block in ipairs(route_blocks)do set_block_red(block)end;return false,switch_err end


local function undo_interlocking()self.interlocking.cancel_route(route_id,owner);self.switch_locks.release_by_route(owner)end
local ok_il,il_err=self.interlocking.set_route(route_id,{owner=owner,train_id=train_id})
if not ok_il then
undo_interlocking()
for _,block in ipairs(route_blocks)do set_block_red(block)end
return false,"interlocking: " .. tostring(il_err)
end
local ok_flank,flank_err=apply_switches(self.interlocking.flank_switches(route_id))
if not ok_flank then
undo_interlocking()
for _,block in ipairs(route_blocks)do set_block_red(block)end
return false,flank_err
end
local route_def=self.interlocking.get_route(route_id)
if route_def and route_def.overlap_block then set_block_red(self.blocks[route_def.overlap_block])end
reserve_blocks(route_blocks,train_id)
local train={id=train_id,route=route_id,owner=owner,state=TRAIN_STATES.RESERVED,route_blocks=route_blocks,route_index=1,current_block=nil,destination=route.to,from=route.from,priority=route.priority or 0,direction=route_direction(route),conflict_groups=route_conflict_groups(route)}
train.length=opts and opts.length or nil
train.phase_rec=phase_module.new()
advance_phase(train,"VALIDATED")
train.gated=self.commit_required
if not train.gated then

advance_phase(train,"PREPARED_BOTH_DURABLE");advance_phase(train,"COMMITTED_BOTH_DURABLE");advance_phase(train,"ACTUATION_ELIGIBLE")
end
self.clearing[train_id]=nil
self.trains[train_id]=train
self.active_routes[owner]=train
lock_conflicts(route,train)
self.deadlocks[train_id]=nil
local ok_signal,signal_err=update_route_signals(train)
if not ok_signal then release_blocks(route_blocks);undo_interlocking();release_conflicts(train);self.trains[train_id]=nil;self.active_routes[owner]=nil;return false,"signal set failed: " .. tostring(signal_err)end
return true
end


local function try_alternatives(train_id,route,options)
for _,alt_id in ipairs(route and route.alternatives or{})do
local alt=self.routes[alt_id]
if alt and alt.reachability_confirmed and alt.from==route.from and alt.to==route.to then
if self.reserve_route(train_id,alt_id,options)then return alt_id end
end
end
return nil
end

function self.request_route(train_id,route_id,opts)
local options=opts or{}
local ok,err,blockers,conflict_group=self.reserve_route(train_id,route_id,options)
if ok then return true,"reserved" end
local route=self.routes[route_id]
if try_alternatives(train_id,route,options)then return true,"reserved" end
local queued=self.queue.find(train_id,route_id)
if queued then
queued.reason=err;queued.blocked_by=blockers;queued.conflict_group=conflict_group or queued.conflict_group
else
queued=self.queue.push({train_id=train_id,route_id=route_id,from=route and route.from,to=route and route.to,direction=route and route_direction(route),conflict_group=conflict_group,priority=options.priority or(route and route.priority)or 0,reason=err,blocked_by=blockers,length=options.length})
end
local record=self.trains[train_id]

if not(record and(record.state==TRAIN_STATES.RESERVED or record.state==TRAIN_STATES.RUNNING))then
record=record or{id=train_id}
self.trains[train_id]=record
record.state=TRAIN_STATES.QUEUED
record.route=route_id
record.direction=route and route_direction(route)or nil
end
self.detect_deadlocks()
return false,"queued",queued
end

function self.process_queue(limit)
local processed={}
local max=limit or self.queue.size()
for _=1,max do
local item=self.queue.pop()
if not item then break end
local ok,err,blockers,conflict_group=self.reserve_route(item.train_id,item.route_id,{queued=true,length=item.length})
if not ok and try_alternatives(item.train_id,self.routes[item.route_id],{queued=true,length=item.length})then ok,err=true,nil end
table.insert(processed,{train_id=item.train_id,route_id=item.route_id,ok=ok,error=err,blocked_by=blockers,attempts=item.attempts,conflict_group=conflict_group})
if not ok then
item.reason=err;item.blocked_by=blockers;item.conflict_group=conflict_group or item.conflict_group;item.attempts=(item.attempts or 0)+1
if item.attempts>=3 then record_deadlock(item,err)end
self.queue.push(item)

end
end
self.detect_deadlocks()
return processed
end


local function stands_still(train_id)
local train=self.trains[train_id]
if not train or not train.owner or self.active_routes[train.owner]~=train then return true end
local last=train.route_blocks and train.route_blocks[#train.route_blocks]
return last~=nil and train.current_block==last.id
end



function self.detect_deadlocks()
local items={}
for _,item in ipairs(self.queue.list())do
if stands_still(item.train_id)then
local waits,seen={},{}
local route=self.routes[item.route_id]
for _,block_id in ipairs(route and route.blocks or{})do
local block=self.blocks[block_id]
local holder=block and(block.reserved_by or block.occupied_by)
if holder and holder~=item.train_id and not seen[holder] and stands_still(holder)then seen[holder]=true;waits[#waits+1]=holder end
end
items[#items+1]={train_id=item.train_id,blocked_by=waits,route_id=item.route_id}
end
end
local cycles=deadlock_module.find_cycles(items)
local found={}
for _,cycle in ipairs(cycles)do
for _,train_id in ipairs(cycle)do
local route_id
for _,item in ipairs(items)do if item.train_id==train_id then route_id=item.route_id end end
found[train_id]=true
local old=self.deadlocks[train_id]
if not(old and old.reason=="deadlock cycle")then
if self.logger then self.logger.warn("deadlock",{train=train_id,cycle=table.concat(cycle,">")})end
end
self.deadlocks[train_id]={train_id=train_id,route_id=route_id,reason="deadlock cycle",cycle=copy_table(cycle),attempts=0}
end
end
for train_id,record in pairs(self.deadlocks)do
if record.reason=="deadlock cycle" and not found[train_id] then self.deadlocks[train_id]=nil end
end
return cycles
end

local function train_for_block(block)
if not block then return nil end
local owner=block.reserved_by or block.occupied_by
if not owner then return nil end
return self.trains[owner]
end

function self.on_sensor_event_by_sensor(sensor_id,action,ts)
local block_id=topology.block_for_sensor(self.sensor_to_block,sensor_id)
if not block_id then return false,"unknown sensor: " .. tostring(sensor_id)end
return self.on_sensor_event(block_id,action,sensor_id,ts)
end

function self.on_sensor_event(block_id,action,sensor_id,ts)
local block=self.blocks[block_id]
if not block then return false,"block not found" end
local guard=self.sensor_guard

if action=="enter" then

local ok,err=guard.validate_enter(block_id,sensor_id,ts)
if not ok then
if self.logger then self.logger.warn("sensor enter rejected",{block=block_id,reason=err})end
return false,"sensor guard: " .. tostring(err)
end
guard.record_enter(block_id,ts)
guard.detect_direction(block_id,sensor_id)

if block.overlap_for and block.state==STATES.RESERVED then

block.overlap_for=nil
mark_fault(block)
if self.logger then self.logger.warn("overlap block entered",{block=block_id})end
return false,"overlap block entered: " .. block_id
end
if block.state==STATES.RESERVED then
local train=train_for_block(block)
local occupying_train=(train and train.id)or block.reserved_by
block_domain.occupy(block,occupying_train)
self.occupancy.observe(block_id,"OCCUPIED_PROVEN","enter_sensor",{at=now_ms(),train_id=occupying_train})
if train then
if train.phase_rec and train.phase_rec.phase=="ACTUATION_ELIGIBLE" then advance_phase(train,"ACTUATED")end
advance_phase(train,"IN_PROGRESS")
end

if train and train.route then self.interlocking.enter_route(train.route,train.owner)end
if train then

local index=nil
for i,route_block in ipairs(train.route_blocks or{})do if route_block.id==block_id then index=i end end
train.state=TRAIN_STATES.RUNNING
if index and index>=(train.route_index or 1)then train.route_index=index;train.current_block=block_id
elseif not train.current_block then train.current_block=block_id end
update_route_signals(train)
end
return true
end
self.occupancy.observe(block_id,"OCCUPIED_PROVEN","enter_sensor",{at=now_ms()})
mark_fault(block);return false,"unexpected enter on block " .. block_id
elseif action=="leave" then

local tail_ok=sensor_id==nil
for _,tail in ipairs(self.graph.tail_sensors(block_id))do if tail==sensor_id then tail_ok=true end end
if self.proof and not tail_ok then return false,"leave from " .. tostring(sensor_id).. " is not a tail sensor of " .. block_id .. ": the end of the train is not proven" end
local enter_time=guard.get_enter_time(block_id)
local ok,err=guard.validate_leave(block_id,sensor_id,ts,enter_time)
if not ok then
if self.logger then self.logger.warn("sensor leave rejected",{block=block_id,reason=err})end
return false,"sensor guard: " .. tostring(err)
end
guard.record_leave(block_id,ts)

if block.state==STATES.OCCUPIED then
local train=train_for_block(block)

if train and not train.owner then train=nil end
block_domain.release(block);set_block_red(block)
if tail_ok then self.occupancy.observe(block_id,"FREE_PROVEN","tail_sensor",{at=now_ms()})else self.occupancy.suspect(block_id,"leave without a tail sensor")end

if train and train.route then self.interlocking.section_free(train.route,block_id,train.owner)end
if train and train.current_block~=nil and train.current_block~=block_id then

update_route_signals(train)
elseif train then
local next_index=(train.route_index or 1)+1;train.route_index=next_index;train.current_block=nil
if next_index>#(train.route_blocks or{})then finish_train(train)else train.state=TRAIN_STATES.RESERVED;update_route_signals(train)end
end
settle_clearing()
self.process_queue(1)
return true
end
mark_fault(block);return false,"unexpected leave on block " .. block_id
end
return false,"unknown action"
end

local function train_references_node(train,node_id)
if train.id==node_id then return true end
for _,b in ipairs(train.route_blocks or{})do
if topology.references_node(b,node_id)then return true end
end
return false
end

function self.timeout_node(node_id)

for _,block in pairs(self.blocks)do
if topology.references_node(block,node_id)then
mark_fault(block,"node_timeout")
local cause=block.fault_cause

if cause and cause.kind=="node_timeout" then
cause.nodes=cause.nodes or{}
cause.nodes[node_id]=true
cause.recovered_at=nil
end
end
end

for _,train in pairs(self.trains)do
if train_references_node(train,node_id)then
train.state=TRAIN_STATES.FAULT
self.queue.remove_train(train.id)

for _,block in ipairs(train.route_blocks or{})do
if block.reserved_by==train.id or block.occupied_by==train.id then set_block_red(block)end
end


end
end
end


function self.set_signal(signal_id,aspect)
if not signal_id then return false,"missing signal_id" end
local target_aspect=aspect or "RED"
if target_aspect~="RED" then
local allowed,route_id=self.interlocking.is_signal_green_allowed(signal_id)
if not allowed then
return false,"SICHERHEIT: Signal " .. tostring(signal_id).. " darf nicht auf " .. target_aspect .. " gestellt werden — keine aktive Fahrstrasse. (" .. tostring(route_id).. ")"
end
end
return signal_logic.set_aspect(signal_id,target_aspect,signal_adapter())
end

function self.set_switch(switch_id,position)
if not switch_id or not position then return false,"missing switch_id or position" end
local ok,err=switch_adapter().setPosition(switch_id,position)
return ok,err
end

function self.release_route(train_id,route_id)
local train=self.trains[train_id]
if not train then return false,"train not found" end

sweep_held_blocks(train)
close_account(train)
if train.owner then
self.switch_locks.release_by_route(train.owner)
self.interlocking.cancel_route(train.route,train.owner)
release_conflicts(train)
self.active_routes[train.owner]=nil
end
self.trains[train_id]=nil

for _,item in ipairs(self.queue.list())do
if item.train_id==train_id then
self.trains[train_id]={id=train_id,state=TRAIN_STATES.QUEUED,route=item.route_id,direction=item.direction}
break
end
end

return true
end



function self.clear_fault(block_id)
local block=self.blocks[block_id]
if not block then return false,"block not found" end
if block.state~=STATES.FAULT then return false,"block is not in FAULT" end
local owner=block.reserved_by or block.occupied_by
local train=owner and self.trains[owner]
if train and(train.state==TRAIN_STATES.RESERVED or train.state==TRAIN_STATES.RUNNING)then
return false,"block belongs to train " .. tostring(owner).. " on its way; release the train first"
end
block_domain.release(block)

self.occupancy.set_flag(block_id,"fault",false)
local ok,err=set_block_red(block)
if not ok then return false,"signal hardware failure: " .. tostring(err)end
return true
end










function self.auto_clear_faults(ctx)
local cleared={}
local stable=ctx.stable_s or 15
local max_age=ctx.max_age_s or 10

local function sensors_free(block,since)
if#(block.sensors or{})==0 then return false end
for _,sensor_id in ipairs(block.sensors)do
local occupied,at=ctx.sensor_level(sensor_id)
if occupied~=false or at==nil or at<since or ctx.now - at>max_age then return false end
end
return true
end

local ready={}
for _,block_id in ipairs(sorted_keys(self.blocks))do
local block=self.blocks[block_id]
local cause=block.state==STATES.FAULT and block.fault_cause or nil
if cause and cause.kind=="node_timeout" then
local all_up=true
for _,node_id in ipairs(sorted_keys(cause.nodes))do if not ctx.node_up(node_id)then all_up=false end end
if not all_up then
cause.recovered_at=nil
else
cause.recovered_at=cause.recovered_at or ctx.now
if ctx.now - cause.recovered_at>=stable and sensors_free(block,cause.recovered_at)then ready[block_id]=true end
end
end
end

local released={}
for _,block_id in ipairs(sorted_keys(ready))do
local block=self.blocks[block_id]
local owner=block.reserved_by or block.occupied_by
local train=owner and self.trains[owner]
local go=true
if train and(train.state==TRAIN_STATES.RESERVED or train.state==TRAIN_STATES.RUNNING)then
go=false
elseif train and train.state==TRAIN_STATES.FAULT and train.owner and self.active_routes[train.owner]==train then
if released[owner]==nil then
local verified=true
for _,route_block in ipairs(train.route_blocks or{})do
if route_block.reserved_by==owner or route_block.occupied_by==owner then
if route_block.state==STATES.FAULT then
if not ready[route_block.id] then verified=false end
elseif not sensors_free(route_block,0)then
verified=false
end
end
end
released[owner]=verified
if verified then self.release_route(owner,train.route)end
end
go=released[owner]
end
if go then

block.reserved_by=nil
block.occupied_by=nil
local ok=self.clear_fault(block_id)
if ok then

self.occupancy.observe(block_id,"FREE_PROVEN","sensor_level",{at=now_ms()})
cleared[#cleared+1]={block=block_id,train=train and owner or nil}
end
end
end
return cleared
end




local signal_order=sorted_keys(self.blocks)
local signal_cursor=0

local function refresh_block(block)
local aspect="RED"
local owner=block.state==STATES.RESERVED and block.reserved_by or nil
if owner then
local next_block,wanted=waiting_aspect(self.trains[owner])
if next_block==block then aspect=wanted end
end
local ok1=set_proceed_aspect(block.entry_signal,aspect)
local ok2=set_signal(block.exit_signal,"RED")
return ok1~=false and ok2~=false
end


function self.refresh_signals(limit)
local count=#signal_order
local result={sent=0,failed=0,failed_blocks={}}
for _=1,math.min(limit or count,count)do
signal_cursor=signal_cursor%count+1
local block=self.blocks[signal_order[signal_cursor]]
result.sent=result.sent+1
if not refresh_block(block)then
result.failed=result.failed+1
result.failed_blocks[#result.failed_blocks+1]=block.id
end
end
return result
end


function self.resend_signals(node_id)
local result={sent=0,failed=0,failed_blocks={}}
for _,block_id in ipairs(signal_order)do
local block=self.blocks[block_id]
if block.entry_signal==node_id or block.exit_signal==node_id then
result.sent=result.sent+1
if not refresh_block(block)then
result.failed=result.failed+1
result.failed_blocks[#result.failed_blocks+1]=block_id
end
end
end
return result
end



function self.shutdown_red()
local failed=0
for _,block_id in ipairs(signal_order)do
local block=self.blocks[block_id]
for _,signal_id in ipairs({block.entry_signal or false,block.exit_signal or false})do
if signal_id then
local ok,result=pcall(set_signal,signal_id,"RED")
if not ok or result==false then failed=failed+1 end
end
end
end
return failed
end

function self.get_overview()
local summary={}
for id,block in pairs(self.blocks)do
local route_id,route_state=self.interlocking.route_for_block(id)
summary[id]={
state=block.state,
reserved_by=block.reserved_by,
occupied_by=block.occupied_by,
interlocking_route=route_id,
interlocking_state=route_state,
}
end
return summary
end
function self.get_interlocking()return self.interlocking.list()end
function self.get_block(id)return self.blocks[id] end
function self.get_trains()local out={};for id,train in pairs(self.trains)do out[id]={id=train.id,route=train.route,state=train.state,holds_route=train.owner~=nil and self.active_routes[train.owner]==train,route_index=train.route_index,current_block=train.current_block,destination=train.destination,priority=train.priority,direction=train.direction,conflict_groups=copy_table(train.conflict_groups),phase=train.phase_rec and train.phase_rec.phase or nil,length=train.length,entry_idx=train.entry_idx}end;return out end
function self.get_queue()return self.queue.list()end
function self.get_switch_locks()return self.switch_locks.list()end
function self.get_conflicts()return copy_table(self.active_conflicts)end
function self.get_deadlocks()return self.deadlocks end


function self.signal_failed(signal_id,reason)
local changed={}
for _,block_id in ipairs(sorted_keys(self.blocks))do
local block=self.blocks[block_id]
if block.entry_signal==signal_id or block.exit_signal==signal_id then
if block.state~=STATES.FAULT then
block.fault_cause={kind="signal"}
block_domain.fault(block)
self.occupancy.set_flag(block_id,"fault",true)
if self.logger then self.logger.warn("signal failed, block out of service",{block=block_id,signal=signal_id,reason=reason})end
changed[#changed+1]=block_id
end
end
end
return changed
end

function self.get_occupancy(block_id)return self.occupancy.get(block_id)end
function self.get_graph()return self.graph end
function self.proof_mode()return self.proof==true end
function self.get_clearing()
local out={}
for train_id,record in pairs(self.clearing)do
out[train_id]={phase=record.rec.phase,blocks=sorted_keys(record.blocks)}
end
return out
end



function self.observe_block(block_id,state,source,meta)
local block=self.blocks[block_id]
if not block then return false,"block not found" end
local data={at=meta and meta.at or now_ms(),train_id=meta and meta.train_id}
local release=false
if state=="FREE_PROVEN" then
local holder=block.reserved_by or block.occupied_by
local train=holder and self.trains[holder]
if block.state~=STATES.FAULT and block.state~=STATES.FREE and holder then
if train and train.owner and self.active_routes[train.owner]==train then return false,"block is held by train " .. tostring(holder)end
release=true
end
end
local ok,err=self.occupancy.observe(block_id,state,source,data)
if not ok then return false,err end
if state=="OCCUPIED_PROVEN" and block.state==STATES.FREE then mark_fault(block,"observed_occupied")end
if release then
block_domain.release(block)
set_block_red(block)
end
settle_clearing()
if release then self.process_queue(1)end
return true
end



function self.prove_free_from_sensors(ctx)
local proven={}
local max_age=ctx.max_age_s or 10
for _,block_id in ipairs(sorted_keys(self.blocks))do
local block=self.blocks[block_id]
local rec=self.occupancy.get(block_id)
if block.state==STATES.FREE and rec.state~="FREE_PROVEN" and not rec.flags.maintenance and not rec.flags.fault and#(block.sensors or{})>0 then
local all_free=true
for _,sensor_id in ipairs(block.sensors)do
local occupied,at=ctx.sensor_level(sensor_id)
if occupied~=false or at==nil or ctx.now - at>max_age then all_free=false;break end
end
if all_free and self.occupancy.observe(block_id,"FREE_PROVEN","sensor_level",{at=now_ms()})then proven[#proven+1]=block_id end
end
end
if#proven>0 then settle_clearing()end
return proven
end


function self.require_commit(on)self.commit_required=on==true end

function self.commit_pending()
local out={}
for _,id in ipairs(sorted_keys(self.trains))do
local train=self.trains[id]
if train.gated and train.phase_rec and train.phase_rec.phase=="VALIDATED" and train.entry_idx==nil then out[#out+1]=id end
end
return out
end

function self.tag_commit(idx)
for _,id in ipairs(self.commit_pending())do self.trains[id].entry_idx=idx end
end

function self.set_commit_phase(train_id,target)
local train=self.trains[train_id]
if not train or not train.phase_rec then return false,"train not found" end
local order={"PREPARED_BOTH_DURABLE","COMMITTED_BOTH_DURABLE"}
for _,step in ipairs(order)do
if train.phase_rec.phase=="VALIDATED" and step=="PREPARED_BOTH_DURABLE" then advance_phase(train,step)
elseif train.phase_rec.phase=="PREPARED_BOTH_DURABLE" and step=="COMMITTED_BOTH_DURABLE" and target=="COMMITTED_BOTH_DURABLE" then advance_phase(train,step)end
if step==target then break end
end
if train.phase_rec.phase=="COMMITTED_BOTH_DURABLE" then
advance_phase(train,"ACTUATION_ELIGIBLE")
update_route_signals(train)
end
return true
end


function self.advance_commits(prepared_idx,committed_idx)
for _,id in ipairs(sorted_keys(self.trains))do
local train=self.trains[id]
if train.gated and train.entry_idx and train.phase_rec then
local phase_name=train.phase_rec.phase
if phase_name=="VALIDATED" and train.entry_idx<=prepared_idx then self.set_commit_phase(id,"PREPARED_BOTH_DURABLE")end
if train.phase_rec.phase=="PREPARED_BOTH_DURABLE" and train.entry_idx<=committed_idx then self.set_commit_phase(id,"COMMITTED_BOTH_DURABLE")end
end
end
end

function self.snapshot(opts)
local blocks={}
for id,block in pairs(self.blocks)do
local cause=block.fault_cause
blocks[id]={id=id,state=block.state,reserved_by=block.reserved_by,occupied_by=block.occupied_by,
fault_cause=cause and{kind=cause.kind,nodes=cause.nodes and sorted_keys(cause.nodes)or nil}or nil}
end
local snap={version=2,blocks=blocks,trains=self.get_trains(),queue=self.get_queue(),switch_locks=self.get_switch_locks(),deadlocks=copy_table(self.deadlocks),
occupancy=self.occupancy.snapshot(),topology_version=self.graph.version,clearing=self.get_clearing()}
if opts and opts.replicated then


snap.occupancy,snap.clearing=nil,nil
for _,train in pairs(snap.trains)do train.phase,train.entry_idx=nil,nil end
end
return snap
end


local function rebuild_train_locks(train)
local route_blocks=train.route_blocks or{}
local ok,err=self.switch_locks.lock_many(collect_switch_requirements(route_blocks),train.owner)
local cleared,any_cleared={},false
for i=1,(train.route_index or 1)- 1 do
local block=route_blocks[i]
if block and block.reserved_by~=train.id and block.occupied_by~=train.id then cleared[block.id]=true;any_cleared=true end
end
local status=interlocking_module.ROUTE_STATES.SET
if any_cleared then status=interlocking_module.ROUTE_STATES.DISSOLVING
elseif train.state==TRAIN_STATES.RUNNING or train.current_block~=nil then status=interlocking_module.ROUTE_STATES.OCCUPIED end
if ok then
ok,err=self.interlocking.restore_route(train.route,{owner=train.owner,train_id=train.id,status=status,cleared=cleared})
end
if not ok then

self.switch_locks.release_by_route(train.owner)
self.interlocking.cancel_route(train.route,train.owner)
for _,block in ipairs(route_blocks)do
if block.reserved_by==train.id or block.occupied_by==train.id then mark_fault(block)end
end
train.state=TRAIN_STATES.FAULT
if self.logger then self.logger.warn("restore: route state inconsistent",{train=train.id,route=train.route,error=err})end
end
end

function self.restore(snapshot)
local snap=snapshot or{}

self.interlocking.reset()
self.switch_locks.clear()
for id,saved in pairs(snap.blocks or{})do local block=self.blocks[id];if block then block.state=saved.state or STATES.FAULT;block.reserved_by=saved.reserved_by;block.occupied_by=saved.occupied_by;block.overlap_for=nil;block.fault_cause=nil
if saved.fault_cause and block.state==STATES.FAULT then
local nodes
if saved.fault_cause.nodes then nodes={};for _,node_id in ipairs(saved.fault_cause.nodes)do nodes[node_id]=true end end
block.fault_cause={kind=saved.fault_cause.kind,nodes=nodes}
end
set_block_red(block)end end

self.occupancy.invalidate_all("restore")
self.occupancy.restore(snap.occupancy)
for id,block in pairs(self.blocks)do self.occupancy.set_flag(id,"fault",block.state==STATES.FAULT)end
self.clearing={}
self.trains={};self.active_routes={};self.active_conflicts={}
for _,train_id in ipairs(sorted_keys(snap.trains))do
local saved=snap.trains[train_id]
local route_id=saved.route
local owner=route_owner(train_id,route_id)
local route=self.routes[route_id]
local train={id=train_id,route=route_id,owner=owner,state=saved.state or TRAIN_STATES.WAITING,route_blocks=rebuild_route_blocks(route_id),route_index=saved.route_index or 1,current_block=saved.current_block,destination=saved.destination,priority=saved.priority or 0,direction=saved.direction or(route and route_direction(route)),conflict_groups=saved.conflict_groups or(route and route_conflict_groups(route))or{}}
train.length=saved.length
train.phase_rec=phase_module.restore({phase=saved.phase})
self.trains[train_id]=train
local holds=train.state==TRAIN_STATES.RESERVED or train.state==TRAIN_STATES.RUNNING
if holds then self.active_routes[owner]=train;if route then lock_conflicts(route,train)end end


local holds_route=holds
if not holds and train.state==TRAIN_STATES.FAULT then
if saved.holds_route~=nil then holds_route=saved.holds_route
else
for _,block in ipairs(train.route_blocks)do if block.reserved_by==train_id or block.occupied_by==train_id then holds_route=true end end
end
end
if route and holds_route then
self.active_routes[owner]=train;rebuild_train_locks(train)
if not holds then lock_conflicts(route,train)end
end
if self.proof then

for _,block in ipairs(train.route_blocks or{})do
local holder=block.reserved_by or block.occupied_by
if holder==nil or holder==train.id then set_block_red(block)end
end
else
update_route_signals(train)
end
end

for group,active in pairs(snap.active_conflicts or{})do if not self.active_conflicts[group] then self.active_conflicts[group]=copy_table(active)end end
self.queue=route_queue.new();for _,item in ipairs(snap.queue or{})do self.queue.push(copy_table(item))end
self.deadlocks=copy_table(snap.deadlocks or{})
for train_id,saved in pairs(snap.clearing or{})do
local blocks={}
for _,id in ipairs(saved.blocks or{})do blocks[id]=true end
self.clearing[train_id]={rec=phase_module.restore({phase=saved.phase}),blocks=blocks}
end
return true
end

return self
end

dispatcher.STATES=STATES
dispatcher.TRAIN_STATES=TRAIN_STATES
dispatcher.route_conflict_groups=route_conflict_groups
dispatcher.route_direction=route_direction

return dispatcher

