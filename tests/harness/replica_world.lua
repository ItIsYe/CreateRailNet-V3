--[[
Purpose: Two masters with real nets, journals (in-memory file systems) and replicas on a lossy simulated link; the leadership is set by the test, the state to replicate is a table the test edits.
Public API: new(opts) -> world with members A and B (world.members[id] = { id, net, journal, replica, fs, ha, state }), lead(id, term), step(ms, n), run(ms), restart(id), crash(id), cut() / heal(), link, close().
  member.state is what snapshot_fn returns for that member while it leads (edit it, then call member.replica.capture()).
  opts: seed, drop, duplicate, delay_max_ms, part_bytes, max_entries, max_bytes.
Notes: time is the virtual clock of the link (os.clock is replaced until close()). restart(id) builds a fresh net, journal object and replica on the same files (a reboot).
]]

local net = require("src.shared.net")
local time = require("src.shared.time")
local journal_module = require("src.shared.journal")
local replica_module = require("src.master.replica")
local memfs = require("tests.harness.memfs")
local prng = require("tests.harness.prng")
local lossy_link = require("tests.harness.lossy_link")

local world_mod = {}

world_mod.A, world_mod.B = "MASTER-A", "MASTER-B"

local quiet = { info = function() end, warn = function() end, error = function() end, debug = function() end }

function world_mod.new(opts)
  opts = opts or {}
  local rng = prng.new(opts.seed or 1)
  local link = lossy_link.new(rng, { drop = opts.drop, duplicate = opts.duplicate, delay_max_ms = opts.delay_max_ms })
  local w = { link = link, members = {}, rng = rng, blocked = false }
  local ids = { world_mod.A, world_mod.B }

  local function clock() return time.now_ms() end

  local function build(member)
    member.net = net.new(link.modem(member.id), 1, member.id, quiet, time)
    member.journal = journal_module.new("state/master_journal.log", { fs = member.fs, max_entries = 1000, max_bytes = opts.journal_bytes or 400000 })
    member.journal.open()
    member.replica = replica_module.new({
      id = member.id, peer = member.peer, network = member.net, journal = member.journal, ha = member.ha, now_ms = clock, logger = quiet,
      snapshot_fn = function() return member.state end, part_bytes = opts.part_bytes, max_entries = opts.max_entries, max_bytes = opts.max_bytes
    })
    link.set_receiver(member.id, function(msg)
      if w.blocked or member.crashed then return end
      local status = member.net.receive(msg)
      if status == "ok" and msg.type == "cmd" and msg.payload.cmd == "repl" then member.replica.handle(msg) end
    end)
  end

  for _, id in ipairs(ids) do
    local member = { id = id, peer = (id == world_mod.A) and world_mod.B or world_mod.A, fs = memfs.new(), state = { blocks = {}, trains = {}, queue = {} }, leader = false, term = 0 }
    member.ha = { is_leader = function() return member.leader and not member.crashed end, term = function() return member.term end }
    w.members[id] = member
    build(member)
  end

  function w.lead(id, term)
    for _, member in pairs(w.members) do member.leader = false end
    local member = w.members[id]
    member.leader, member.term = true, term
    for _, other in pairs(w.members) do if other ~= member then other.term = term end end
  end

  function w.step(ms, count)
    for _ = 1, count or 1 do
      link.advance(ms)
      for _, id in ipairs(ids) do
        local member = w.members[id]
        if not member.crashed then member.replica.tick(); member.net.tick() end
      end
    end
  end
  function w.run(ms) w.step(50, math.ceil(ms / 50)) end

  function w.crash(id) w.members[id].crashed = true end
  function w.restart(id)
    local member = w.members[id]
    member.crashed = false
    build(member)
  end
  function w.cut() w.blocked = true end
  function w.heal() w.blocked = false end
  function w.close() link.close() end
  return w
end

return world_mod
