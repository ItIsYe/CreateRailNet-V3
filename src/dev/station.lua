--[[
Purpose: Zugriff auf einen Create-Bahnhof (Create_Station) mit den Eigenschaften, die gemessen wurden: ohne Zug werfen getTrainName und hasSchedule einen Fehler (kein Leerwert), canTrainReach liefert zwei Werte, setSchedule beweist nur die Uebergabe. Jede Aussage traegt ihre Herkunft; unlesbare Geraete ergeben "nicht verfuegbar", nie einen geratenen Zustand.
API: station.new(env, name) -> s; s.read() -> { available, present, imminent, enroute, train, has_schedule, assembly, errors }; s.schedule(); s.set_schedule(schedule) -> "uebernommen" | "bereits" | nil, grund; s.can_reach(ziel) -> bool, grund; s.distance(ziel); s.station_name(); s.rename_train(name)
Notes: env = { peripheral }. set_schedule prueft vorher und nachher mit dem Ist-Zustand und setzt einen Fahrplan nie blind ein zweites Mal (Konzept 13.3, 21.6): ein bereits gleicher Fahrplan wird nicht noch einmal uebergeben, weil Create den Ablauf dabei neu beginnen kann.
]]

local ser = require("core.ser")

local M = {}

function M.new(env, name)
  local s = {}

  local function call(method, ...)
    return pcall(env.peripheral.call, name, method, ...)
  end

  local function plain(text)
    return tostring(text):gsub("^.-:%d+: ", "")
  end

  function s.read()
    local state = { name = name, errors = {} }
    local ok, present = call("isTrainPresent")
    if not ok then
      state.available = false
      state.errors[#state.errors + 1] = plain(present)
      return state
    end
    state.available = true
    state.present = present == true
    local ok_i, imminent = call("isTrainImminent")
    if ok_i then state.imminent = (imminent == true) end
    local ok_e, enroute = call("isTrainEnroute")
    if ok_e then state.enroute = (enroute == true) end
    local ok_a, assembly = call("isInAssemblyMode")
    if ok_a then state.assembly = (assembly == true) end
    if state.present then
      local ok_t, train = call("getTrainName")
      if ok_t then state.train = train else state.errors[#state.errors + 1] = plain(train) end
      local ok_h, has = call("hasSchedule")
      if ok_h then state.has_schedule = has == true else state.errors[#state.errors + 1] = plain(has) end
    end
    return state
  end

  function s.station_name()
    local ok, v = call("getStationName")
    if ok then return v end
    return nil, plain(v)
  end

  function s.schedule()
    local ok, v = call("getSchedule")
    if not ok then return nil, plain(v) end
    return v
  end

  function s.set_schedule(schedule)
    local state = s.read()
    if not state.available then return nil, "Bahnhof nicht verfuegbar" end
    if not state.present then return nil, "kein Zug am Bahnhof" end
    local want = ser.encode(schedule)
    local current = s.schedule()
    if current ~= nil and ser.encode(current) == want then return "bereits" end
    local ok, err = call("setSchedule", schedule)
    if not ok then return nil, plain(err) end
    local after = s.schedule()
    if after == nil or ser.encode(after) ~= want then return nil, "uebernommen, aber der gelesene Fahrplan weicht ab" end
    return "uebernommen"
  end

  function s.can_reach(target)
    local ok, reachable, reason = call("canTrainReach", target)
    if not ok then return nil, plain(reachable) end
    return reachable == true, reason
  end

  function s.distance(target)
    local ok, distance, reason = call("distanceTo", target)
    if not ok then return nil, plain(distance) end
    return distance, reason
  end

  function s.rename_train(new_name)
    local ok, err = call("setTrainName", new_name)
    if not ok then return nil, plain(err) end
    local ok2, now = call("getTrainName")
    if ok2 and now == new_name then return true end
    return nil, "Name nicht uebernommen"
  end

  return s
end

return M
