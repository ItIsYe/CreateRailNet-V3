--[[
Purpose: The storage budget of a CC:Tweaked computer. A computer holds a fixed 1 000 000 bytes (computer_space_limit is not raised; nothing here or in the doctor asks for more): program, state files, journals and the staging of an update have to fit.
Public API:
  LIMIT, MIN_FILE_COST                      the fixed size of a computer, the least CC:Tweaked counts for a file (500)
  JOURNAL.master / .node / .fleet -> { max_entries, max_bytes }    the compaction thresholds the journals are created with; a journal stops taking entries at HARD_FACTOR times max_bytes
  SNAPSHOT_MAX_BYTES, PLAN_MAX_BYTES        the largest snapshot / network plan a computer writes or takes over (a journal that cannot snapshot within the cap fails safe)
  state_worst_case(role) -> bytes           the most the state files of a role take: every file twice (current and the new copy; the .prev generation gives way when space is short, src/shared/safe_write.lua)
  program_budget(role) -> bytes             what the program files of a role may take so that state and an update still fit
  OTA_HEADROOM                              what stays free at the least for the staged copies and backups of an update
Notes: tests/test_storage_budget.lua adds the measured program of every role (minified, every file at least 500 bytes) to these numbers and fails when a role does not fit,
  and shows the design load (400 signals, 40 trains: snapshot 21 600 bytes, plan 24 300 bytes) is below the caps. A bigger network is refused with a message instead of a full disk.
]]

local storage_budget = {}

storage_budget.LIMIT = 1000000
storage_budget.MIN_FILE_COST = 500
storage_budget.HARD_FACTOR = 2

storage_budget.JOURNAL = {
  master = { max_entries = 300, max_bytes = 12000 },
  node = { max_entries = 200, max_bytes = 8000 },
  fleet = { max_entries = 300, max_bytes = 12000 },
}
storage_budget.SNAPSHOT_MAX_BYTES = 30000
storage_budget.PLAN_MAX_BYTES = 35000
storage_budget.OTA_HEADROOM = 100000

-- keys, election, epoch, maintenance, update plan, panel layout and the like: a few hundred bytes each
local SMALL_FILES = 8
local SMALL_FILE_MAX = 1500

local function copies(bytes) return bytes * 2 end

function storage_budget.journal_hard_stop(kind)
  return storage_budget.JOURNAL[kind].max_bytes * storage_budget.HARD_FACTOR
end

function storage_budget.state_worst_case(role)
  local small = copies(SMALL_FILES * SMALL_FILE_MAX)
  local function journal(kind) return storage_budget.journal_hard_stop(kind) + copies(storage_budget.SNAPSHOT_MAX_BYTES) end
  if role == "master" then
    -- the journal with its snapshot, the recovery state file, the network plan
    return journal("master") + copies(storage_budget.SNAPSHOT_MAX_BYTES) + copies(storage_budget.PLAN_MAX_BYTES) + small
  elseif role == "fleet" then
    return journal("fleet") + journal("node") + small
  elseif role == "panel" then
    -- the plan and the topology the master sent
    return journal("node") + copies(storage_budget.PLAN_MAX_BYTES) * 2 + small
  end
  return journal("node") + small
end

function storage_budget.program_budget(role)
  return storage_budget.LIMIT - storage_budget.state_worst_case(role) - storage_budget.OTA_HEADROOM
end

return storage_budget
