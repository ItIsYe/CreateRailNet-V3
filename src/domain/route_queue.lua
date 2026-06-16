--[[
Purpose: Priority queue helper for pending route requests with aging metadata.
Public API: new() -> queue with push, pop, list, size, reprioritize.
]]

local route_queue = {}

function route_queue.new()
  local items = {}
  local seq = 0
  local self = {}

  function self.push(request)
    seq = seq + 1
    local item = {
      seq = request.seq or seq,
      train_id = request.train_id,
      route_id = request.route_id,
      from = request.from,
      to = request.to,
      priority = request.priority or 0,
      base_priority = request.base_priority or request.priority or 0,
      attempts = (request.attempts or 0),
      blocked_by = request.blocked_by,
      queued_at = request.queued_at or os.time(),
      state = "QUEUED",
      reason = request.reason
    }
    table.insert(items, item)
    return item
  end

  local last_reprioritize = 0
  local REPRIORITIZE_INTERVAL = 10  -- seconds; avoids O(N) on every pop

  function self.reprioritize(now, aging_step_s, aging_bonus)
    local clock = now or os.time()
    local step = aging_step_s or 30
    local bonus = aging_bonus or 1
    last_reprioritize = clock
    for _, item in ipairs(items) do
      local age_steps = math.floor((clock - (item.queued_at or clock)) / step)
      item.priority = (item.base_priority or item.priority or 0) + (age_steps * bonus) + (item.attempts or 0)
    end
  end

  function self.pop()
    if #items == 0 then return nil end
    local now = os.time()
    if now - last_reprioritize >= REPRIORITIZE_INTERVAL then
      self.reprioritize(now)
    end
    local best_index = 1
    for i = 2, #items do
      local best = items[best_index]
      local candidate = items[i]
      if candidate.priority > best.priority or (candidate.priority == best.priority and candidate.seq < best.seq) then best_index = i end
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
        base_priority = item.base_priority,
        attempts = item.attempts,
        blocked_by = item.blocked_by,
        queued_at = item.queued_at,
        state = item.state,
        reason = item.reason
      }
    end
    return out
  end

  return self
end

return route_queue
