--[[
Purpose: Core block dispatcher for the master node.
Public API: new(config, adapters), reserve_route(train_id, route_id), on_sensor_event(block_id, action), on_sensor_event_by_sensor(sensor_id, action), timeout_node(node_id).
]]

local util = require("src.shared.util")

local dispatcher = {}

local STATES = {
  FREE = "FREE",
  RESERVED = "RESERVED",
  OCCUPIED = "OCCUPIED",
  FAULT = "FAULT"
}

local function build_block_map(blocks)
  local map = {}
  for _, block in ipairs(blocks or {}) do
    map[block.id] = {
      id = block.id,
      entry_signal = block.entry_signal,
      exit_signal = block.exit_signal,
      sensors = block.sensors or {},
      switches = block.switches or {},
      state = STATES.FREE,
      reserved_by = nil
    }
  end
  return map
end

function dispatcher.new(config, adapters)
  local self = {
    blocks = build_block_map(config.blocks),
    routes = util.index_by(config.routes or {}, "id"),
    trains = {},
    adapters = adapters or {},
    sensor_to_block = {}
  }

  for _, block in pairs(self.blocks) do
    for _, sensor_id in ipairs(block.sensors) do
      self.sensor_to_block[sensor_id] = block.id
    end
  end

  local function set_signal(signal_id, aspect)
    if not self.adapters.signals then
      return true
    end
    return self.adapters.signals.setAspect(signal_id, aspect)
  end

  local function set_switch(switch_id, position)
    if not self.adapters.switches then
      return true
    end
    return self.adapters.switches.setPosition(switch_id, position)
  end

  local function force_red(block)
    set_signal(block.entry_signal, "RED")
    set_signal(block.exit_signal, "RED")
  end

  local function fail_safe(block)
    block.state = STATES.FAULT
    force_red(block)
  end

  function self.reserve_route(train_id, route_id)
    local route = self.routes[route_id]
    if not route then
      return false, "route not found"
    end

    local touched = {}
    for _, block_id in ipairs(route.blocks) do
      local block = self.blocks[block_id]
      if not block then
        return false, "block not found: " .. block_id
      end
      if block.state ~= STATES.FREE then
        return false, "block not free: " .. block_id
      end
      table.insert(touched, block)
    end

    for _, block in ipairs(touched) do
      for _, switch_def in ipairs(block.switches) do
        local ok, err = set_switch(switch_def.id, switch_def.position)
        if not ok then
          for _, rollback_block in ipairs(touched) do
            force_red(rollback_block)
          end
          return false, "switch set failed: " .. tostring(switch_def.id) .. ": " .. tostring(err)
        end
      end
    end

    for _, block in ipairs(touched) do
      block.state = STATES.RESERVED
      block.reserved_by = train_id
      force_red(block)
    end

    local first = touched[1]
    if first then
      local ok, err = set_signal(first.entry_signal, "GREEN")
      if not ok then
        for _, rollback_block in ipairs(touched) do
          rollback_block.state = STATES.FREE
          rollback_block.reserved_by = nil
          force_red(rollback_block)
        end
        return false, "signal set failed: " .. tostring(first.entry_signal) .. ": " .. tostring(err)
      end
    end

    self.trains[train_id] = { id = train_id, route = route_id }
    return true
  end

  function self.on_sensor_event_by_sensor(sensor_id, action)
    local block_id = self.sensor_to_block[sensor_id]
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
        block.state = STATES.OCCUPIED
        return true
      end
      fail_safe(block)
      return false, "unexpected enter"
    elseif action == "leave" then
      if block.state == STATES.OCCUPIED then
        block.state = STATES.FREE
        block.reserved_by = nil
        force_red(block)
        return true
      end
      fail_safe(block)
      return false, "unexpected leave"
    end

    return false, "unknown action"
  end

  function self.timeout_node(node_id)
    for _, block in pairs(self.blocks) do
      for _, sensor_id in ipairs(block.sensors) do
        if sensor_id == node_id then
          fail_safe(block)
        end
      end
      for _, switch_def in ipairs(block.switches) do
        if switch_def.id == node_id then
          fail_safe(block)
        end
      end
      if block.entry_signal == node_id or block.exit_signal == node_id then
        fail_safe(block)
      end
    end
  end

  function self.get_overview()
    local summary = {}
    for id, block in pairs(self.blocks) do
      summary[id] = {
        state = block.state,
        reserved_by = block.reserved_by
      }
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
