--[[
Purpose: Fixed redundancy pairs of the fleet nodes (Gesamtkonzept Kap. 8.1).
Public API: new({ nodes = {fleet node ids}, pairs = { { id, nodes = {a, b} } }, now, timeout_s (15) }) -> pairs, problems.
  pairs.pair_of(node) / partner_of(node) / list() / reserve() / status(pair_id) -> { locked, reason, alive }
  pairs.heartbeat(node, { version, checksum })       a node reports the version of its fleet data (the last durable commit) and a checksum of it
  pairs.auto_allowed(pair_id) -> true | false, why    new automatic activity of the pair: both nodes alive, in step, not locked
  pairs.any_auto() -> boolean
  pairs.unlock(pair_id, approval) / reassign(pair_id, nodes, approval)      only with the approval of an operator (guided re-assignment)
  pairs.assign_train(train_id, pair_id, approval) / release_train / owner_of_train(train_id)
  pairs.snapshot() / restore(snapshot)
Notes: the pairs are chosen at the first configuration and are not formed again dynamically; an odd node is reserve and does nothing until an authorised assignment. A silent partner or a partner
  that is behind in version locks only the new automatic activity of its pair, other pairs go on. The same version with a different checksum is a contradiction: the pair stays locked until an
  operator unlocks it after the data was reconstructed. A train and its orders belong to exactly one pair.
]]

local fleet_pairs = {}

local function approved(a) return type(a) == "table" and a.confirmed == true and type(a.operator) == "string" and a.operator ~= "" end

