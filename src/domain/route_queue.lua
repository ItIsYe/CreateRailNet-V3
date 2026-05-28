--[[
Purpose: Priority queue helper for pending route requests.
Public API: new() -> queue with push, pop, list, size.
]]

local route_queue = {}

function route_queue.new()
  local items = {}
  local seq = 0
  local self = {}

  function self.push(request)
    seq = seq + 1
    local item = {
      seq = seq,
      train_id = request.train_id,
      route_id = request.route_id,
      from = request.from,
      to = request.to,
      priority = request.priority or 0,
      state = "QUEUED",
      reason = request.reason
    }
    table.insert(items, item)
    return item
  end

  function self.pop()
    if #items == 0 then return nil end
    local best_index = 1
    for i = 2, #items do
      local best = items[best_index]
      local candidate = items[i]
      if candidate.priority > best.priority or (candidate.priority == best.priority and candidate.seq < best.seq) then
        best_index = i
      end
    end
    return table.remove(items, best_index)
  end

  function self.size()
    return #items
  end

  function self.list()
    local out = {}
    for i, item in ipairs(items) do
      out[i] = {
        seq = item.seq,
        train_id = item.train_id,
        route_id = item.route_id,
        from = item.from,
        to = item.to,
        priority = item.priority,
        state = item.state,
        reason = item.reason
      }
    end
    return out
  end

  return self
end

return route_queue
