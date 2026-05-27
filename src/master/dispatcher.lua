--[[
Purpose: Core block dispatcher for the master node.
Public API: new(config, adapters), reserve_route(train_id, route_id), on_sensor_event(block_id, action), on_sensor_event_by_sensor(sensor_id, action), timeout_node(node_id).
]]

local util = require("src.shared.util")
local block_domain = require("src.domain.blocks")
local topology = require("src.domain.topology")
local signal_logic = require("src.domain.signal_logic")

local dispatcher = {}
local STATES = block_domain.STATES

function dispatcher.new(config, adapters)
  local self = {
    blocks = block_domain.build_map(config.blocks),
    routes = util.index_by(config.routes or {}, "id"),
    trains = {},
    adapters = adapters or {}
  }

  self.sensor_to_block = topology.build_sensor_to_block(self.blocks)

  local function signal_adapter()
    return self.adapters.signals
  end

  local function switch_adapter()
    return self.adapters.switches
  end

  local function set_switch(switch_id, position)
    if not switch_adapter() then
      return true
    end
    return switch_adapter().setPosition(switch_id, position)
  end

  local function set_block_red(block)
    return signal_logic.set_block_red(block, signal_adapter())
  end

  local function mark_fault(block)
    block_domain.fault(block)
    set_block_red(block)
  end

  local function collect_route_blocks(route)
    local touched = {}
    for _, block_id in ipairs(route.blocks) do
      local block = self.blocks[block_id]
      if not block then
        return nil, "block not found: " .. block_id
      end
      if not block_domain.is_free(block) then
        return nil, "block not free: " .. block_id
      end
      table.insert(touched, block)
    end
    return touched
  end

  local function apply_switches(route_blocks)
    for _, block in ipairs(route_blocks) do
      for _, switch_def in ipairs(block.switches or {}) do
        local ok, err = set_switch(switch_def.id, switch_def.position)
        if not ok then
          return false, "switch set failed: " .. tostring(switch_def.id) .. ": " .. tostring(err)
        end
      end
    end
    return true
  end

  local function reserve_blocks(route_blocks, train_id)
    for _, block in ipairs(route_blocks) do
      block_domain.reserve(block, train_id)
      set_block_red(block)
    end
  end

  local function release_blocks(route_blocks)
    for _, block in ipairs(route_blocks) do
      block_domain.release(block)
      set_block_red(block)
    end
  end

  function self.reserve_route(train_id, route_id)
    local route = self.routes[route_id]
    if not route then
      return false, "route not found"
    end

    local route_blocks, collect_err = collect_route_blocks(route)
    if not route_blocks then
      return false, collect_err
    end

    local ok_switch, switch_err = apply_switches(route_blocks)
    if not ok_switch then
      for _, block in ipairs(route_blocks) do
        set_block_red(block)
      end
      return false, switch_err
    end

    reserve_blocks(route_blocks, train_id)

    local first = route_blocks[1]
    if first then
      local ok_signal, signal_err = signal_logic.set_entry_green(first, signal_adapter())
      if not ok_signal then
        release_blocks(route_blocks)
        return false, "signal set failed: " .. tostring(first.entry_signal) .. ": " .. tostring(signal_err)
      end
    end

    self.trains[train_id] = { id = train_id, route = route_id }
    return true
  end

  function self.on_sensor_event_by_sensor(sensor_id, action)
    local block_id = topology.block_for_sensor(self.sensor_to_block, sensor_id)
    if not block_id then
      return false, "unknown sensor: " .. tostring(sensor_id)
    end
    return self.on_sensor_event(block_id, action)
  end

  function self.on_sensor_event(block_id, action)
    local block = self.blocks[block_id]
    if not block then
      return false, "block not found"
    end

    if action == "enter" then
      if block.state == STATES.RESERVED then
        block_domain.occupy(block)
        return true
      end
      mark_fault(block)
      return false, "unexpected enter"
    elseif action == "leave" then
      if block.state == STATES.OCCUPIED then
        block_domain.release(block)
        set_block_red(block)
        return true
      end
      mark_fault(block)
      return false, "unexpected leave"
    end

    return false, "unknown action"
  end

  function self.timeout_node(node_id)
    for _, block in pairs(self.blocks) do
      if topology.references_node(block, node_id) then
        mark_fault(block)
      end
    end
  end

  function self.get_overview()
    local summary = {}
    for id, block in pairs(self.blocks) do
      summary[id] = { state = block.state, reserved_by = block.reserved_by }
    end
    return summary
  end

  function self.get_block(id)
    return self.blocks[id]
  end

  function self.get_trains()
    return util.deepcopy(self.trains)
  end

  return self
end

dispatcher.STATES = STATES

return dispatcher
