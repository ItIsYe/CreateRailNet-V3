--[[
Purpose: Railway interlocking (Stellwerk) — Fahrstraßen, Flankenschutz, Durchrutschweg.
Implements: Route setting, conflicting routes, overlap (Durchrutschweg),
flank protection (Flankenschutz), protection switches (Schutzweichen).

A Fahrstrasse (route/interlocking path) is an atomic safety unit:
  - entry_signal: must show RED until route is set
  - exit_signal: the signal at the end of the route
  - blocks: all blocks included
  - switches: must all be in correct position AND locked
  - flank_protection: list of {switch_id, position} — neighboring switches
    set to block entry from flanks
  - overlap: additional block beyond the exit signal (Durchrutschweg)
    reserved but signal stays RED — gives space if train overruns stop

Status: VACANT → SETTING → SET → OCCUPIED → DISSOLVING → VACANT

Public API:
  new(config, switch_locks, block_domain_ref)
  set_route(route_id) -> ok, err
  cancel_route(route_id) -> ok, err
  enter_route(route_id) -> ok, err  [called when train enters entry block]
  section_free(route_id, block_id) -> ok  [called when block cleared, partial dissolution]
  get_route_status(route_id) -> status table
  is_signal_green_allowed(signal_id) -> bool, reason
  list() -> all route statuses
]]

local interlocking = {}

local ROUTE_STATES = {
  VACANT     = "VACANT",
  SETTING    = "SETTING",     -- switches being set
  SET        = "SET",         -- all conditions met, signal can show PROCEED
  OCCUPIED   = "OCCUPIED",    -- train has entered
  DISSOLVING = "DISSOLVING",  -- partial dissolution as train progresses
}

