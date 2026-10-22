

















local sensor_guard={}


local DEBOUNCE_MS=200

local MAX_EVENT_AGE_MS=10000


local DEFAULT_MIN_OCCUPY_MS=100

function sensor_guard.new(config)
local self={}
local cfg=config or{}
local MIN_OCCUPY_MS=cfg.sensor_guard_min_occupy_ms
if MIN_OCCUPY_MS==nil then MIN_OCCUPY_MS=DEFAULT_MIN_OCCUPY_MS end


local enter_times={}

local directions={}

local adjacent={}


for _,route in ipairs(cfg.routes or{})do
local blocks=route.blocks or{}
for i=1,#blocks - 1 do
local a,b=blocks[i],blocks[i+1]
adjacent[a]=adjacent[a] or{}
adjacent[b]=adjacent[b] or{}
adjacent[a][b]=true
adjacent[b][a]=true
end
end


local block_cfg={}
for _,b in ipairs(cfg.blocks or{})do
block_cfg[b.id]=b
end



local function now_ms()
return math.floor(os.clock()*1000)
end


function self.validate_enter(block_id,sensor_id,ts)
local event_time=ts or now_ms()
local age=now_ms()- event_time


if age>MAX_EVENT_AGE_MS then
return false,string.format("stale enter event for %s: age=%dms > max=%dms",block_id,age,MAX_EVENT_AGE_MS)
end


local last_enter=enter_times[block_id]
if last_enter and(event_time - last_enter)<DEBOUNCE_MS then
return false,string.format("debounce: enter for %s too soon after last enter (%dms)",block_id,event_time - last_enter)
end

return true
end


function self.validate_leave(block_id,sensor_id,ts,entered_at)
local event_time=ts or now_ms()
local age=now_ms()- event_time

if age>MAX_EVENT_AGE_MS then
return false,string.format("stale leave event for %s: age=%dms",block_id,age)
end


local occupy_start=entered_at or enter_times[block_id]
if occupy_start then
local occupy_duration=event_time - occupy_start
if occupy_duration<MIN_OCCUPY_MS then
return false,string.format("implausible leave for %s: occupied only %dms (min %dms)",block_id,occupy_duration,MIN_OCCUPY_MS)
end
end

return true
end

function self.record_enter(block_id,ts)
enter_times[block_id]=ts or now_ms()
end

function self.record_leave(block_id,ts)

enter_times[block_id]=nil
end



function self.detect_direction(block_id,sensor_id)
local bcfg=block_cfg[block_id]
if not bcfg then return "unknown" end

if bcfg.entry_sensor and bcfg.exit_sensor then
if sensor_id==bcfg.entry_sensor then
directions[block_id]="forward"
elseif sensor_id==bcfg.exit_sensor then
directions[block_id]="backward"
end
end

return directions[block_id] or "unknown"
end


function self.validate_sequence(new_block_id,prev_block_id)
if not prev_block_id then return true end
if new_block_id==prev_block_id then return true end


if adjacent[prev_block_id] and adjacent[prev_block_id][new_block_id] then
return true
end


return false,string.format("non-adjacent block transition: %s -> %s",tostring(prev_block_id),tostring(new_block_id))
end

function self.get_direction(block_id)
return directions[block_id] or "unknown"
end

function self.get_enter_time(block_id)
return enter_times[block_id]
end

return self
end

return sensor_guard