function fleet_pairs.new(opts)
  opts = opts or {}
  local now = opts.now or function() return 0 end
  local timeout = opts.timeout_s or 15
  local self = {}
  local problems = {}
  local known = {}
  for _, id in ipairs(opts.nodes or {}) do known[id] = true end
  local pairs_by_id, pair_order, node_pair = {}, {}, {}
  local seen = {}        -- node -> { at, version, checksum }
  local assignments = {} -- train id -> pair id

  local function problem(text) problems[#problems + 1] = text end

  local function add_pair(def)
    if type(def) ~= "table" or type(def.id) ~= "string" then problem("a pair needs an id") return end
    if pairs_by_id[def.id] then problem("pair " .. def.id .. " is defined twice") return end
    if type(def.nodes) ~= "table" or #def.nodes ~= 2 then problem("pair " .. def.id .. " needs exactly two nodes") return end
    for _, node in ipairs(def.nodes) do
      if not known[node] then problem("pair " .. def.id .. ": node " .. tostring(node) .. " is no fleet node") return end
      if node_pair[node] then problem("node " .. node .. " is already in pair " .. node_pair[node]) return end
    end
    if def.nodes[1] == def.nodes[2] then problem("pair " .. def.id .. " needs two different nodes") return end
    pairs_by_id[def.id] = { id = def.id, nodes = { def.nodes[1], def.nodes[2] }, locked = false }
    pair_order[#pair_order + 1] = def.id
    node_pair[def.nodes[1]], node_pair[def.nodes[2]] = def.id, def.id
  end
  for _, def in ipairs(opts.pairs or {}) do add_pair(def) end

  function self.pair_of(node) local id = node_pair[node]; return id and pairs_by_id[id] or nil end
  function self.partner_of(node)
    local p = self.pair_of(node)
    if not p then return nil end
    return p.nodes[1] == node and p.nodes[2] or p.nodes[1]
  end
  function self.list()
    local out = {}
    for _, id in ipairs(pair_order) do out[#out + 1] = pairs_by_id[id] end
    return out
  end
  function self.reserve()
    local out = {}
    for _, id in ipairs(opts.nodes or {}) do if not node_pair[id] then out[#out + 1] = id end end
    table.sort(out)
    return out
  end

  function self.heartbeat(node, report)
    seen[node] = { at = now(), version = report and report.version, checksum = report and report.checksum }
  end

  local function alive(node) return seen[node] ~= nil and (now() - seen[node].at) <= timeout end

  function self.auto_allowed(pair_id)
    local pair = pairs_by_id[pair_id]
    if not pair then return false, "unknown pair " .. tostring(pair_id) end
    for _, node in ipairs(pair.nodes) do
      if not alive(node) then return false, "node " .. node .. " is silent or was never seen" end
    end
    local a, b = seen[pair.nodes[1]], seen[pair.nodes[2]]
    if a.version == b.version and a.checksum ~= b.checksum then
      pair.locked, pair.reason = true, "the partners contradict each other at version " .. tostring(a.version)
    end
    if pair.locked then return false, pair.reason or "pair is locked" end
    if a.version ~= b.version then return false, "the partner has to catch up (versions " .. tostring(a.version) .. " and " .. tostring(b.version) .. ")" end
    return true
  end

  function self.any_auto()
    for _, id in ipairs(pair_order) do if self.auto_allowed(id) then return true end end
    return false
  end

  function self.status(pair_id)
    local pair = pairs_by_id[pair_id]
    if not pair then return nil end
    return { locked = pair.locked, reason = pair.reason, alive = { [pair.nodes[1]] = alive(pair.nodes[1]), [pair.nodes[2]] = alive(pair.nodes[2]) } }
  end

  function self.unlock(pair_id, approval)
    local pair = pairs_by_id[pair_id]
    if not pair then return false, "unknown pair" end
    if not approved(approval) then return false, "unlocking a pair needs the approval of an operator" end
    pair.locked, pair.reason = false, nil
    return true
  end

  function self.reassign(pair_id, nodes, approval)
    local pair = pairs_by_id[pair_id]
    if not pair then return false, "unknown pair" end
    if not approved(approval) then return false, "a new pairing needs the approval of an operator" end
    if type(nodes) ~= "table" or #nodes ~= 2 or nodes[1] == nodes[2] then return false, "a pair needs two different nodes" end
    for _, node in ipairs(nodes) do
      if not known[node] then return false, "node " .. tostring(node) .. " is no fleet node" end
      if node_pair[node] and node_pair[node] ~= pair_id then return false, "node " .. node .. " is in pair " .. node_pair[node] end
    end
    for _, node in ipairs(pair.nodes) do node_pair[node] = nil end
    pair.nodes = { nodes[1], nodes[2] }
    node_pair[nodes[1]], node_pair[nodes[2]] = pair_id, pair_id
    pair.locked, pair.reason = true, "new pairing: the data has to be reconstructed"
    return true
  end

  function self.assign_train(train_id, pair_id, approval)
    if not approved(approval) then return false, "an assignment needs the approval of an operator" end
    if not pairs_by_id[pair_id] then return false, "unknown pair " .. tostring(pair_id) end
    if assignments[train_id] and assignments[train_id] ~= pair_id then return false, "train " .. train_id .. " belongs to pair " .. assignments[train_id] end
    assignments[train_id] = pair_id
    return true
  end

  function self.release_train(train_id, approval)
    if not approved(approval) then return false, "releasing a train needs the approval of an operator" end
    if not assignments[train_id] then return false, "train is not assigned" end
    assignments[train_id] = nil
    return true
  end

  function self.owner_of_train(train_id) return assignments[train_id] end

  function self.snapshot()
    local out = { pairs = {}, assignments = {}, seen = {} }
    for id, p in pairs(pairs_by_id) do out.pairs[id] = { id = id, nodes = { p.nodes[1], p.nodes[2] }, locked = p.locked, reason = p.reason } end
    for k, v in pairs(assignments) do out.assignments[k] = v end
    return out
  end

  function self.restore(snap)
    pairs_by_id, pair_order, node_pair, assignments = {}, {}, {}, {}
    local ids = {}
    for id in pairs((snap and snap.pairs) or {}) do ids[#ids + 1] = id end
    table.sort(ids)
    for _, id in ipairs(ids) do
      local p = snap.pairs[id]
      pairs_by_id[id] = { id = id, nodes = { p.nodes[1], p.nodes[2] }, locked = p.locked == true, reason = p.reason }
      pair_order[#pair_order + 1] = id
      node_pair[p.nodes[1]], node_pair[p.nodes[2]] = id, id
    end
    for k, v in pairs((snap and snap.assignments) or {}) do assignments[k] = v end
  end

  return self, problems
end

return fleet_pairs