function interlocking.new(config, switch_locks_ref, blocks_ref)
  local routes_cfg = {}
  for _, r in ipairs(config.interlocking_routes or config.routes or {}) do
    -- An interlocking route has additional safety fields
    routes_cfg[r.id] = r
  end

  local state = {}  -- route_id -> { status, locked_switches, locked_blocks, overlap_block }

  local self = {}
  self.ROUTE_STATES = ROUTE_STATES

  -- Check whether all blocks in this route are free
  local function blocks_clear(route)
    for _, block_id in ipairs(route.blocks or {}) do
      local block = blocks_ref and blocks_ref[block_id]
      if block and block.state ~= "FREE" then
        return false, "block occupied: " .. tostring(block_id)
      end
    end
    return true
  end

  -- Check overlap (Durchrutschweg) block
  local function overlap_clear(route)
    local ov = route.overlap_block
    if not ov then return true end
    local block = blocks_ref and blocks_ref[ov]
    if block and block.state ~= "FREE" then
      return false, "overlap block occupied: " .. tostring(ov)
    end
    return true
  end

  -- Check whether all flank protection conditions can be met
  local function flanks_settable(route, owner)
    for _, fp in ipairs(route.flank_protection or {}) do
      if switch_locks_ref then
        local ok, err = switch_locks_ref.can_lock(fp.switch_id, fp.position, owner)
        if not ok then return false, "flank switch conflict: " .. tostring(fp.switch_id) .. ": " .. tostring(err) end
      end
    end
    return true
  end

  -- Lock all flank protection switches
  local function lock_flanks(route, owner)
    local reqs = {}
    for _, fp in ipairs(route.flank_protection or {}) do
      table.insert(reqs, { id = fp.switch_id, position = fp.position })
    end
    if switch_locks_ref and #reqs > 0 then
      return switch_locks_ref.lock_many(reqs, owner .. ":flank")
    end
    return true
  end

  -- Check whether setting this route conflicts with any active route
  local function route_conflict(route_id, route)
    for other_id, other_state in pairs(state) do
      if other_id ~= route_id and other_state.status ~= ROUTE_STATES.VACANT then
        local other_route = routes_cfg[other_id]
        if other_route then
          -- Check block overlap
          local other_blocks = {}
          for _, b in ipairs(other_route.blocks or {}) do other_blocks[b] = true end
          if other_route.overlap_block then other_blocks[other_route.overlap_block] = true end
          for _, b in ipairs(route.blocks or {}) do
            if other_blocks[b] then
              return true, "block conflict with route " .. other_id .. " on block " .. b
            end
          end
          -- Check switch conflict (different position required)
          local other_switches = {}
          for _, sw in ipairs((other_route.switches or {})) do other_switches[sw.id] = sw.position end
          for _, sw in ipairs(route.switches or {}) do
            if other_switches[sw.id] and other_switches[sw.id] ~= sw.position then
              return true, "switch conflict with route " .. other_id .. " on switch " .. sw.id
            end
          end
        end
      end
    end
    return false
  end

  -- Set a route (Fahrstraße stellen)
  function self.set_route(route_id)
    local route = routes_cfg[route_id]
    if not route then return false, "unknown interlocking route: " .. tostring(route_id) end

    local rs = state[route_id]
    if rs and rs.status ~= ROUTE_STATES.VACANT then
      return false, "route already set: " .. tostring(rs.status)
    end

    -- 1. Check all blocks clear
    local ok, err = blocks_clear(route)
    if not ok then return false, err end

    -- 2. Check overlap (Durchrutschweg) clear
    ok, err = overlap_clear(route)
    if not ok then return false, err end

    -- 3. Check no conflicting routes active
    local conflict, cerr = route_conflict(route_id, route)
    if conflict then return false, cerr end

    local owner = "route:" .. route_id

    -- 4. Check flank protection switches available
    ok, err = flanks_settable(route, owner)
    if not ok then return false, err end

    -- 5. Lock main route switches
    if switch_locks_ref then
      local reqs = {}
      for _, sw in ipairs(route.switches or {}) do
        table.insert(reqs, { id = sw.id, position = sw.position })
      end
      ok, err = switch_locks_ref.lock_many(reqs, owner)
      if not ok then return false, "switch lock failed: " .. tostring(err) end
    end

    -- 6. Lock flank protection switches
    ok, err = lock_flanks(route, owner)
    if not ok then
      if switch_locks_ref then switch_locks_ref.release_by_route(owner) end
      return false, "flank protection failed: " .. tostring(err)
    end

    -- 7. Lock overlap block if present
    if route.overlap_block and blocks_ref then
      local ov_block = blocks_ref[route.overlap_block]
      if ov_block then
        -- Mark overlap as "overlap-reserved" — not as regular reserved
        ov_block.overlap_for = route_id
        ov_block.state = "RESERVED"
        ov_block.reserved_by = owner
      end
    end

    -- Route is now SET — entry signal may proceed to GREEN
    state[route_id] = {
      status = ROUTE_STATES.SET,
      owner = owner,
      route_id = route_id,
      cleared_blocks = {},
      set_at = os.clock()
    }

    return true
  end

  -- Train enters entry block — route becomes OCCUPIED
  function self.enter_route(route_id)
    local rs = state[route_id]
    if not rs then return false, "route not set" end
    if rs.status ~= ROUTE_STATES.SET then
      return false, "route not in SET state: " .. tostring(rs.status)
    end
    rs.status = ROUTE_STATES.OCCUPIED
    rs.entered_at = os.clock()
    return true
  end

  -- Section (block) has been cleared — partial dissolution (Teilauflösung)
  function self.section_free(route_id, block_id)
    local rs = state[route_id]
    if not rs then return false, "route not found" end
    if rs.status ~= ROUTE_STATES.OCCUPIED and rs.status ~= ROUTE_STATES.DISSOLVING then
      return false, "route not occupied"
    end
    rs.status = ROUTE_STATES.DISSOLVING
    rs.cleared_blocks = rs.cleared_blocks or {}
    rs.cleared_blocks[block_id] = true

    -- Check if all blocks cleared → fully dissolve
    local route = routes_cfg[route_id]
    local all_clear = true
    for _, bid in ipairs(route and route.blocks or {}) do
      if not rs.cleared_blocks[bid] then all_clear = false; break end
    end

    if all_clear then
      self.cancel_route(route_id)
    end
    return true
  end

  -- Cancel/dissolve a route
  function self.cancel_route(route_id)
    local rs = state[route_id]
    local owner = (rs and rs.owner) or ("route:" .. route_id)

    -- Release switch locks
    if switch_locks_ref then
      switch_locks_ref.release_by_route(owner)
      switch_locks_ref.release_by_route(owner .. ":flank")
    end

    -- Release overlap block
    local route = routes_cfg[route_id]
    if route and route.overlap_block and blocks_ref then
      local ov = blocks_ref[route.overlap_block]
      if ov and ov.overlap_for == route_id then
        ov.overlap_for = nil
        ov.state = "FREE"
        ov.reserved_by = nil
      end
    end

    state[route_id] = { status = ROUTE_STATES.VACANT }
    return true
  end

  -- Key safety check: is it allowed to show GREEN on this signal?
  -- GREEN is ONLY allowed if a route is SET and this signal is the entry signal of that route.
  function self.is_signal_green_allowed(signal_id)
    for route_id, rs in pairs(state) do
      if rs.status == ROUTE_STATES.SET or rs.status == ROUTE_STATES.OCCUPIED then
        local route = routes_cfg[route_id]
        if route and route.entry_signal == signal_id then
          return true, route_id
        end
      end
    end
    return false, "no active route covers signal " .. tostring(signal_id)
  end

  function self.get_route_status(route_id)
    local rs = state[route_id] or { status = ROUTE_STATES.VACANT }
    local route = routes_cfg[route_id] or {}
    return {
      route_id    = route_id,
      status      = rs.status,
      entry_signal= route.entry_signal,
      exit_signal = route.exit_signal,
      overlap     = route.overlap_block,
      set_at      = rs.set_at,
      entered_at  = rs.entered_at,
      cleared     = rs.cleared_blocks or {},
    }
  end

  function self.list()
    local out = {}
    for id, _ in pairs(routes_cfg) do
      out[id] = self.get_route_status(id)
    end
    return out
  end

  -- Get route covering a given block (for panel display)
  function self.route_for_block(block_id)
    for route_id, rs in pairs(state) do
      if rs.status ~= ROUTE_STATES.VACANT then
        local route = routes_cfg[route_id]
        if route then
          for _, bid in ipairs(route.blocks or {}) do
            if bid == block_id then return route_id, rs.status end
          end
        end
      end
    end
    return nil, nil
  end

  return self
end

return interlocking
