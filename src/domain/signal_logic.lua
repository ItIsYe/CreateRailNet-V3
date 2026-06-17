--[[
Purpose: Domain helpers for railway signal aspects.
Public API: set_aspect(signal_id, aspect, adapter), set_block_red(block, adapter), set_entry_green(block, adapter).
]]

local signal_logic = {}

function signal_logic.set_aspect(signal_id, aspect, adapter)
  if not signal_id or not adapter then
    return true
  end
  return adapter.setAspect(signal_id, aspect)
end

function signal_logic.set_block_red(block, adapter)
  if not block then return true end
  local ok1, err1 = signal_logic.set_aspect(block.entry_signal, "RED", adapter)
  local ok2, err2 = signal_logic.set_aspect(block.exit_signal, "RED", adapter)
  if not ok1 then return false, "entry signal failed: " .. tostring(err1) end
  if not ok2 then return false, "exit signal failed: " .. tostring(err2) end
  return true
end

function signal_logic.set_entry_green(block, adapter)
  if not block then
    return true
  end
  return signal_logic.set_aspect(block.entry_signal, "GREEN", adapter)
end

return signal_logic
