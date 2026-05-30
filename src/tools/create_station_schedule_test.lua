--[[
Purpose: Safely test Create Train Station schedule application with explicit confirmation.
Public API: build_test_schedule(destination, dwell_seconds), inspect_station(name), run(args).
]]

local create_train_schedule = require("src.adapter.create_train_schedule")

local tool = {}

local function safe_call(fn)
  local ok, result = pcall(fn)
  if ok then return true, result end
  return false, tostring(result)
end

local function wrap(name)
  if not peripheral or not peripheral.wrap then return nil, "peripheral API unavailable" end
  local obj = peripheral.wrap(name)
  if not obj then return nil, "station peripheral not found: " .. tostring(name) end
  return obj
end

function tool.build_test_schedule(destination, dwell_seconds)
  return create_train_schedule.build_schedule({ { station_name = destination, dwell_seconds = dwell_seconds or 5 } }, { cyclic = false })
end

function tool.inspect_station(name)
  local station, err = wrap(name)
  if not station then return nil, err end
  local info = { name = name, methods = {}, present = nil, station_name = nil, train_name = nil, has_schedule = nil, errors = {} }
  if peripheral.getMethods then
    local ok, methods = safe_call(function() return peripheral.getMethods(name) end)
    if ok and type(methods) == "table" then info.methods = methods else table.insert(info.errors, "getMethods: " .. tostring(methods)) end
  end
  if type(station.getStationName) == "function" then
    local ok, value = safe_call(function() return station.getStationName() end)
    if ok then info.station_name = value else table.insert(info.errors, "getStationName: " .. tostring(value)) end
  end
  if type(station.isTrainPresent) == "function" then
    local ok, value = safe_call(function() return station.isTrainPresent() end)
    if ok then info.present = value else table.insert(info.errors, "isTrainPresent: " .. tostring(value)) end
  end
  if info.present and type(station.getTrainName) == "function" then
    local ok, value = safe_call(function() return station.getTrainName() end)
    if ok then info.train_name = value else table.insert(info.errors, "getTrainName: " .. tostring(value)) end
  end
  if info.present and type(station.hasSchedule) == "function" then
    local ok, value = safe_call(function() return station.hasSchedule() end)
    if ok then info.has_schedule = value else table.insert(info.errors, "hasSchedule: " .. tostring(value)) end
  end
  return info
end

function tool.apply_test_schedule(name, destination, dwell_seconds, confirm)
  if confirm ~= true then return false, "refusing to apply schedule without confirm=true" end
  local station, err = wrap(name)
  if not station then return false, err end
  if type(station.isTrainPresent) ~= "function" then return false, "station missing isTrainPresent" end
  local ok_present, present = safe_call(function() return station.isTrainPresent() end)
  if not ok_present then return false, tostring(present) end
  if not present then return false, "no train present at station" end
  if type(station.setSchedule) ~= "function" then return false, "station missing setSchedule" end
  local schedule, build_err = tool.build_test_schedule(destination, dwell_seconds)
  if not schedule then return false, build_err end
  local ok, apply_err = safe_call(function() return station.setSchedule(schedule) end)
  if not ok then return false, tostring(apply_err) end
  return true, schedule
end

function tool.run(args)
  local options = args or {}
  local station = options.station or options[1] or "Create_Station_0"
  local destination = options.destination or options[2] or "ST-B"
  local dwell = tonumber(options.dwell_seconds or options[3] or 5) or 5
  local confirm = options.confirm == true or options[4] == "confirm"

  print("CreateRailNet Create Station Schedule Test")
  print("station=" .. tostring(station) .. " destination=" .. tostring(destination) .. " dwell=" .. tostring(dwell))
  local info, err = tool.inspect_station(station)
  if not info then print("inspect failed: " .. tostring(err)); return false, err end
  print("station_name=" .. tostring(info.station_name))
  print("train_present=" .. tostring(info.present))
  print("train_name=" .. tostring(info.train_name))
  print("has_schedule=" .. tostring(info.has_schedule))
  if #info.errors > 0 then for _, e in ipairs(info.errors) do print("warn: " .. tostring(e)) end end

  if not confirm then
    print("No schedule was applied. To apply, call with confirm=true or fourth arg 'confirm'.")
    return true, info
  end

  local ok, result = tool.apply_test_schedule(station, destination, dwell, true)
  print(ok and "schedule applied" or ("schedule failed: " .. tostring(result)))
  return ok, result
end

local raw = {...}
if raw and #raw > 0 then tool.run(raw) end

return tool
