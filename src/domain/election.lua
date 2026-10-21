--[[
Purpose: Election of the active master among master A, master B and the arbiter, with terms, durable votes and a lease (Gesamtkonzept Kap. 2, 5.1, 5.3, S-01, S-02).
Public API: new(opts) -> election.
  opts: id, voters (the three ids, fixed), masters (the two ids that may lead, in order of preference), now_ms (function), store { load() -> { term, voted_for } | nil, save(term, voted_for) -> ok },
        last_commit (function -> number, the newest committed journal index of this computer; nil for the arbiter), lease_ms (3000), beat_ms (1000), timeout_base_ms (5000), timeout_step_ms (3000).
  election.tick() -> list of messages to send { to, kind, payload }
  election.on_message(from, kind, payload) -> list of messages to send
  election.is_leader() -> true only for a leader whose lease is valid right now     election.term()  election.role()  election.leader()  election.status()
  election.elected_by() -> list of voter ids that granted this leader its term
Message kinds: pre_vote_request { term, candidate, last_commit }, pre_vote_reply { term, granted, voter }, vote_request { term, candidate, last_commit },
  vote_reply { term, granted, voter }, lead_beat { term, leader, n, commit }, lead_ack { term, ok, voter, n }.
Notes: before it raises its term a computer asks "would you vote for me?" (pre-vote); nobody changes state on that question, so a master that is cut off from the leader but not from the world can
  never push the term up and disturb a leader that the arbiter and the other master still follow. Pure logic, no network and no clock of its own: the caller sends what tick() / on_message() return and feeds in what arrives. Two of the three voters make a majority. A voter grants
  at most one vote per term and stores term and vote durably before it answers, so a crash and restart cannot vote twice. A leader is valid only while a majority has acknowledged a beat
  that it sent no longer than lease_ms ago (measured from when the beat was sent, so the follower's own wait starts after the leader's lease ends); a voter that heard a live leader
  does not grant another candidate until it has heard nothing for lease_ms plus a margin. Together that gives at most one valid leader at any instant (assuming clocks that run at about
  the same speed: docs/assumptions.md), a leader that loses its majority stops acting by itself, and a leader that was cut off learns the new term from the first answer it gets
  and steps down (a stale leader is fenced). The arbiter never becomes a candidate; it votes and keeps the highest term it has seen. A majority of votes is leadership, not permission:
  every release still needs both masters to confirm it durably (package P4).
]]

local election = {}

local FOLLOWER, CANDIDATE, LEADER = "follower", "candidate", "leader"
election.FOLLOWER, election.CANDIDATE, election.LEADER = FOLLOWER, CANDIDATE, LEADER

local MARGIN_MS = 1000

local function index_of(list, id)
  for i, value in ipairs(list) do if value == id then return i end end
  return nil
end

