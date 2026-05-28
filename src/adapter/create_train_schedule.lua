--[[
Purpose: Adapter for applying Create train schedules from service plans.
Public API: new(peripherals, opts), build_schedule(stops), apply(train_id, schedule), apply_stops(train_id, stops).
]]

local method_helper = require("src.adapter.methods")

local create_train_schedule = {}

local function copy_stop(stop)
  return {
    from = stop.from,
    to = stop.to or stop.destination,
    route_id = stop.route_id,
    station_id = stop.station_id or stop.to or stop.destination,
    dwell_seconds = stop.dwell_seconds or 0,
    kind = stop.kind
  }
end

function create_train_schedule.build_schedule(stops)
  local schedule = { stops = {} }
  for _, stop in ipairs(stops or {}) do
    table.insert(schedule.stops, copy_stop(stop))
  end
  return schedule
end

function create_train_schedule.new(peripherals, opts)
  local options = opts or {}
  local hardware = options.hardware
  local self = {}

  local function target_for(train_id)
    if hardware then return hardware.target(train_id) end
    return train_id
  end

  local function try_methods(train_id, schedule)
    local target = target_for(train_id)
    local methods = { "setSchedule", "setTrainSchedule", "applySchedule" }
    local last_err = nil
    for _, method in ipairs(methods) do
      local ok, err = method_helper.call(peripherals, target, method, schedule)
      if ok then return true end
      last_err = err
    end
    return false, last_err or "no schedule method available"
  end

  function self.apply(train_id, schedule)
    if not train_id or train_id == "" then return false, "missing train_id" end
    if type(schedule) ~= "table" then return false, "schedule must be table" end
    return try_methods(train_id, schedule)
  end

  function self.apply_stops(train_id, stops)
    return self.apply(train_id, create_train_schedule.build_schedule(stops))
  end

  return self
end

return create_train_schedule
