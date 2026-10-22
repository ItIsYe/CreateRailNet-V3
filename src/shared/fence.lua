--[[
Purpose: Fencing at an actuator: a computer remembers the highest election epoch it has seen from a master and refuses commands of lower epochs (Gesamtkonzept Kap. 5.1, E-10, F-07).
Public API: new(opts) -> fence (set_topology(list, required) changes the master list later). opts: path (default state/crn_epoch.json), fs, masters (list of master ids), required (true: a command without an epoch is refused).
  fence.check(payload, src) -> true | false, reason       reasons: "old_epoch", "no_epoch", "bad_epoch", "leader_mismatch"
  fence.epoch() -> highest epoch seen
Notes: a command from a master carries election_epoch (the term of its leadership) and election_leader (its own id). A higher epoch is stored (durably, before the command runs);
  an equal one is fine; a lower one comes from a leader that was replaced and is refused: after a failover the old master cannot steer anything even if it still believes it leads.
  With required = false (a plan with a single master) a command without an epoch passes, one with an epoch is still checked. The election itself (docs/V3_ZIEL.md) makes sure that only the
  leader of the highest term sends commands; this is the second line, at the place where the action happens. The file survives restarts, so a restarted computer is not fenceable
  by a replay of an old epoch.
]]

local json = require("src.shared.json")
local safe_write = require("src.shared.safe_write")

local fence = {}

fence.DEFAULT_PATH = "state/crn_epoch.json"

function fence.new(opts)
  opts = opts or {}
  local path = opts.path or fence.DEFAULT_PATH
  local io_opts = { fs = opts.fs }
  local masters = {}
  for _, id in ipairs(opts.masters or {}) do masters[id] = true end
  local self = {}
  local highest = 0

  do
    local body = safe_write.read_with_backup(path, io_opts)
    if body then
      local ok, decoded = pcall(json.decode, body)
      if ok and type(decoded) == "table" and type(decoded.epoch) == "number" then highest = decoded.epoch end
    end
  end

  function self.epoch() return highest end

  -- the plan or the master told this computer that there are two masters now (or none): the rules follow
  function self.set_topology(list, required)
    masters = {}
    for _, id in ipairs(list or {}) do masters[id] = true end
    opts.required = required == true
  end

  function self.check(payload, src)
    local epoch = payload and payload.election_epoch
    if epoch == nil then
      if opts.required then return false, "no_epoch" end
      return true
    end
    if type(epoch) ~= "number" or epoch < 1 or epoch ~= math.floor(epoch) then return false, "bad_epoch" end
    if payload.election_leader ~= nil and payload.election_leader ~= src then return false, "leader_mismatch" end
    if next(masters) ~= nil and not masters[src] then return false, "leader_mismatch" end
    if epoch < highest then return false, "old_epoch" end
    if epoch > highest then
      local ok = safe_write.write(path, json.encode({ v = 1, epoch = epoch }), io_opts)
      if not ok then return false, "epoch_not_stored" end
      highest = epoch
    end
    return true
  end

  return self
end

return fence
