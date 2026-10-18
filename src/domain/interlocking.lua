--[[
Purpose: Railway interlocking (Stellwerk) — Fahrstraßen, Flankenschutz, Durchrutschweg.
Implements: Route setting, conflicting routes, overlap (Durchrutschweg), flank protection (Flankenschutz).

A Fahrstrasse (route/interlocking path) is an atomic safety unit. Its fields come from the dispatcher route and its blocks:
  - entry_signal / exit_signal: first entry and last exit signal of the blocks
  - signal_blocks: entry signal -> blocks it guards (GREEN/YELLOW is only allowed for a block that is still ahead of the train)
  - switches: positions of all blocks of the route, locked under the route owner
Entries of config.interlocking_routes with the same id add or override fields:
  - flank_protection: list of {switch_id, position} — neighboring switches locked (and set by the dispatcher) so no
    other route can end up in the flank
  - overlap_block: block beyond the exit signal (Durchrutschweg), kept reserved for the train; stays RED
An entry with an id that is no dispatcher route stands for itself (needs blocks and entry_signal).

Status: VACANT → SET → OCCUPIED → DISSOLVING → VACANT. A route with state is owned by whoever set it (opts.owner).

Public API:
  new(config, switch_locks, blocks_ref)
  set_route(route_id, opts) -> ok, err          opts: { owner = lock owner, train_id = holder of the blocks }
  restore_route(route_id, opts) -> ok, err      rebuild after a restart: opts + { status, cleared }
  enter_route(route_id, owner) -> ok, err       [called when a train enters a block of the route]
  section_free(route_id, block_id, owner) -> ok [called when a block is cleared, partial dissolution]
  cancel_route(route_id, owner) -> ok, err
  reset()                                       dissolve everything
  is_signal_green_allowed(signal_id) -> bool, route_id | reason
  flank_switches(route_id) -> { {id, position}, ... }
  get_route(route_id) -> route definition (do not modify)
  get_route_status(route_id), list(), route_for_block(block_id)
]]

local interlocking = {}

local ROUTE_STATES = {
  VACANT     = "VACANT",
  SET        = "SET",         -- all conditions met, signal can show PROCEED
  OCCUPIED   = "OCCUPIED",    -- train has entered
  DISSOLVING = "DISSOLVING",  -- partial dissolution as train progresses
}

