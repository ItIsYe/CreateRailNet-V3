












local track_choice={}

local function contains(list,value)
for _,item in ipairs(list or{})do if item==value then return true end end
return false
end

local function excluded_reason(track,request,state,kind)
if track.confirmed~=true then return "track not confirmed in the game yet" end
if request.direction and track.direction and track.direction~=request.direction then return "direction " .. tostring(track.direction).. " does not fit " .. tostring(request.direction)end
if request.length then
if not track.length then return "length of the track was never measured" end
if request.length>track.length then return "train too long for the track (" .. tostring(request.length).. " > " .. tostring(track.length).. ")" end
end
if kind=="platform" and request.train_type and track.train_types and not contains(track.train_types,request.train_type)then
return "train type " .. tostring(request.train_type).. " not served by the track"
end
return nil
end

function track_choice.choose_platform(platforms,request,state)
request=request or{}
local suitable,excluded={},{}
for _,platform in ipairs(platforms or{})do
local reason=excluded_reason(platform,request,state,"platform")
if reason then
excluded[platform.id]=reason
else
suitable[#suitable+1]=platform
end
end
local free={}
for _,platform in ipairs(suitable)do
if platform.conflict_group and state.group_busy and state.group_busy(platform.conflict_group)then
excluded[platform.id]="conflict group " .. tostring(platform.conflict_group).. " is in use"
elseif not state.is_free(platform.block)then
excluded[platform.id]="track is not free"
else
free[#free+1]=platform
end
end
table.sort(free,function(a,b)
local pa,pb=a.preferred or math.huge,b.preferred or math.huge
if pa~=pb then return pa<pb end
local la,lb=a.length or math.huge,b.length or math.huge
if la~=lb then return la<lb end
return tostring(a.id)<tostring(b.id)
end)
local candidates={}
for _,platform in ipairs(free)do candidates[#candidates+1]={id=platform.id,block=platform.block,length=platform.length}end
local wait=#candidates==0 and#suitable>0
return candidates[1] and candidates[1].id or nil,candidates,excluded,wait
end

function track_choice.choose_depot(depots,request,state)
request=request or{}
local any_fit=false
local ordered={}
for _,depot in ipairs(depots or{})do ordered[#ordered+1]=depot end
table.sort(ordered,function(a,b)
local pa,pb=(a.id==request.prefer)and 0 or 1,(b.id==request.prefer)and 0 or 1
if pa~=pb then return pa<pb end
return tostring(a.id)<tostring(b.id)
end)
local first=true
for _,depot in ipairs(ordered)do
local best
for _,track in ipairs(depot.tracks or{})do
if not excluded_reason(track,request,state,"depot")then
any_fit=true
if state.is_free(track.block)then
if not best or(track.length or math.huge)<(best.length or math.huge)then best=track end
end
end
end
if best then return{kind="TRACK",depot=depot.id,track=best.id,alternative=(not first)or nil}end
first=false
end
if not any_fit then return{kind="HOLD_AND_ALERT",reason="no track in any depot fits the train"}end
if request.circuit then return{kind="SAFE_ROUTE",route=request.circuit}end
return{kind="HOLD_AND_ALERT",reason="every depot is full and no approved circuit exists"}
end

return track_choice
