--[[
Purpose: Train profiles of the fleet (Gesamtkonzept Kap. 8.2, 24.3): immutable logical id, registered Create identity, length, direction suitability, class, line permissions, depot preference, technical state.
Public API: new({ now }) -> registry.
  registry.seen(create_name) -> "KNOWN" | "PENDING"                 an unknown train is recognised and counted, never registered by itself
  registry.pending() -> list of { name, first_seen, count }
  registry.register(spec, approval) -> ok | false, err              approval = { operator, confirmed = true }
  registry.retire(id, approval) -> ok | false, err                  the id is archived and never used again
  registry.get(id) / by_name(name) / list({ lifecycle }) / set_technical_state(id, state) (OK | DEFECT | MAINTENANCE)
  registry.eligible(id, request) -> true | false, why              request: { train_class, line, direction }
  registry.snapshot() / registry.restore(snapshot)
Notes: a registered record is changed only through this module; every change raises its version. The Create name of a retired train may be given to a new train (new id); a retired id may not.
]]

local profile = {}

local CLASSES = { PASSENGER = true, FREIGHT = true }
local TECH = { OK = true, DEFECT = true, MAINTENANCE = true }

local function approved(approval) return type(approval) == "table" and approval.confirmed == true and type(approval.operator) == "string" and approval.operator ~= "" end

local function copy_list(list)
  local out = {}
  for i, v in ipairs(list or {}) do out[i] = v end
  return out
end

local function contains(list, value)
  for _, item in ipairs(list or {}) do if item == value then return true end end
  return false
end

function profile.new(opts)
  opts = opts or {}
  local now = opts.now or function() return 0 end
  local self = {}
  local profiles = {}     -- id -> profile (also the retired ones: the archive)
  local by_create_name = {}
  local pending = {}

  function self.seen(name)
    if by_create_name[name] then return "KNOWN" end
    local entry = pending[name]
    if not entry then entry = { name = name, first_seen = now(), count = 0 }; pending[name] = entry end
    entry.count = entry.count + 1
    return "PENDING"
  end

  function self.pending()
    local out = {}
    for _, entry in pairs(pending) do out[#out + 1] = { name = entry.name, first_seen = entry.first_seen, count = entry.count } end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
  end

  function self.register(spec, approval)
    if not approved(approval) then return false, "a new train needs the approval of an operator" end
    for _, field in ipairs({ "immutable_id", "create_name_ref", "train_class", "length", "permitted_directions" }) do
      if spec[field] == nil then return false, "field missing: " .. field end
    end
    if profiles[spec.immutable_id] then
      if profiles[spec.immutable_id].lifecycle_status == "RETIRED" then return false, "id " .. spec.immutable_id .. " is archived and is never used again" end
      return false, "id " .. spec.immutable_id .. " is already registered"
    end
    if by_create_name[spec.create_name_ref] then return false, "Create name " .. spec.create_name_ref .. " already belongs to " .. by_create_name[spec.create_name_ref] end
    if not CLASSES[spec.train_class] then return false, "train_class must be PASSENGER or FREIGHT" end
    if type(spec.length) ~= "number" or spec.length <= 0 then return false, "length must be a number > 0" end
    profiles[spec.immutable_id] = {
      immutable_id = spec.immutable_id, create_name_ref = spec.create_name_ref, train_class = spec.train_class, length = spec.length,
      permitted_directions = copy_list(spec.permitted_directions), capabilities = copy_list(spec.capabilities), line_permissions = copy_list(spec.line_permissions),
      depot_preference = spec.depot_preference, lifecycle_status = "ACTIVE", technical_state = "OK", version = 1, registered_by = approval.operator, registered_at = now()
    }
    by_create_name[spec.create_name_ref] = spec.immutable_id
    pending[spec.create_name_ref] = nil
    return true
  end

  function self.retire(id, approval)
    if not approved(approval) then return false, "retiring a train needs the approval of an operator" end
    local p = profiles[id]
    if not p then return false, "unknown train " .. tostring(id) end
    p.lifecycle_status = "RETIRED"
    p.version = p.version + 1
    if by_create_name[p.create_name_ref] == id then by_create_name[p.create_name_ref] = nil end
    return true
  end

  function self.get(id) return profiles[id] end
  function self.by_name(name) return by_create_name[name] and profiles[by_create_name[name]] or nil end

  function self.list(filter)
    local out = {}
    for _, p in pairs(profiles) do
      if not (filter and filter.lifecycle) or p.lifecycle_status == filter.lifecycle then out[#out + 1] = p end
    end
    table.sort(out, function(a, b) return a.immutable_id < b.immutable_id end)
    return out
  end

  function self.set_technical_state(id, state)
    local p = profiles[id]
    if not p or not TECH[state] then return false end
    p.technical_state = state
    p.version = p.version + 1
    return true
  end

  function self.eligible(id, request)
    request = request or {}
    local p = profiles[id]
    if not p then return false, "unknown train " .. tostring(id) end
    if p.lifecycle_status ~= "ACTIVE" then return false, "train " .. id .. " is retired" end
    if p.technical_state ~= "OK" then return false, "technical state of " .. id .. " is " .. p.technical_state end
    if request.train_class and request.train_class ~= p.train_class then return false, "class " .. p.train_class .. " does not fit " .. request.train_class end
    if request.line and #p.line_permissions > 0 and not contains(p.line_permissions, request.line) then return false, "train " .. id .. " has no permission for line " .. request.line end
    if request.direction and not contains(p.permitted_directions, request.direction) then return false, "direction " .. request.direction .. " is not permitted for " .. id end
    return true
  end

  function self.snapshot()
    local out = { profiles = {}, pending = {} }
    for id, p in pairs(profiles) do
      local c = {}
      for k, v in pairs(p) do c[k] = type(v) == "table" and copy_list(v) or v end
      out.profiles[id] = c
    end
    for name, entry in pairs(pending) do out.pending[name] = { name = entry.name, first_seen = entry.first_seen, count = entry.count } end
    return out
  end

  function self.restore(snap)
    profiles, by_create_name, pending = {}, {}, {}
    for id, p in pairs((snap and snap.profiles) or {}) do
      local c = {}
      for k, v in pairs(p) do c[k] = type(v) == "table" and copy_list(v) or v end
      profiles[id] = c
      if c.lifecycle_status == "ACTIVE" then by_create_name[c.create_name_ref] = id end
    end
    for name, entry in pairs((snap and snap.pending) or {}) do pending[name] = { name = entry.name, first_seen = entry.first_seen, count = entry.count } end
  end

  return self
end

return profile
