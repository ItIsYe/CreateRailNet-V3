--[[
Purpose: Service plan / schedule model for trains.
Public API: new(config) -> registry with get, assign, advance, current_stop, list.
]]

local service_plans = {}

local STOP_STATES = {
  PENDING = "PENDING",
  REQUESTED = "REQUESTED",
  AUTHORIZED = "AUTHORIZED",
  ARRIVED = "ARRIVED",
  COMPLETE = "COMPLETE",
  FAULT = "FAULT"
}

local function copy(src)
  local dst = {}
  for k, v in pairs(src or {}) do
    if type(v) == "table" then dst[k] = copy(v) else dst[k] = v end
  end
  return dst
end

local function normalize_stop(stop, index)
  return {
    index = index,
    id = stop.id or ("STOP-" .. tostring(index)),
    from = stop.from,
    to = stop.to or stop.destination,
    route_id = stop.route_id,
    kind = stop.kind,
    dwell_seconds = stop.dwell_seconds or 0,
    state = stop.state or STOP_STATES.PENDING
  }
end

local function normalize_plan(plan)
  local stops = {}
  for i, stop in ipairs(plan.stops or {}) do
    stops[i] = normalize_stop(stop, i)
  end
  return {
    id = plan.id,
    display_name = plan.display_name or plan.id,
    train_id = plan.train_id,
    repeat_plan = plan.repeat_plan or false,
    state = plan.state or "READY",
    current_index = plan.current_index or 1,
    stops = stops
  }
end

function service_plans.new(config)
  local plans = {}
  local train_to_plan = {}
  local self = {}

  for _, plan in ipairs((config and config.service_plans) or (config and config.schedules) or {}) do
    if plan.id then
      plans[plan.id] = normalize_plan(plan)
      if plan.train_id then train_to_plan[plan.train_id] = plan.id end
    end
  end

  for _, node in ipairs((config and config.nodes) or {}) do
    if node.role == "train" and node.service_plan then
      train_to_plan[node.train_id or node.id] = node.service_plan
    end
  end

  function self.get(plan_id)
    return plans[plan_id]
  end

  function self.for_train(train_id)
    local plan_id = train_to_plan[train_id]
    return plan_id and plans[plan_id] or nil
  end

  function self.assign(train_id, plan_id)
    if not plans[plan_id] then return nil, "service plan not found" end
    train_to_plan[train_id] = plan_id
    plans[plan_id].train_id = train_id
    plans[plan_id].state = "ACTIVE"
    return plans[plan_id]
  end

  function self.current_stop(train_id)
    local plan = self.for_train(train_id)
    if not plan then return nil, "no service plan assigned" end
    return plan.stops[plan.current_index], plan
  end

  function self.mark_current(train_id, state)
    local stop, plan = self.current_stop(train_id)
    if not stop then return nil, plan end
    stop.state = state
    return stop, plan
  end

  function self.advance(train_id)
    local plan = self.for_train(train_id)
    if not plan then return nil, "no service plan assigned" end
    if plan.stops[plan.current_index] then
      plan.stops[plan.current_index].state = STOP_STATES.COMPLETE
    end
    plan.current_index = plan.current_index + 1
    if plan.current_index > #plan.stops then
      if plan.repeat_plan and #plan.stops > 0 then
        plan.current_index = 1
        for i, stop in ipairs(plan.stops) do
          stop.index = i
          stop.state = STOP_STATES.PENDING
        end
      else
        plan.state = "COMPLETE"
      end
    end
    return plan.stops[plan.current_index], plan
  end

  function self.list()
    local out = {}
    for id, plan in pairs(plans) do out[id] = copy(plan) end
    return out
  end

  return self
end

service_plans.STOP_STATES = STOP_STATES

return service_plans
