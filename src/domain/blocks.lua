--[[
Purpose: Domain helpers for railway block state and block maps.
Public API: STATES, build_map(blocks), reserve(block, train_id), occupy(block), release(block), fault(block), is_free(block).
]]

local blocks = {}

blocks.STATES = {
  FREE = "FREE",
  RESERVED = "RESERVED",
  OCCUPIED = "OCCUPIED",
  FAULT = "FAULT"
}

function blocks.build_map(definitions)
  local map = {}
  for _, block in ipairs(definitions or {}) do
    map[block.id] = {
      id = block.id,
      entry_signal = block.entry_signal,
      exit_signal = block.exit_signal,
      sensors = block.sensors or {},
      switches = block.switches or {},
      state = blocks.STATES.FREE,
      reserved_by = nil
    }
  end
  return map
end

function blocks.is_free(block)
  return block and block.state == blocks.STATES.FREE
end

function blocks.reserve(block, train_id)
  block.state = blocks.STATES.RESERVED
  block.reserved_by = train_id
end

function blocks.occupy(block)
  block.state = blocks.STATES.OCCUPIED
end

function blocks.release(block)
  block.state = blocks.STATES.FREE
  block.reserved_by = nil
end

function blocks.fault(block)
  block.state = blocks.STATES.FAULT
end

return blocks
