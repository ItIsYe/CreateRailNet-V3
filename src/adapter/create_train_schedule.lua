--[[
Purpose: Adapter for applying official Create train schedules through Create Train Station peripherals.
Public API: new(peripherals, opts), build_schedule(stops, opts), apply(train_id, schedule, opts), apply_stops(train_id, stops, opts).
]]

local create_train_schedule = {}

local DEFAULT_TIME_UNIT_SECONDS = 1

local function destination_text(stop)
  return stop.station_name or stop.station_id or stop.to or stop.destination
end

local function dwell_seconds(stop)
  local value = stop.dwell_seconds or stop.dwell or 0
  if type(value) ~= "number" or value < 0 then value = 0 end
  return value
end

local function build_delay_condition(seconds)
  return {
    id = "create:delay",
    data = {
      value = seconds,
      time_unit = DEFAULT_TIME_UNIT_SECONDS
    }
  }
end

local function build_entry(stop)
  local destination = destination_text(stop)
  if not destination or destination == "" then return nil, "missing destination/station name" end
  return {
    instruction = {
      id = "create:destination",
      data = {
        text = destination
      }
    },
    conditions = {
      {
        build_delay_condition(dwell_seconds(stop))
      }
    }
  }
end

function create_train_schedule.build_schedule(stops, opts)
  local options = opts or {}
  local schedule = {
    cyclic = options.cyclic == true,
    entries = {}
  }

  for _, stop in ipairs(stops or {}) do
    local entry, err = build_entry(stop)
    if not entry then return nil, err end
    table.insert(schedule.entries, entry)
  end

  return schedule
end

function create_train_schedule.new(peripherals, opts)
  local options = opts or {}
  local hardware = options.hardware
  local default_station = options.station or options.create_station or options.schedule_station
  local require_train_present = options.require_train_present ~= false
  local self = {}

  local function target_for(train_id, apply_opts)
    local call_opts = apply_opts or {}
    if call_opts.station then return call_opts.station end
    if call_opts.create_station then return call_opts.create_station end
    if call_opts.schedule_station then return call_opts.schedule_station end
    if default_station then return default_station end
    if hardware and hardware.target then return hardware.target(train_id) end
    return train_id
  end

  local function wrap_station(target)
    if not peripherals or not peripherals.wrap then return nil, "peripherals wrapper unavailable" end
    local station = peripherals.wrap(target)
    if not station then return nil, "station peripheral not found: " .. tostring(target) end
    return station
  end

  local function check_train_present(station)
    if not require_train_present then return true end
    if type(station.isTrainPresent) ~= "function" then return false, "station missing isTrainPresent" end
    local ok, present = pcall(function() return station.isTrainPresent() end)
    if not ok then return false, tostring(present) end
    if not present then return false, "no train present at station" end
    return true
  end

  local function set_schedule(station, schedule)
    if type(station.setSchedule) ~= "function" then return false, "station missing setSchedule" end
    local ok, err = pcall(function() return station.setSchedule(schedule) end)
    if not ok then return false, tostring(err) end
    return true
  end

  function self.apply(train_id, schedule, apply_opts)
    if not train_id or train_id == "" then return false, "missing train_id" end
    if type(schedule) ~= "table" then return false, "schedule must be table" end
    if type(schedule.entries) ~= "table" then return false, "schedule must be official Create format with entries" end

    local target = target_for(train_id, apply_opts)
    local station, wrap_err = wrap_station(target)
    if not station then return false, wrap_err end

    local present_ok, present_err = check_train_present(station)
    if not present_ok then return false, present_err end

    return set_schedule(station, schedule)
  end

  function self.apply_stops(train_id, stops, apply_opts)
    local schedule, err = create_train_schedule.build_schedule(stops, apply_opts)
    if not schedule then return false, err end
    return self.apply(train_id, schedule, apply_opts)
  end

  return self
end

return create_train_schedule