local function sorted_keys(t)
  local keys = {}
  for key in pairs(t or {}) do keys[#keys + 1] = key end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  return keys
end

local function copy_list(list)
  local out = {}
  for i, v in ipairs(list or {}) do out[i] = v end
  return out
end

-- Route definitions of the interlocking: derived from config.routes and config.blocks, overlaid with config.interlocking_routes
local function build_routes(config)
  local block_defs = {}
  for _, block in ipairs(config.blocks or {}) do block_defs[block.id] = block end

  local function build(raw)
    local route = {}
    for k, v in pairs(raw) do route[k] = v end
    route.blocks = copy_list(raw.blocks)
    local first, last = block_defs[route.blocks[1]], block_defs[route.blocks[#route.blocks]]
    route.entry_signal = raw.entry_signal or (first and first.entry_signal)
    route.exit_signal = raw.exit_signal or (last and last.exit_signal)
    local switches, seen = {}, {}
    if raw.switches then
      for _, sw in ipairs(raw.switches) do switches[#switches + 1] = { id = sw.id, position = sw.position } end
    else
      for _, block_id in ipairs(route.blocks) do
        local def = block_defs[block_id]
        for _, sw in ipairs(def and def.switches or {}) do
          if not seen[tostring(sw.id)] then
            seen[tostring(sw.id)] = true
            switches[#switches + 1] = { id = sw.id, position = sw.position }
          end
        end
      end
    end
    route.switches = switches
    local signal_blocks = {}
    for _, block_id in ipairs(route.blocks) do
      local signal = block_defs[block_id] and block_defs[block_id].entry_signal
      if signal then
        signal_blocks[signal] = signal_blocks[signal] or {}
        table.insert(signal_blocks[signal], block_id)
      end
    end
    if route.entry_signal and not signal_blocks[route.entry_signal] and route.blocks[1] then
      signal_blocks[route.entry_signal] = { route.blocks[1] }
    end
    route.signal_blocks = signal_blocks
    return route
  end

  local raw_routes = {}
  for _, r in ipairs(config.routes or {}) do raw_routes[r.id] = r end
  for _, r in ipairs(config.interlocking_routes or {}) do
    local merged = {}
    for k, v in pairs(raw_routes[r.id] or {}) do merged[k] = v end
    for k, v in pairs(r) do merged[k] = v end
    raw_routes[r.id] = merged
  end
  local routes = {}
  for id, raw in pairs(raw_routes) do routes[id] = build(raw) end
  return routes
end

function interlocking.new(config, switch_locks_ref, blocks_ref)
  local routes_cfg = build_routes(config)
  local route_ids = sorted_keys(routes_cfg)

  -- indexes: which routes use a block / switch / signal (sorted, so answers do not depend on pairs() order)
  local block_routes, switch_routes, signal_routes = {}, {}, {}
  local function index(map, key, route_id)
    map[key] = map[key] or {}
    table.insert(map[key], route_id)
  end
  for _, route_id in ipairs(route_ids) do
    local route = routes_cfg[route_id]
    for _, block_id in ipairs(route.blocks) do index(block_routes, block_id, route_id) end
    if route.overlap_block then index(block_routes, route.overlap_block, route_id) end
    for _, sw in ipairs(route.switches) do index(switch_routes, sw.id, route_id) end
    for signal in pairs(route.signal_blocks) do index(signal_routes, signal, route_id) end
  end
  for _, list in pairs(signal_routes) do table.sort(list) end

  local state = {}  -- route_id -> { status, owner, train_id, cleared_blocks, set_at, entered_at }; nil = VACANT

  local self = {}
  self.ROUTE_STATES = ROUTE_STATES

  local function flank_owner(owner) return tostring(owner) .. ":flank" end

  -- Every block of the route must be free, or already reserved for the train that gets the route
  local function blocks_clear(route, train_id)
    for _, block_id in ipairs(route.blocks) do
      if blocks_ref then
        local block = blocks_ref[block_id]
        if not block then return false, "unknown block: " .. tostring(block_id) end
        if block.state ~= "FREE" and not (train_id ~= nil and block.state == "RESERVED" and block.reserved_by == train_id) then
          return false, "block occupied: " .. tostring(block_id)
        end
      end
    end
    return true
  end

  -- Overlap (Durchrutschweg) block must be free
  local function overlap_clear(route, train_id)
    local ov = route.overlap_block
    if not ov or not blocks_ref then return true end
    local block = blocks_ref[ov]
    if not block then return false, "unknown overlap block: " .. tostring(ov) end
    if block.state ~= "FREE" and not (block.overlap_for == route.id and block.reserved_by == (train_id or block.reserved_by)) then
      return false, "overlap block occupied: " .. tostring(ov)
    end
    return true
  end

  -- Does another live route use one of our blocks or need one of our switches in a different position?
  local function route_conflict(route_id, route)
    local checked = {}
    local function block_hit(block_id)
      for _, other_id in ipairs(block_routes[block_id] or {}) do
        if other_id ~= route_id and state[other_id] and not checked[other_id] then
          checked[other_id] = true
          return "block conflict with route " .. other_id .. " on block " .. tostring(block_id)
        end
      end
    end
    for _, block_id in ipairs(route.blocks) do
      local hit = block_hit(block_id)
      if hit then return true, hit end
    end
    if route.overlap_block then
      local hit = block_hit(route.overlap_block)
      if hit then return true, hit end
    end
    for _, sw in ipairs(route.switches) do
      for _, other_id in ipairs(switch_routes[sw.id] or {}) do
        local other = state[other_id] and routes_cfg[other_id]
        if other_id ~= route_id and other then
          for _, other_sw in ipairs(other.switches) do
            if other_sw.id == sw.id and other_sw.position ~= sw.position then
              return true, "switch conflict with route " .. other_id .. " on switch " .. tostring(sw.id)
            end
          end
        end
      end
    end
    return false
  end

  local function flank_requirements(route)
    local reqs = {}
    for _, fp in ipairs(route.flank_protection or {}) do reqs[#reqs + 1] = { id = fp.switch_id, position = fp.position } end
    return reqs
  end

  -- Locks switches and flank switches, reserves the overlap block. All or nothing for what it adds.
  local function apply_route(route_id, route, owner, train_id)
    if switch_locks_ref then
      local ok, err = switch_locks_ref.lock_many(route.switches, owner)
      if not ok then return false, "switch lock failed: " .. tostring(err) end
      local flank = flank_requirements(route)
      if #flank > 0 then
        ok, err = switch_locks_ref.lock_many(flank, flank_owner(owner))
        if not ok then return false, "flank protection failed: " .. tostring(err) end
      end
    end
    if route.overlap_block and blocks_ref then
      local ov = blocks_ref[route.overlap_block]
      local holder = train_id or owner
      if ov and ov.state == "FREE" then
        ov.overlap_for = route_id
        ov.state = "RESERVED"
        ov.reserved_by = holder
        ov.occupied_by = nil
      elseif ov and ov.state == "RESERVED" and ov.reserved_by == holder then
        ov.overlap_for = route_id
      elseif ov and ov.state ~= "FAULT" then
        -- (a FAULT overlap block stays FAULT for the operator; a restart does not revive it)
        return false, "overlap block occupied: " .. tostring(route.overlap_block)
      end
    end
    return true
  end

  local function release_route_resources(route_id, owner)
    local route = routes_cfg[route_id]
    if switch_locks_ref then
      switch_locks_ref.release_by_route(owner)
      switch_locks_ref.release_by_route(flank_owner(owner))
    end
    if route and route.overlap_block and blocks_ref then
      local ov = blocks_ref[route.overlap_block]
      -- an overlap block that went FAULT (train ran into it) stays as it is until the operator repairs it
      if ov and ov.overlap_for == route_id then
        ov.overlap_for = nil
        if ov.state == "RESERVED" then
          ov.state = "FREE"
          ov.reserved_by = nil
        end
      end
    end
  end

  -- Set a route (Fahrstraße stellen)
  function self.set_route(route_id, opts)
    opts = opts or {}
    local route = routes_cfg[route_id]
    if not route then return false, "unknown interlocking route: " .. tostring(route_id) end
    local owner = opts.owner or ("route:" .. route_id)

    local rs = state[route_id]
    if rs then
      if rs.owner == owner then return true end
      return false, "route already set: " .. tostring(rs.status)
    end

    local ok, err = blocks_clear(route, opts.train_id)
    if not ok then return false, err end
    ok, err = overlap_clear(route, opts.train_id)
    if not ok then return false, err end
    local conflict, cerr = route_conflict(route_id, route)
    if conflict then return false, cerr end

    ok, err = apply_route(route_id, route, owner, opts.train_id)
    if not ok then
      if switch_locks_ref and not opts.owner then switch_locks_ref.release_by_route(owner) end
      return false, err
    end

    state[route_id] = { status = ROUTE_STATES.SET, owner = owner, train_id = opts.train_id, cleared_blocks = {}, set_at = os.clock() }
    return true
  end

  -- After a restart: the route of a train that was on its way. No clear/conflict checks (the train already holds the
  -- blocks), but switches and overlap are taken again. opts.status and opts.cleared restore the progress.
  function self.restore_route(route_id, opts)
    opts = opts or {}
    local route = routes_cfg[route_id]
    if not route then return false, "unknown interlocking route: " .. tostring(route_id) end
    local owner = opts.owner or ("route:" .. route_id)
    local rs = state[route_id]
    if rs and rs.owner ~= owner then return false, "route already set: " .. tostring(rs.status) end
    if not rs then
      local ok, err = apply_route(route_id, route, owner, opts.train_id)
      if not ok then return false, err end
    end
    local cleared = {}
    for block_id in pairs(opts.cleared or {}) do cleared[block_id] = true end
    state[route_id] = { status = opts.status or ROUTE_STATES.SET, owner = owner, train_id = opts.train_id, cleared_blocks = cleared, set_at = os.clock() }
    return true
  end

  -- Train enters a block of the route — route becomes OCCUPIED. Later blocks of the same route are no news.
  function self.enter_route(route_id, owner)
    local rs = state[route_id]
    if not rs then return false, "route not set" end
    if owner and rs.owner ~= owner then return false, "route belongs to " .. tostring(rs.owner) end
    if rs.status == ROUTE_STATES.SET then
      rs.status = ROUTE_STATES.OCCUPIED
      rs.entered_at = os.clock()
    end
    return true
  end

  -- Section (block) has been cleared — partial dissolution (Teilauflösung)
  function self.section_free(route_id, block_id, owner)
    local rs = state[route_id]
    if not rs then return false, "route not found" end
    if owner and rs.owner ~= owner then return false, "route belongs to " .. tostring(rs.owner) end
    -- a block can only be left after it was entered, even if the enter event of the route never arrived
    rs.status = ROUTE_STATES.DISSOLVING
    rs.cleared_blocks[block_id] = true

    local route = routes_cfg[route_id]
    for _, bid in ipairs(route.blocks) do
      if not rs.cleared_blocks[bid] then return true end
    end
    -- every block cleared → fully dissolved
    self.cancel_route(route_id, rs.owner)
    return true
  end

  -- Cancel/dissolve a route. With an owner, only the route of that owner is touched.
  function self.cancel_route(route_id, owner)
    local rs = state[route_id]
    if not rs then
      if not owner then release_route_resources(route_id, "route:" .. route_id) end
      return true
    end
    if owner and rs.owner ~= owner then return false, "route belongs to " .. tostring(rs.owner) end
    release_route_resources(route_id, rs.owner)
    state[route_id] = nil
    return true
  end

  function self.reset()
    for _, route_id in ipairs(sorted_keys(state)) do self.cancel_route(route_id) end
  end

  -- Key safety check: is it allowed to show GREEN/YELLOW on this signal?
  -- Only if a live route covers it and the block behind it is still ahead of the train: reserved for the route's train,
  -- not yet cleared.
  function self.is_signal_green_allowed(signal_id)
    for _, route_id in ipairs(signal_routes[signal_id] or {}) do
      local rs = state[route_id]
      if rs then
        for _, block_id in ipairs(routes_cfg[route_id].signal_blocks[signal_id] or {}) do
          if not rs.cleared_blocks[block_id] then
            local block = blocks_ref and blocks_ref[block_id]
            local fits
            if not blocks_ref then fits = true
            elseif not block then fits = false
            elseif rs.train_id then fits = block.state == "RESERVED" and block.reserved_by == rs.train_id
            else fits = block.state == "FREE" or block.state == "RESERVED" end
            if fits then return true, route_id end
          end
        end
      end
    end
    return false, "no active route covers signal " .. tostring(signal_id)
  end

  function self.flank_switches(route_id)
    local route = routes_cfg[route_id]
    return route and flank_requirements(route) or {}
  end

  function self.get_route(route_id) return routes_cfg[route_id] end

  function self.get_route_status(route_id)
    local rs = state[route_id]
    local route = routes_cfg[route_id] or {}
    return {
      route_id    = route_id,
      status      = rs and rs.status or ROUTE_STATES.VACANT,
      owner       = rs and rs.owner,
      train_id    = rs and rs.train_id,
      entry_signal= route.entry_signal,
      exit_signal = route.exit_signal,
      overlap     = route.overlap_block,
      set_at      = rs and rs.set_at,
      entered_at  = rs and rs.entered_at,
      cleared     = rs and rs.cleared_blocks or {},
    }
  end

  function self.list()
    local out = {}
    for _, id in ipairs(route_ids) do out[id] = self.get_route_status(id) end
    return out
  end

  -- Live route covering a given block (for panel display)
  function self.route_for_block(block_id)
    for _, route_id in ipairs(block_routes[block_id] or {}) do
      local rs = state[route_id]
      if rs then return route_id, rs.status end
    end
    return nil, nil
  end

  return self
end

interlocking.ROUTE_STATES = ROUTE_STATES

return interlocking
