--[[
Purpose: Topology lookup helpers for railway blocks and node references.
Public API: build_sensor_to_block(block_map), block_for_sensor(map, sensor_id), references_node(block, node_id).
]]

local topology = {}

function topology.build_sensor_to_block(block_map)
  local sensor_to_block = {}
  for _, block in pairs(block_map or {}) do
    for _, sensor_id in ipairs(block.sensors or {}) do
      sensor_to_block[sensor_id] = block.id
    end
  end
  return sensor_to_block
end

function topology.block_for_sensor(sensor_to_block, sensor_id)
  return sensor_to_block and sensor_to_block[sensor_id] or nil
end

function topology.references_node(block, node_id)
  if not block then
    return false
  end

  if block.entry_signal == node_id or block.exit_signal == node_id then
    return true
  end

  for _, sensor_id in ipairs(block.sensors or {}) do
    if sensor_id == node_id then
      return true
    end
  end

  for _, switch_def in ipairs(block.switches or {}) do
    if switch_def.id == node_id then
      return true
    end
  end

  return false
end

return topology
