--[[
Purpose: Deadlock detection over the wait-for graph of the route queue (Gesamtkonzept Kap. 4.4, test C-12).
Public API: find_cycles(items) -> cycles, truncated. items: list of { train_id, blocked_by = {train ids} }; a cycle is a list of train ids starting at the smallest id.
Notes: only trains that wait themselves can close a loop. A deadlock is reported, never "healed": existing reservations are not taken away (4.4). At most MAX_ITEMS waiting trains are looked at.
]]

local deadlock = {}

local MAX_ITEMS = 200

function deadlock.find_cycles(items)
  local waits, ids = {}, {}
  local truncated = false
  for i, item in ipairs(items or {}) do
    if i > MAX_ITEMS then truncated = true; break end
    local id = tostring(item.train_id)
    if not waits[id] then ids[#ids + 1] = id; waits[id] = {} end
    for _, blocker in ipairs(item.blocked_by or {}) do waits[id][#waits[id] + 1] = tostring(blocker) end
  end
  table.sort(ids)
  for _, id in ipairs(ids) do table.sort(waits[id]) end

  local cycles = {}
  for _, start in ipairs(ids) do
    -- only cycles whose smallest member is `start`: every cycle is found once
    local path, on_path = { start }, { [start] = true }
    local function walk(current)
      for _, nxt in ipairs(waits[current] or {}) do
        if nxt == start then
          local copy = {}
          for i, v in ipairs(path) do copy[i] = v end
          cycles[#cycles + 1] = copy
        elseif waits[nxt] and not on_path[nxt] and nxt > start then
          on_path[nxt] = true; path[#path + 1] = nxt
          walk(nxt)
          path[#path] = nil; on_path[nxt] = nil
        end
      end
    end
    walk(start)
  end
  return cycles, truncated
end

return deadlock
