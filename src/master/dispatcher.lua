--[[
Purpose: Core block dispatcher for the master node.
Public API: new(config, adapters), reserve_route(train_id, route_id), request_route(train_id, route_id, opts), process_queue(), on_sensor_event(block_id, action), on_sensor_event_by_sensor(sensor_id, action), timeout_node(node_id).
]]

local util = require("src.shared.util")
local block_domain = require("src.domain.blocks")
local topology = require("src.domain.topology")
local signal_logic = require("src.domain.signal_logic")
local route_queue = require("src.domain.route_queue")
local switch_locks = require("src.domain.switch_locks")

local dispatcher = {}
local STATES = block_domain.STATES

local TRAIN_STATES = { QUEUED = "QUEUED", RESERVED = "RESERVED", RUNNING = "RUNNING", WAITING = "WAITING", ARRIVED = "ARRIVED", FAULT = "FAULT" }

function dispatcher.new(config, adapters)
  local self = { blocks = block_domain.build_map(config.blocks), routes = util.index_by(config.routes or {}, "id"), trains = {}, adapters = adapters or {}, queue = route_queue.new(), switch_locks = switch_locks.new(), active_routes = {}, deadlocks = {} }
  self.sensor_to_block = topology.build_sensor_to_block(self.blocks)

  local function signal_adapter() return self.adapters.signals end
  local function switch_adapter() return self.adapters.switches end
  local function set_switch(switch_id, position) if not switch_adapter() then return true end; return switch_adapter().setPosition(switch_id, position) end
  local function set_signal(signal_id, aspect) if not signal_id then return true end; return signal_logic.set_aspect(signal_id, aspect, signal_adapter()) end
  local function set_block_red(block) return signal_logic.set_block_red(block, signal_adapter()) end
  local function mark_fault(block) block_domain.fault(block); set_block_red(block) end
  local function route_owner(train_id, route_id) return tostring(train_id) .. ":" .. tostring(route_id) end
  local function get_route(_, route_id) local route = self.routes[route_id]; if not route then return nil, "route not found" end; return route end

  local function blocked_by_blocks(route)
    local out = {}
    for _, block_id in ipairs(route.blocks or {}) do
      local block = self.blocks[block_id]
      if block and not block_domain.is_free(block) then table.insert(out, block.reserved_by or block.occupied_by or block_id) end
    end
    return out
  end

  local function collect_route_blocks(route, train_id)
    local touched = {}
    for _, block_id in ipairs(route.blocks or {}) do
      local block = self.blocks[block_id]
      if not block then return nil, "block not found: " .. tostring(block_id), nil end
      if not block_domain.is_free(block) and block.reserved_by ~= train_id then return nil, "block not free: " .. tostring(block_id), blocked_by_blocks(route) end
      table.insert(touched, block)
    end
    return touched
  end

  local function collect_switch_requirements(route_blocks)
    local requirements, seen = {}, {}
    for _, block in ipairs(route_blocks or {}) do
      for _, switch_def in ipairs(block.switches or {}) do
        local key = tostring(switch_def.id)
        if not seen[key] then table.insert(requirements, { id = switch_def.id, position = switch_def.position }); seen[key] = true end
      end
    end
    return requirements
  end

  local function apply_switches(requirements)
    for _, req in ipairs(requirements or {}) do
      local ok, err = set_switch(req.id, req.position)
      if not ok then return false, "switch set failed: " .. tostring(req.id) .. ": " .. tostring(err) end
    end
    return true
  end

  local function reserve_blocks(route_blocks, train_id) for _, block in ipairs(route_blocks) do block_domain.reserve(block, train_id); set_block_red(block) end end
  local function release_blocks(route_blocks) for _, block in ipairs(route_blocks) do block_domain.release(block); set_block_red(block) end end

  local function update_route_signals(train)
    if not train or not train.route_blocks then return true end
    for _, block in ipairs(train.route_blocks) do set_block_red(block) end
    local current_index = train.route_index or 1
    local next_block = train.route_blocks[current_index]
    if next_block and next_block.state == STATES.RESERVED and next_block.reserved_by == train.id then
      local lookahead = train.route_blocks[current_index + 1]
      local aspect = "GREEN"
      if lookahead and lookahead.state ~= STATES.FREE and lookahead.reserved_by ~= train.id then aspect = "YELLOW" end
      return set_signal(next_block.entry_signal, aspect)
    end
    return true
  end

  local function finish_train(train)
    train.state = TRAIN_STATES.ARRIVED
    train.current_block = nil
    train.route_index = #(train.route_blocks or {}) + 1
    self.switch_locks.release_by_route(train.owner)
    self.active_routes[train.owner] = nil
  end

  local function record_deadlock(item, err)
    self.deadlocks[item.train_id] = { train_id = item.train_id, route_id = item.route_id, reason = err, attempts = item.attempts or 0, blocked_by = item.blocked_by }
  end

  function self.reserve_route(train_id, route_id)
    local route, route_err = get_route(train_id, route_id)
    if not route then return false, route_err end
    local route_blocks, collect_err, blockers = collect_route_blocks(route, train_id)
    if not route_blocks then return false, collect_err, blockers end
    local owner = route_owner(train_id, route_id)
    local switch_requirements = collect_switch_requirements(route_blocks)
    local ok_lock, lock_err = self.switch_locks.lock_many(switch_requirements, owner)
    if not ok_lock then return false, lock_err end
    local ok_switch, switch_err = apply_switches(switch_requirements)
    if not ok_switch then self.switch_locks.release_by_route(owner); for _, block in ipairs(route_blocks) do set_block_red(block) end; return false, switch_err end
    reserve_blocks(route_blocks, train_id)
    local train = { id = train_id, route = route_id, owner = owner, state = TRAIN_STATES.RESERVED, route_blocks = route_blocks, route_index = 1, current_block = nil, destination = route.to, from = route.from, priority = route.priority or 0 }
    self.trains[train_id] = train
    self.active_routes[owner] = train
    self.deadlocks[train_id] = nil
    local ok_signal, signal_err = update_route_signals(train)
    if not ok_signal then release_blocks(route_blocks); self.switch_locks.release_by_route(owner); self.trains[train_id] = nil; self.active_routes[owner] = nil; return false, "signal set failed: " .. tostring(signal_err) end
    return true
  end

  function self.request_route(train_id, route_id, opts)
    local options = opts or {}
    local ok, err, blockers = self.reserve_route(train_id, route_id)
    if ok then return true, "reserved" end
    local route = self.routes[route_id]
    local queued = self.queue.push({ train_id = train_id, route_id = route_id, from = route and route.from, to = route and route.to, priority = options.priority or (route and route.priority) or 0, reason = err, blocked_by = blockers })
    self.trains[train_id] = self.trains[train_id] or { id = train_id }
    self.trains[train_id].state = TRAIN_STATES.QUEUED
    self.trains[train_id].route = route_id
    return false, "queued", queued
  end

  function self.process_queue(limit)
    local processed = {}
    local max = limit or self.queue.size()
    for _ = 1, max do
      local item = self.queue.pop()
      if not item then break end
      local ok, err, blockers = self.reserve_route(item.train_id, item.route_id)
      table.insert(processed, { train_id = item.train_id, route_id = item.route_id, ok = ok, error = err, blocked_by = blockers, attempts = item.attempts })
      if not ok then
        item.reason = err
        item.blocked_by = blockers
        item.attempts = (item.attempts or 0) + 1
        if item.attempts >= 3 then record_deadlock(item, err) end
        self.queue.push(item)
        break
      end
    end
    return processed
  end

  local function train_for_block(block) if not block or not block.reserved_by then return nil end; return self.trains[block.reserved_by] end

  function self.on_sensor_event_by_sensor(sensor_id, action)
    local block_id = topology.block_for_sensor(self.sensor_to_block, sensor_id)
    if not block_id then return false, "unknown sensor: " .. tostring(sensor_id) end
    return self.on_sensor_event(block_id, action)
  end

  function self.on_sensor_event(block_id, action)
    local block = self.blocks[block_id]
    if not block then return false, "block not found" end
    if action == "enter" then
      if block.state == STATES.RESERVED then
        local train = train_for_block(block)
        block_domain.occupy(block)
        if train then train.state = TRAIN_STATES.RUNNING; train.current_block = block_id; for i, route_block in ipairs(train.route_blocks or {}) do if route_block.id == block_id then train.route_index = i end end; update_route_signals(train) end
        return true
      end
      mark_fault(block); return false, "unexpected enter"
    elseif action == "leave" then
      if block.state == STATES.OCCUPIED then
        local train = train_for_block(block)
        block_domain.release(block); set_block_red(block)
        if train then local next_index = (train.route_index or 1) + 1; train.route_index = next_index; train.current_block = nil; if next_index > #(train.route_blocks or {}) then finish_train(train) else train.state = TRAIN_STATES.RESERVED; update_route_signals(train) end end
        self.process_queue(1)
        return true
      end
      mark_fault(block); return false, "unexpected leave"
    end
    return false, "unknown action"
  end

  function self.timeout_node(node_id) for _, block in pairs(self.blocks) do if topology.references_node(block, node_id) then mark_fault(block) end end end
  function self.get_overview() local summary = {}; for id, block in pairs(self.blocks) do summary[id] = { state = block.state, reserved_by = block.reserved_by } end; return summary end
  function self.get_block(id) return self.blocks[id] end
  function self.get_trains() local out = {}; for id, train in pairs(self.trains) do out[id] = { id = train.id, route = train.route, state = train.state, route_index = train.route_index, current_block = train.current_block, destination = train.destination, priority = train.priority } end; return out end
  function self.get_queue() return self.queue.list() end
  function self.get_switch_locks() return self.switch_locks.list() end
  function self.get_deadlocks() return self.deadlocks end

  return self
end

dispatcher.STATES = STATES
dispatcher.TRAIN_STATES = TRAIN_STATES

return dispatcher
