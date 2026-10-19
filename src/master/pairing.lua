--[[
Purpose: Pairing on the master. A computer that announces itself but is not in the plan waits here as a candidate until the operator
  accepts or rejects it; accepting writes its entry into the plan file. Nothing is granted by announcing: a candidate has no commands,
  no blocks and no say in anything until its entry stands in the plan.
Public API:
  new(opts) -> pairing
    opts: config (the loaded plan; accepted entries are added to its nodes), plan_path, fs, now_s(), audit(kind, data),
          max_candidates (64), ttl_s (3600: a candidate that was not heard for that long is forgotten), mute_s (600: how long a rejected id is ignored)
  pairing.announce(src, payload) -> state, detail
      payload: { role, entry (the plan entry of that computer), setup ({ state, fail, warn, version }) }
      state: "known" (in the plan with this role) | "pending" | "conflict" (in the plan with another role) | "muted" | "full" | "invalid"
  pairing.list() -> candidates sorted by id: { id, role, entry, setup, state = "pending" | "conflict", first_seen, last_seen }
  pairing.get(id) -> candidate | nil        pairing.count() -> number
  pairing.setup_of(id) -> { state, fail, warn, version, at } | nil     what a computer of the plan reported about its own setup
  pairing.accept(id, operator) -> ok, message     adds the entry to the plan file (old file kept as .prev) and to the loaded plan
  pairing.reject(id, operator) -> ok, message     forgets the candidate and ignores that id for mute_s
Notes: everything that arrives from the network is cut down before it is kept: the id must be a sane id, the role one of ours, the entry a
  small table of plain values whose id and role are those of the sender, the setup record only its known fields. The plan file is only
  touched when it parses and validates now and when it still does so with the new entry. The plan is written in the stable format of the
  setup wizard (netplan.encode), so a hand-edited layout changes; the old file stays as .prev.
]]

local json = require("src.shared.json")
local netplan = require("src.setup.netplan")
local safe_write = require("src.shared.safe_write")
local setup_status = require("src.shared.setup_status")
local startup_template = require("src.shared.startup_template")
local time = require("src.shared.time")

local pairing = {}

local MAX_ENTRY_BYTES = 1500
local MAX_DEPTH = 4
local MAX_TEXT = 100

local function is_role(role)
  for _, known in ipairs(startup_template.ROLES) do if known == role then return true end end
  return false
end

-- a copy of `value` made of plain values only, nothing deeper than MAX_DEPTH, no long texts, no functions, no cycles
local function plain(value, depth)
  local kind = type(value)
  if kind == "number" then
    if value ~= value or value == math.huge or value == -math.huge then return nil end
    return value
  end
  if kind == "boolean" then return value end
  if kind == "string" then
    if #value > MAX_TEXT then return nil end
    return value
  end
  if kind == "table" and depth < MAX_DEPTH then
    local copy, count = {}, 0
    for key, item in pairs(value) do
      count = count + 1
      if count > 40 then return nil end
      if type(key) == "string" and #key <= 40 or type(key) == "number" then
        local clean = plain(item, depth + 1)
        if clean ~= nil then copy[key] = clean end
      end
    end
    return copy
  end
  return nil
end

local function clean_entry(src, role, entry)
  local minimal = { id = src, role = role }
  if type(entry) ~= "table" then return minimal end
  local copy = plain(entry, 0)
  if type(copy) ~= "table" then return minimal end
  copy.id, copy.role = src, role
  local ok, encoded = pcall(json.encode, copy)
  if not ok or #encoded > MAX_ENTRY_BYTES then return minimal end
  return copy
end

local function clean_setup(setup)
  if type(setup) ~= "table" then return nil end
  local out = {}
  if type(setup.state) == "string" and setup_status.STATES[setup.state] then out.state = setup.state end
  for _, key in ipairs({ "fail", "warn" }) do
    if type(setup[key]) == "number" and setup[key] >= 0 and setup[key] < 1000 then out[key] = math.floor(setup[key]) end
  end
  if type(setup.version) == "string" and #setup.version <= 60 then out.version = setup.version end
  if setup_status.HW[setup.hw or ""] then out.hw = setup.hw end
  if next(out) == nil then return nil end
  return out
end

