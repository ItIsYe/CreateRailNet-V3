--[[
Purpose: Master A, master B and the arbiter as three elections on a simulated network with loss, delay, duplication, partitions, crashes and slightly different clock speeds.
Public API: new(opts) -> world with step(ms, n), run(ms), crash(id), restart(id), cut(a, b) / heal(a, b) / heal_all(), isolate(id), leaders() -> ids that are valid leaders now,
  violations (list of strings, filled by the invariant checks of every step), term_leaders (term -> leader id), members[id] = { election, alive, store }.
  opts: seed, drop (0..1), duplicate (0..1), delay_max_ms, drift (members' clock speed differs by up to this fraction, e.g. 0.02), lease_ms, last_commit (id -> number).
Notes: the stores survive a crash like files do. Every step checks: at most one valid leader at any instant, a term never goes down on one member, one leader per term for all of history.
]]

local election = require("src.domain.election")
local prng = require("tests.harness.prng")

local world_mod = {}

world_mod.A, world_mod.B, world_mod.ARB = "MASTER-A", "MASTER-B", "ARBITER-1"

function world_mod.new(opts)
  opts = opts or {}
  local rng = prng.new(opts.seed or 1)
  local w = { now = 0, members = {}, queue = {}, violations = {}, term_leaders = {}, blocked = {}, sent = 0, rng = rng }
  local ids = { world_mod.A, world_mod.B, world_mod.ARB }
  local masters = { world_mod.A, world_mod.B }

  local function clock_of(id)
    local member = w.members[id]
    return function() return math.floor(w.now * member.rate) end
  end

  local function build(id)
    local member = w.members[id]
    member.election = election.new({
      id = id, voters = ids, masters = masters, now_ms = clock_of(id), lease_ms = opts.lease_ms or 3000,
      store = member.store, last_commit = (id ~= world_mod.ARB) and function() return opts.last_commit and opts.last_commit(id) or 0 end or nil
    })
  end

  for _, id in ipairs(ids) do
    local member = { alive = true, rate = 1 + (opts.drift and ((rng.int(0, 2000) - 1000) / 1000 * opts.drift) or 0), durable = {}, last_term = 0 }
    member.store = {
      load = function() return member.durable.saved end,
      save = function(term, voted_for)
        if member.fail_writes then return false end
        member.durable.saved = { term = term, voted_for = voted_for }
        return true
      end
    }
    w.members[id] = member
  end
  for _, id in ipairs(ids) do build(id) end

  local function blocked(a, b) return w.blocked[a .. ">" .. b] or w.blocked[b .. ">" .. a] end

  local function send(from, actions)
    for _, action in ipairs(actions or {}) do
      w.sent = w.sent + 1
      if not blocked(from, action.to) and not rng.chance(opts.drop or 0) then
        local copies = rng.chance(opts.duplicate or 0) and 2 or 1
        for _ = 1, copies do
          w.queue[#w.queue + 1] = { due = w.now + rng.int(1, math.max(1, opts.delay_max_ms or 1)), from = from, to = action.to, kind = action.kind, payload = action.payload }
        end
      end
    end
  end

  function w.leaders()
    local out = {}
    for _, id in ipairs(ids) do
      local member = w.members[id]
      if member.alive and member.election.is_leader() then out[#out + 1] = id end
    end
    return out
  end

  local function check()
    local leaders = w.leaders()
    if #leaders > 1 then w.violations[#w.violations + 1] = "two valid leaders at " .. w.now .. ": " .. table.concat(leaders, ",") end
    for _, id in ipairs(leaders) do
      local term = w.members[id].election.term()
      local known = w.term_leaders[term]
      if known and known ~= id then w.violations[#w.violations + 1] = "term " .. term .. " has two leaders: " .. known .. " and " .. id end
      w.term_leaders[term] = id
    end
    for _, id in ipairs(ids) do
      local member = w.members[id]
      if member.alive then
        local term = member.election.term()
        if term < member.last_term then w.violations[#w.violations + 1] = id .. " went from term " .. member.last_term .. " to " .. term end
        member.last_term = term
      end
    end
  end

  function w.step(ms, count)
    for _ = 1, count or 1 do
      w.now = w.now + ms
      table.sort(w.queue, function(a, b) return a.due < b.due end)
      local due, later = {}, {}
      for _, item in ipairs(w.queue) do if item.due <= w.now then due[#due + 1] = item else later[#later + 1] = item end end
      w.queue = later
      for _, item in ipairs(due) do
        local member = w.members[item.to]
        if member.alive and not blocked(item.from, item.to) then send(item.to, member.election.on_message(item.from, item.kind, item.payload)) end
        check()
      end
      for _, id in ipairs(ids) do
        local member = w.members[id]
        if member.alive then send(id, member.election.tick()) end
      end
      check()
    end
  end

  function w.run(ms) w.step(50, math.ceil(ms / 50)) end

  function w.crash(id) w.members[id].alive = false end
  function w.restart(id)
    local member = w.members[id]
    member.alive = true
    build(id)
  end
  function w.cut(a, b) w.blocked[a .. ">" .. b] = true end
  function w.heal(a, b) w.blocked[a .. ">" .. b] = nil; w.blocked[b .. ">" .. a] = nil end
  function w.heal_all() w.blocked = {} end
  function w.isolate(id) for _, other in ipairs(ids) do if other ~= id then w.cut(id, other) end end end

  return w
end

return world_mod