function election.new(opts)
  local self = {}
  local id = opts.id
  local voters, masters = opts.voters, opts.masters
  local now_ms = opts.now_ms
  local store = opts.store
  local lease_ms = opts.lease_ms or 3000
  local beat_ms = opts.beat_ms or 1000
  local rank = index_of(masters, id)         -- nil: the arbiter
  local timeout_ms = (opts.timeout_base_ms or 5000) + ((rank or 1) - 1) * (opts.timeout_step_ms or 3000)
  local stickiness_ms = lease_ms + MARGIN_MS
  if timeout_ms < stickiness_ms + MARGIN_MS then timeout_ms = stickiness_ms + MARGIN_MS end

  local term, voted_for = 0, nil
  local role, leader_id = FOLLOWER, nil
  local last_contact = nil      -- when a live leader was last heard (monotonic ms)
  local deadline                -- when this computer starts an election
  local votes = {}              -- candidate: voter -> true
  local pre_votes = nil         -- follower that asked for pre-votes: voter -> true (nil: not asking)
  local granted_by = {}         -- leader: the voters of its term
  local beat_n, beat_sent = 0, {}
  local acked_at = {}           -- leader: voter -> the time the newest acknowledged beat was sent
  local next_beat = 0
  local next_request = 0
  local pre_asked_at = nil
  local first_request = nil     -- candidate: when this term's first request went out (a granted vote counts from then, never later)
  local write_failed = false

  local function others()
    local list = {}
    for _, voter in ipairs(voters) do if voter ~= id then list[#list + 1] = voter end end
    return list
  end

  local function majority() return math.floor(#voters / 2) + 1 end

  local function persist()
    if not store then return true end
    local ok = store.save(term, voted_for)
    write_failed = not ok
    return ok and true or false
  end

  local function reset_deadline(now) deadline = now + timeout_ms; pre_votes = nil end

  local function adopt(new_term, now)
    -- a higher term ends whatever this computer was doing: it is a follower again and has not voted in the new term yet
    term = new_term
    voted_for = nil
    if role ~= FOLLOWER then role = FOLLOWER end
    votes, granted_by, acked_at, beat_sent = {}, {}, {}, {}
    pre_votes = nil
    persist()
    reset_deadline(now)
  end

  do
    local saved = store and store.load()
    if saved then term, voted_for = tonumber(saved.term) or 0, saved.voted_for end
    reset_deadline(now_ms())
  end

  local function commit_index() return opts.last_commit and opts.last_commit() or 0 end

  local function votes_count()
    local n = 0
    for _ in pairs(votes) do n = n + 1 end
    return n
  end

  local function fresh_voters(now)
    local n = 1 -- this computer
    for voter, sent in pairs(acked_at) do
      if voter ~= id and now - sent <= lease_ms then n = n + 1 end
    end
    return n
  end

  function self.term() return term end
  function self.role() return role end
  function self.leader() return leader_id end
  function self.elected_by()
    local list = {}
    for voter in pairs(granted_by) do list[#list + 1] = voter end
    table.sort(list)
    return list
  end

  function self.is_leader()
    if role ~= LEADER then return false end
    return fresh_voters(now_ms()) >= majority()
  end

  function self.status()
    local now = now_ms()
    return { id = id, role = role, term = term, leader = leader_id, valid = self.is_leader(), voted_for = voted_for, write_failed = write_failed,
      fresh = role == LEADER and fresh_voters(now) or nil }
  end

  local function broadcast(kind, payload)
    local out = {}
    for _, voter in ipairs(others()) do out[#out + 1] = { to = voter, kind = kind, payload = payload } end
    return out
  end

  local function become_candidate(now)
    term = term + 1
    voted_for = id
    role = CANDIDATE
    votes = { [id] = true }
    leader_id = nil
    if not persist() then
      -- a vote that cannot be written down must not be counted: stay out of the election until the disk works
      role, votes = FOLLOWER, {}
      term = term - 1
      voted_for = nil
      reset_deadline(now)
      return {}
    end
    reset_deadline(now)
    first_request, next_request = now, now + beat_ms
    return broadcast("vote_request", { term = term, candidate = id, last_commit = commit_index() })
  end

  local function become_leader(now)
    role = LEADER
    leader_id = id
    granted_by = {}
    for voter in pairs(votes) do granted_by[voter] = true end
    acked_at = {}
    for voter in pairs(votes) do if voter ~= id then acked_at[voter] = first_request or now end end
    beat_sent = {}
    next_beat = now
  end

  function self.tick()
    local now = now_ms()
    local out = {}
    if role == FOLLOWER then
      if rank and now >= deadline then
        if not pre_votes then
          pre_votes = { [id] = true }
          pre_asked_at = now
          next_request = now + beat_ms
          for _, message in ipairs(broadcast("pre_vote_request", { term = term + 1, candidate = id, last_commit = commit_index() })) do out[#out + 1] = message end
        elseif now >= next_request then
          next_request = now + beat_ms
          for _, message in ipairs(broadcast("pre_vote_request", { term = term + 1, candidate = id, last_commit = commit_index() })) do out[#out + 1] = message end
        end
        if pre_votes and (function() local n = 0 for _ in pairs(pre_votes) do n = n + 1 end return n end)() >= majority() then
          pre_votes = nil
          for _, message in ipairs(become_candidate(now)) do out[#out + 1] = message end
        end
      end
    elseif role == CANDIDATE then
      if votes_count() >= majority() then
        become_leader(now)
      elseif now >= deadline then
        -- no majority this round: back to asking (a pre-vote) before the term goes up again
        role, votes = FOLLOWER, {}
        reset_deadline(now)
      elseif now >= next_request then
        next_request = now + beat_ms
        for _, message in ipairs(broadcast("vote_request", { term = term, candidate = id, last_commit = commit_index() })) do out[#out + 1] = message end
      end
    end
    if role == LEADER then
      if not self.is_leader() then
        -- no majority has acknowledged a beat for a whole lease: this is not a leader any more
        role, leader_id = FOLLOWER, nil
        votes, granted_by, acked_at, beat_sent = {}, {}, {}, {}
        reset_deadline(now)
      elseif now >= next_beat then
        beat_n = beat_n + 1
        beat_sent[beat_n] = now
        beat_sent[beat_n - 20] = nil
        next_beat = now + beat_ms
        for _, message in ipairs(broadcast("lead_beat", { term = term, leader = id, n = beat_n, commit = commit_index() })) do out[#out + 1] = message end
      end
    end
    return out
  end

  function self.on_message(from, kind, payload)
    local now = now_ms()
    local out = {}
    if type(payload) ~= "table" or type(payload.term) ~= "number" or index_of(voters, from) == nil then return out end

    -- a pre-vote changes nothing here, not even the term
    if kind == "pre_vote_request" then
      local candidate = payload.candidate
      if candidate ~= from or index_of(masters, candidate) == nil then return out end
      local grant = payload.term > term
      if grant and role == LEADER and self.is_leader() then grant = false end
      if grant and leader_id and leader_id ~= candidate and last_contact and now - last_contact < stickiness_ms then grant = false end
      if grant and opts.last_commit and (tonumber(payload.last_commit) or 0) < commit_index() then grant = false end
      out[#out + 1] = { to = from, kind = "pre_vote_reply", payload = { term = term, granted = grant, voter = id } }
      return out
    elseif kind == "pre_vote_reply" then
      if payload.term > term then adopt(payload.term, now)
      elseif pre_votes and role == FOLLOWER and payload.granted == true then pre_votes[from] = true end
      return out
    end

    -- only a master can ask for a vote, and only in its own name; anything else does not even move the term
    if kind == "vote_request" and (payload.candidate ~= from or index_of(masters, from) == nil) then return out end

    -- a vote request while a live leader is followed is not even looked at: it must not move the term (Raft thesis 4.2.3)
    if kind == "vote_request" and payload.term > term and payload.candidate == from and leader_id and leader_id ~= from and last_contact and now - last_contact < stickiness_ms then
      out[#out + 1] = { to = from, kind = "vote_reply", payload = { term = term, granted = false, voter = id } }
      return out
    end

    if payload.term > term then adopt(payload.term, now) end

    if kind == "vote_request" then
      local candidate = payload.candidate
      if candidate ~= from or index_of(masters, candidate) == nil then return out end
      local grant = payload.term == term and (voted_for == nil or voted_for == candidate)
      -- a voter that heard a live leader recently does not help another candidate
      if grant and leader_id and leader_id ~= candidate and last_contact and now - last_contact < stickiness_ms then grant = false end
      if grant and role == LEADER then grant = false end
      -- a master does not vote for a candidate whose committed history is behind its own
      if grant and opts.last_commit and (tonumber(payload.last_commit) or 0) < commit_index() then grant = false end
      if grant then
        voted_for = candidate
        if not persist() then grant = false; voted_for = nil end
      end
      if grant then
        -- the candidate may be leader any moment: nobody else gets this computer's vote for a while
        leader_id, last_contact = candidate, now
        reset_deadline(now)
      end
      out[#out + 1] = { to = from, kind = "vote_reply", payload = { term = term, granted = grant, voter = id } }

    elseif kind == "vote_reply" then
      if role == CANDIDATE and payload.term == term and payload.granted == true then
        votes[from] = true
        if votes_count() >= majority() then become_leader(now) end
      end

    elseif kind == "lead_beat" then
      if payload.term < term then
        -- a leader of an old term: tell it the current one (that is the fence)
        out[#out + 1] = { to = from, kind = "lead_ack", payload = { term = term, ok = false, voter = id, n = payload.n } }
      elseif payload.leader == from and index_of(masters, from) then
        if role ~= FOLLOWER then role = FOLLOWER; votes = {} end
        leader_id, last_contact = from, now
        reset_deadline(now)
        out[#out + 1] = { to = from, kind = "lead_ack", payload = { term = term, ok = true, voter = id, n = payload.n } }
      end

    elseif kind == "lead_ack" then
      if role == LEADER and payload.term == term and payload.ok == true and beat_sent[payload.n] then
        local sent = beat_sent[payload.n]
        if not acked_at[from] or sent > acked_at[from] then acked_at[from] = sent end
      end
    end
    return out
  end

  return self
end

return election
