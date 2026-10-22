







local phase={}

local ORDER={"PROPOSED","VALIDATED","PREPARED_BOTH_DURABLE","COMMITTED_BOTH_DURABLE","ACTUATION_ELIGIBLE","ACTUATED","IN_PROGRESS","CLEARANCE_PENDING","RELEASED_PROVEN"}
local MAX_HISTORY=8

local NEXT={
PROPOSED={VALIDATED=true,FAULT=true},
VALIDATED={PREPARED_BOTH_DURABLE=true},
PREPARED_BOTH_DURABLE={COMMITTED_BOTH_DURABLE=true},
COMMITTED_BOTH_DURABLE={ACTUATION_ELIGIBLE=true},
ACTUATION_ELIGIBLE={ACTUATED=true},
ACTUATED={IN_PROGRESS=true,CLEARANCE_PENDING=true},
IN_PROGRESS={CLEARANCE_PENDING=true},
CLEARANCE_PENDING={RELEASED_PROVEN=true},
FAULT={CLEARANCE_PENDING=true},
UNCERTAIN={CLEARANCE_PENDING=true},
RELEASED_PROVEN={}
}

for _,name in ipairs({"VALIDATED","PREPARED_BOTH_DURABLE","COMMITTED_BOTH_DURABLE","ACTUATION_ELIGIBLE","ACTUATED","IN_PROGRESS"})do
NEXT[name].FAULT=true
NEXT[name].UNCERTAIN=true
end
NEXT.PROPOSED.UNCERTAIN=true

local ACTUATE={ACTUATION_ELIGIBLE=true,ACTUATED=true,IN_PROGRESS=true}

local TRUSTED={PROPOSED=true,VALIDATED=true,COMMITTED_BOTH_DURABLE=true,CLEARANCE_PENDING=true,RELEASED_PROVEN=true,FAULT=true,UNCERTAIN=true}

phase.ORDER=ORDER

function phase.new()return{phase="PROPOSED",history={"PROPOSED"}}end

function phase.can(from,to)return NEXT[from]~=nil and NEXT[from][to]==true end

function phase.may_actuate(name)return ACTUATE[name]==true end

function phase.is_final(name)return name=="RELEASED_PROVEN" end

function phase.advance(record,to)
if not NEXT[to] then return false,"unknown state " .. tostring(to)end
if not phase.can(record.phase,to)then return false,"cannot go from " .. tostring(record.phase).. " to " .. to end
record.phase=to
record.history[#record.history+1]=to
while#record.history>MAX_HISTORY do table.remove(record.history,1)end
return true
end

function phase.restore(saved)
local name=saved and saved.phase
local record=phase.new()
record.history={}
if NEXT[name] and TRUSTED[name] then record.phase=name else record.phase="UNCERTAIN" end
record.history[1]=record.phase
return record
end

return phase
