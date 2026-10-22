












local storage_budget={}

storage_budget.LIMIT=1000000
storage_budget.MIN_FILE_COST=500
storage_budget.HARD_FACTOR=2

storage_budget.JOURNAL={
master={max_entries=300,max_bytes=12000},
node={max_entries=200,max_bytes=8000},
fleet={max_entries=300,max_bytes=12000},
}
storage_budget.SNAPSHOT_MAX_BYTES=30000
storage_budget.PLAN_MAX_BYTES=35000
storage_budget.OTA_HEADROOM=100000


local SMALL_FILES=8
local SMALL_FILE_MAX=1500

local function copies(bytes)return bytes*2 end

function storage_budget.journal_hard_stop(kind)
return storage_budget.JOURNAL[kind].max_bytes*storage_budget.HARD_FACTOR
end

function storage_budget.state_worst_case(role)
local small=copies(SMALL_FILES*SMALL_FILE_MAX)
local function journal(kind)return storage_budget.journal_hard_stop(kind)+copies(storage_budget.SNAPSHOT_MAX_BYTES)end
if role=="master" then

return journal("master")+copies(storage_budget.SNAPSHOT_MAX_BYTES)+copies(storage_budget.PLAN_MAX_BYTES)+small
elseif role=="fleet" then
return journal("fleet")+journal("node")+small
elseif role=="panel" then

return journal("node")+copies(storage_budget.PLAN_MAX_BYTES)*2+small
end
return journal("node")+small
end

function storage_budget.program_budget(role)
return storage_budget.LIMIT - storage_budget.state_worst_case(role)- storage_budget.OTA_HEADROOM
end

return storage_budget