function pairing.new(opts)
  local o = opts or {}
  local self = {}
  local cfg = o.config or { nodes = {} }
  local fs_api = o.fs or _G.fs
  local now = o.now_s or time.now_s
  local audit = o.audit or function() end
  local max_candidates = o.max_candidates or 64
  local ttl_s = o.ttl_s or 3600
  local mute_s = o.mute_s or 600
  local candidates, count = {}, 0
  local muted = {}
  local known_setup = {}   -- id of the plan -> what that computer reported (at most one entry per computer of the plan)

  local function find_in_plan(id)
    for _, node in ipairs(cfg.nodes or {}) do if node.id == id then return node end end
    return nil
  end

  local function prune()
    local t = now()
    for id, candidate in pairs(candidates) do
      if t - candidate.last_seen > ttl_s then candidates[id] = nil; count = count - 1 end
    end
    for id, until_ in pairs(muted) do if t >= until_ then muted[id] = nil end end
  end

  function self.announce(src, payload)
    if type(src) ~= "string" or not netplan.valid_id(src) then return "invalid", "id" end
    local p = type(payload) == "table" and payload or {}
    local role = p.role
    if type(role) ~= "string" or not is_role(role) then return "invalid", "role" end
    local planned = find_in_plan(src)
    if planned then
      if planned.role == role then
        local setup = clean_setup(p.setup)
        if setup then setup.at = now(); known_setup[src] = setup end
        return "known"
      end
      -- a second computer with an id of the plan, or a computer that changed its role: the operator has to sort it out
      local candidate = candidates[src]
      if not candidate then
        prune()
        if count >= max_candidates then return "full" end
        candidate = { id = src, first_seen = now() }
        candidates[src] = candidate
        count = count + 1
        audit("pair_conflict", { node_id = src, role = role, plan_role = planned.role })
      end
      candidate.role, candidate.state, candidate.last_seen = role, "conflict", now()
      candidate.entry, candidate.setup = clean_entry(src, role, p.entry), clean_setup(p.setup)
      return "conflict", planned.role
    end
    if role == "master" then return "invalid", "role" end
    prune()
    if muted[src] then return "muted" end
    local candidate = candidates[src]
    if not candidate then
      if count >= max_candidates then return "full" end
      candidate = { id = src, first_seen = now() }
      candidates[src] = candidate
      count = count + 1
      audit("pair_candidate", { node_id = src, role = role })
    end
    -- an entry of an earlier announcement belongs to the role it was sent with
    if candidate.entry and candidate.entry.role ~= role then candidate.entry = nil end
    candidate.role, candidate.state, candidate.last_seen = role, "pending", now()
    -- a later announcement with an entry replaces the guess of an earlier heartbeat
    if p.entry ~= nil or not candidate.entry then candidate.entry = clean_entry(src, role, p.entry) end
    local setup = clean_setup(p.setup)
    if setup then candidate.setup = setup end
    return "pending"
  end

  function self.list()
    prune()
    local out = {}
    for _, candidate in pairs(candidates) do out[#out + 1] = candidate end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
  end

  function self.get(id) return candidates[id] end
  function self.setup_of(id) return known_setup[id] end
  function self.count() prune(); return count end

  local function read_plan()
    if not (fs_api and fs_api.exists and fs_api.exists(o.plan_path or "")) then return nil, "Netzplan-Datei nicht gefunden: " .. tostring(o.plan_path) end
    local fh = fs_api.open(o.plan_path, "r")
    if not fh then return nil, "Netzplan-Datei nicht lesbar: " .. tostring(o.plan_path) end
    local text = fh.readAll()
    fh.close()
    return text
  end

  function self.accept(id, operator)
    local candidate = candidates[id]
    if not candidate then return false, "Kein wartender Computer: " .. tostring(id) end
    if candidate.state == "conflict" then return false, "Die ID " .. id .. " steht mit anderer Rolle im Netzplan. Erst dort klaeren." end
    if not o.plan_path then return false, "Der Master kennt den Pfad seines Netzplans nicht." end
    if o.plan_path:find("^configs/templates/") then
      return false, "Der Master laeuft mit einer mitgelieferten Vorlage. Mit scripts/setup.lua einen eigenen Netzplan (configs/network.json) anlegen."
    end
    local text, read_err = read_plan()
    if not text then return false, read_err end
    local plan, errors = netplan.parse(text)
    if not plan then return false, "Der Netzplan ist kein gueltiges JSON: nichts geaendert." end
    if errors then return false, "Der Netzplan hat Fehler (" .. netplan.explain(errors[1], plan) .. "): nichts geaendert. Pruefen: scripts/setup.lua --check" end
    if netplan.find_node(plan, id) then
      -- somebody put it into the file by hand in the meantime
      if not find_in_plan(id) then cfg.nodes[#cfg.nodes + 1] = netplan.find_node(plan, id) end
      candidates[id] = nil
      count = count - 1
      audit("node_accepted", { node_id = id, role = candidate.role, by = operator, already = true })
      return true, id .. " stand schon im Netzplan."
    end
    local entry = clean_entry(id, candidate.role, candidate.entry)
    local body = netplan.encode(netplan.add_node(plan, entry))
    local _, new_errors = netplan.parse(body)
    if new_errors then return false, "Der Eintrag macht den Netzplan ungueltig (" .. netplan.explain(new_errors[1], plan) .. "): nichts geaendert." end
    local ok, err = safe_write.write(o.plan_path, body, { fs = fs_api })
    if not ok then return false, "Netzplan konnte nicht geschrieben werden: " .. tostring(err) end
    cfg.nodes = cfg.nodes or {}
    cfg.nodes[#cfg.nodes + 1] = entry
    candidates[id] = nil
    count = count - 1
    audit("node_accepted", { node_id = id, role = entry.role, by = operator })
    return true, id .. " ist im Netzplan eingetragen (alte Fassung: " .. o.plan_path .. ".prev). Bloecke und Routen, die ihn nutzen, gelten nach einem Neustart des Masters."
  end

  function self.reject(id, operator)
    if not candidates[id] then return false, "Kein wartender Computer: " .. tostring(id) end
    candidates[id] = nil
    count = count - 1
    muted[id] = now() + mute_s
    audit("pair_rejected", { node_id = id, by = operator })
    return true, id .. " abgelehnt (wird " .. math.floor(mute_s / 60) .. " Minuten ignoriert)."
  end

  return self
end

return pairing
