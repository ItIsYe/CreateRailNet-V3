--[[
Purpose: High availability glue: the election of a computer wired to its net, the gate that keeps a master without valid leadership from commanding, and the stamp of the epoch (Kap. 5.1).
Public API: new(opts) -> ha. opts: id, config (masters, master_id, arbiter), network (net instance), now_ms, store (election_store), last_commit (function), logger, lease_ms, beat_ms.
  ha.tick()                       call about twice a second: runs the election and sends what it wants to say
  ha.handle(msg) -> true          a "cmd" with cmd = "election" from a voter; returns false for any other message
  ha.is_leader() / ha.term() / ha.leader() / ha.status()
  ha.gate(msg_type, dst, payload) -> ok, reason       installed in the net: only a valid leader sends commands to computers that are not voters (election and pairing answers are free)
  ha.stamp(msg_type, dst, payload)                     installed in the net: puts election_epoch / election_leader / election_proof into those commands
  EXEMPT_CMDS, is_ha(config) -> true when the plan names two masters
Notes: the voters are the masters and the arbiter of the plan. Election messages are plain "cmd" messages (cmd = "election", kind and fields of src/domain/election.lua), sent without retry:
  a lost message is repeated by the election itself. A pending command that a master queued while it was leader is dropped, not resent, when it stops being leader (the net asks the gate before
  every retry). election_proof lists the voters that granted this leadership; actuators cannot check it (they hold keys for the masters only) and check the epoch instead (src/shared/fence.lua);
  the other master and the arbiter checked the votes themselves when they gave them.
]]

local election = require("src.domain.election")

local ha = {}

ha.EXEMPT_CMDS = { election = true, pair_state = true, plan_part = true }

function ha.is_ha(config)
  return type(config) == "table" and type(config.masters) == "table" and #config.masters >= 2
end

function ha.voter_ids(config)
  local list = {}
  for _, id in ipairs(config.masters or {}) do list[#list + 1] = id end
  if config.arbiter then list[#list + 1] = config.arbiter end
  return list
end

function ha.new(opts)
  local config = opts.config or {}
  local voters = ha.voter_ids(config)
  local is_voter = {}
  for _, id in ipairs(voters) do is_voter[id] = true end
  local network = opts.network
  local logger = opts.logger
  local self = {}

  -- a computer that forgot its vote could vote twice: an unreadable election file keeps it out of the election
  local saved, load_err = nil, nil
  if opts.store then saved, load_err = opts.store.load() end
  if load_err then
    if logger then logger.error("election state unreadable: this computer takes no part in the election", { error = load_err }) end
    local disabled = { disabled = load_err }
    function disabled.tick() end
    function disabled.handle(msg) return msg and msg.payload and msg.payload.cmd == "election" end
    function disabled.is_leader() return false end
    function disabled.term() return 0 end
    function disabled.leader() return nil end
    function disabled.status() return { id = opts.id, role = "follower", term = 0, valid = false, disabled = load_err } end
    function disabled.gate(msg_type, dst, payload)
      if msg_type ~= "cmd" or type(payload) ~= "table" or ha.EXEMPT_CMDS[payload.cmd] or is_voter[dst] then return true end
      return false, "election state unreadable"
    end
    function disabled.stamp() end
    return disabled
  end

  local core = election.new({
    id = opts.id, voters = voters, masters = config.masters, now_ms = opts.now_ms, store = opts.store, last_commit = opts.last_commit,
    lease_ms = opts.lease_ms, beat_ms = opts.beat_ms, timeout_base_ms = opts.timeout_base_ms, timeout_step_ms = opts.timeout_step_ms
  })
  self.election = core

  local previous_leader = false
  local function send_all(actions)
    for _, action in ipairs(actions or {}) do
      local payload = { cmd = "election", kind = action.kind }
      for key, value in pairs(action.payload) do payload[key] = value end
      network.send("cmd", action.to, payload)
    end
  end

  function self.tick()
    send_all(core.tick())
    local leading = core.is_leader()
    if logger and leading ~= previous_leader then
      logger.info(leading and "this master is now the active leader" or "this master is no longer the active leader", { term = core.term() })
    end
    previous_leader = leading
  end

  function self.handle(msg)
    local payload = msg and msg.payload
    if not payload or payload.cmd ~= "election" or type(payload.kind) ~= "string" then return false end
    if not is_voter[msg.src] then return true end
    local fields = {}
    for key, value in pairs(payload) do if key ~= "cmd" and key ~= "kind" then fields[key] = value end end
    send_all(core.on_message(msg.src, payload.kind, fields))
    return true
  end

  function self.is_leader() return core.is_leader() end
  function self.term() return core.term() end
  function self.leader() return core.leader() end
  function self.status() return core.status() end

  function self.gate(msg_type, dst, payload)
    if msg_type ~= "cmd" or type(payload) ~= "table" then return true end
    if ha.EXEMPT_CMDS[payload.cmd] then return true end
    if is_voter[dst] then return true end
    if core.is_leader() then return true end
    return false, "not the active leader"
  end

  function self.stamp(msg_type, dst, payload)
    if msg_type ~= "cmd" or type(payload) ~= "table" then return end
    if ha.EXEMPT_CMDS[payload.cmd] or is_voter[dst] then return end
    payload.election_epoch = core.term()
    payload.election_leader = opts.id
    payload.election_proof = core.elected_by()
  end

  return self
end

return ha
