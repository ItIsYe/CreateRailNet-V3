--[[
Purpose: Fake-Welt mit Create-Geraeten nach den Messwerten (docs/MESSWERTE.md): Bahnhof (Fehler "there is no train present" ohne Zug, canTrainReach mit zwei Rueckgaben), Signal (Zwangsrot, Ereignis bei Aenderung), Beobachter, Modems, Monitor, Redstone Relay und die Computerseiten. Methoden, die es nicht gibt, werfen einen Fehler wie im Spiel.
API: world = create.world(); world.add_station(name, opts), add_signal, add_observer, add_modem(name, wireless[, hub]), add_monitor(name, w, h), add_relay(name); world.arrive(station, train, schedule), world.depart(station), world.pass(observer, train), world.passed(observer, train), world.detach(name); world.peripheral; world.redstone; world.pull() -> Ereignis
]]

local unpack = table.unpack or unpack

local M = {}

local function deepcopy(v)
  if type(v) ~= "table" then return v end
  local out = {}
  for k, x in pairs(v) do out[k] = deepcopy(x) end
  return out
end
M.deepcopy = deepcopy

function M.world()
  local w = { devices = {}, queue = {}, calls = {} }

  local function emit(name, device, arg)
    w.queue[#w.queue + 1] = { name, device, arg }
  end

  function w.pull()
    return table.remove(w.queue, 1)
  end

  local function add(name, types, methods, state)
    w.devices[name] = { name = name, types = types, methods = methods, state = state }
    return w.devices[name]
  end

  local NO_TRAIN = "there is no train present"

  function w.add_station(name, opts)
    opts = opts or {}
    local st = { station_name = opts.station_name or name, train = nil, imminent = false, enroute = false, assembly = false, ignore_set = opts.ignore_set, known = opts.known or {} }
    local m = {}
    function m.getStationName() return st.station_name end
    function m.setStationName(n) st.station_name = n end
    function m.isTrainPresent() return st.train ~= nil end
    function m.isTrainImminent() return st.imminent end
    function m.isTrainEnroute() return st.enroute end
    function m.getTrainName() if not st.train then error(NO_TRAIN, 0) end return st.train.name end
    function m.setTrainName(n) if not st.train then error(NO_TRAIN, 0) end st.train.name = n end
    function m.hasSchedule() if not st.train then error(NO_TRAIN, 0) end return st.train.schedule ~= nil end
    function m.getSchedule() if not st.train then error(NO_TRAIN, 0) end return deepcopy(st.train.schedule) end
    function m.setSchedule(s)
      if not st.train then error(NO_TRAIN, 0) end
      st.sets = (st.sets or 0) + 1
      if not st.ignore_set then st.train.schedule = deepcopy(s) end
    end
    function m.canTrainReach(target)
      if not st.train then error(NO_TRAIN, 0) end
      if st.known[target] then return true, nil end
      return false, "no-target"
    end
    function m.distanceTo(target)
      if not st.train then error(NO_TRAIN, 0) end
      if st.known[target] then return st.known[target], nil end
      return nil, "no-target"
    end
    function m.isInAssemblyMode() return st.assembly end
    function m.setAssemblyMode(v) st.assembly = v end
    function m.assemble() error("not in assembly mode", 0) end
    function m.disassemble() error("not in assembly mode", 0) end
    return add(name, { "Create_Station" }, m, st)
  end

  function w.add_signal(name, opts)
    opts = opts or {}
    local sg = { forced = false, base = "GREEN", ignore_hold = opts.ignore_hold, blocking = {} }
    local function current()
      if sg.forced then return "RED" end
      return sg.base
    end
    local m = {}
    function m.getState() return current() end
    function m.isForcedRed() return sg.forced end
    function m.setForcedRed(v)
      local before = current()
      if not sg.ignore_hold then sg.forced = v and true or false end
      if current() ~= before then emit("train_signal_state_change", name, current()) end
    end
    function m.getSignalType() return "ENTRY_SIGNAL" end
    function m.cycleSignalType() end
    function m.listBlockingTrainNames() return deepcopy(sg.blocking) end
    return add(name, { "Create_Signal" }, m, sg)
  end

  function w.set_base(name, state)
    local d = w.devices[name]
    local before = d.methods.getState()
    d.state.base = state
    if d.methods.getState() ~= before then emit("train_signal_state_change", name, d.methods.getState()) end
  end

  function w.add_observer(name)
    local ob = { passing = nil }
    local m = {}
    function m.isTrainPassing() return ob.passing ~= nil end
    function m.getPassingTrainName() return ob.passing end
    return add(name, { "Create_TrainObserver" }, m, ob)
  end

  function w.add_modem(name, wireless, hub)
    local m = {}
    function m.isWireless() return wireless end
    function m.open() end
    function m.close() end
    function m.transmit() end
    local types = hub and { "modem", "peripheral_hub" } or { "modem" }
    return add(name, types, m, {})
  end

  function w.add_monitor(name, width, height)
    local m = { size = { width, height } }
    local api = {}
    function api.getSize() return m.size[1], m.size[2] end
    function api.setCursorPos() end
    function api.write() end
    function api.clear() end
    function api.setTextColour() end
    function api.setBackgroundColour() end
    return add(name, { "monitor" }, api, m)
  end

  w.sides = { top = false, bottom = false, left = false, right = false, front = false, back = false }
  w.redstone = {
    getOutput = function(side)
      if w.sides[side] == nil then error("Invalid side.", 0) end
      return w.sides[side]
    end,
    setOutput = function(side, on)
      if w.sides[side] == nil then error("Invalid side.", 0) end
      w.sides[side] = on and true or false
    end,
  }

  function w.add_relay(name)
    local relay = { outputs = {} }
    local m = {}
    function m.getInput() return false end
    function m.setOutput(side, on) relay.outputs[side] = on and true or false end
    function m.getOutput(side) return relay.outputs[side] == true end
    return add(name, { "redstone_relay" }, m, relay)
  end

  function w.arrive(name, train, schedule)
    local st = w.devices[name].state
    st.enroute = true
    emit("train_imminent", name, train)
    st.imminent = false
    st.train = { name = train, schedule = deepcopy(schedule) }
    st.enroute = false
    emit("train_arrival", name, train)
  end

  function w.depart(name)
    local st = w.devices[name].state
    local train = st.train and st.train.name
    st.train = nil
    emit("train_departure", name, train)
  end

  function w.pass(name, train)
    w.devices[name].state.passing = train
    emit("train_passing", name, train)
  end

  function w.passed(name, train)
    w.devices[name].state.passing = nil
    emit("train_passed", name, train)
  end

  function w.detach(name)
    w.devices[name] = nil
  end

  local p = {}
  function p.getNames()
    local names = {}
    for name in pairs(w.devices) do names[#names + 1] = name end
    table.sort(names)
    return names
  end
  function p.getType(name)
    local d = w.devices[name]
    if not d then return nil end
    return unpack(d.types)
  end
  function p.getMethods(name)
    local d = w.devices[name]
    if not d then return nil end
    local names = {}
    for method in pairs(d.methods) do names[#names + 1] = method end
    table.sort(names)
    return names
  end
  function p.isPresent(name) return w.devices[name] ~= nil end
  function p.call(name, method, ...)
    local d = w.devices[name]
    if not d then error("No peripheral named '" .. tostring(name) .. "'", 0) end
    local fn = d.methods[method]
    if not fn then error("No such method " .. tostring(method), 0) end
    w.calls[#w.calls + 1] = name .. ":" .. method
    return fn(...)
  end
  w.peripheral = p

  return w
end

return M
