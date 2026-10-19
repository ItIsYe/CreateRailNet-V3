--[[
Purpose: The guided function test of one computer (scripts/setup.lua --test): does the hardware in the plan do what the plan says? What can be
  read is read; what switches something (a signal, a turnout) is asked for one action at a time, and the safe state is restored afterwards
  (a signal ends RED, a turnout ends STRAIGHT). Nothing happens without a yes, and installing, reading or pairing never starts it.
Public API:
  steps(ctx, o) -> list of { id, title, kind = "read" | "show" | "act", ask (act: what will happen), run() -> ok, detail }
    ctx: what the doctor found out (role, id, cfg, entry, config)
    o: peripheral (CC api), redstone (CC api, default the global), sleep(seconds), confirm(question, default) -> boolean,
       link(opts) -> { state } (src/setup/link.lua; optional), hold_s (3: how long a signal stays released), watch_s (6: how long a detector is watched)
  run(ctx, o) -> { results = list of { id, title, kind, state = "ok" | "fail" | "skipped", detail }, ok, done, failed, skipped }
    a step of kind "act" asks first (confirm(ask, false)); "no" skips it. ok = nothing failed (a skipped step is not a failure, the test is just not complete)
Notes: the calls are those the node makes in operation (src/adapter/create_signals.lua, create_switches.lua, create_sensors.lua), so what passes
  here is what the node will do. The restore of a signal / turnout runs even when the step before it failed, and once more when the first
  attempt did not take; if the safe state cannot be restored the step says so loudly. A step never raises: whatever goes wrong is its result.
  Ctrl+T during the wait is honoured after the restore.
]]

local cc_modem = require("src.adapter.cc_modem")
local create_signals = require("src.adapter.create_signals")
local create_switches = require("src.adapter.create_switches")
local create_sensors = require("src.adapter.create_sensors")
local hardware = require("src.setup.hardware")
local hardware_config = require("src.adapter.hardware_config")
local monitors = require("src.adapter.monitors")
local peripherals_module = require("src.adapter.peripherals")
local redstone_module = require("src.adapter.redstone")

local functest = {}

local function text_of(value) return tostring(value):sub(1, 120) end

-- a call of an adapter (they answer true, or false and a reason); never raises
local function attempt(fn, ...)
  local called, ok, err = pcall(fn, ...)
  if not called then return false, ok end
  return ok and true or false, err
end

local MONITOR_ROLES = { master = true, panel = true, station = true, depot = true, train = true }

function functest.steps(ctx, o)
  local opts = o or {}
  local list = {}
  local peri = peripherals_module.new(opts.peripheral)
  local hw = hardware_config.new(ctx.cfg)
  local rs = redstone_module.new(opts.redstone)
  local sleep = opts.sleep or function() end
  local hold_s = opts.hold_s or 3
  local entry = ctx.entry or {}
  local id = ctx.id

  local function add(step) list[#list + 1] = step end

  -- the modem: present, and the channel of the plan can be opened
  add({ id = "modem", title = "Modem", kind = "read", run = function()
    local modem = cc_modem.new({ channel = ctx.cfg.channel, modem_name = entry.modem, peripheral_api = opts.peripheral })
    if not modem.modem then return false, "kein Modem gefunden" end
    local opened, err = modem:open(ctx.cfg.channel)
    if opened == false then return false, text_of(err) end
    return true, "Kanal " .. tostring(ctx.cfg.channel) .. " geoeffnet" .. (entry.modem and (" (" .. entry.modem .. ")") or "")
  end })

  -- the master: only asked, nothing is registered by it
  if opts.link and ctx.role ~= "master" then
    add({ id = "master", title = "Master", kind = "read", run = function()
      local result = opts.link({ channel = ctx.cfg.channel, master_id = ctx.cfg.master_id, id = id, role = ctx.role, entry = ctx.entry,
        setup = { state = "KONFIGURIERT" }, modem_name = entry.modem, peripheral = opts.peripheral })
      local state = type(result) == "table" and result.state or "no_answer"
      if state == "known" then return true, "antwortet und kennt " .. tostring(id) end
      if state == "pending" then return true, "antwortet; " .. tostring(id) .. " wartet am Master auf Annahme" end
      if state == "old_master" then return true, "antwortet (aelterer Stand)" end
      if state == "conflict" then return false, "die ID " .. tostring(id) .. " steht dort mit anderer Rolle" end
      if state == "rejected" then return false, "der Master hat " .. tostring(id) .. " abgelehnt" end
      return false, "keine Antwort"
    end })
  end

  -- the monitor: it shows a line, and the player says whether it is there
  if MONITOR_ROLES[ctx.role] and (entry.monitor ~= nil or monitors.resolve(peri, nil) ~= nil) then
    add({ id = "monitor", title = "Monitor", kind = "show", run = function()
      local monitor, note = monitors.resolve(peri, entry.monitor)
      if not monitor then return false, text_of(note or "kein Monitor gefunden") end
      pcall(monitor.clear)
      pcall(monitor.setCursorPos, 1, 1)
      local written = pcall(monitor.write, "CreateRailNet Funktionstest")
      if not written then return false, "der Monitor nimmt keinen Text an" end
      if opts.confirm and opts.confirm("Steht 'CreateRailNet Funktionstest' oben auf dem Monitor?", true) ~= true then return false, "Text nicht zu sehen" end
      return true, "Text angezeigt"
    end })
  end

  if ctx.role == "sensor" then
    local adapter = create_sensors.new(peri, { hardware = hw, redstone = rs })
    add({ id = "sensor", title = "Melder", kind = "read", run = function()
      local seen, changed, last = {}, false, nil
      local rounds = math.max(1, math.floor((opts.watch_s or 6) / 0.5))
      for _ = 1, rounds do
        local called, ok, occupied = pcall(adapter.readOccupied, id)
        if not called then return false, "nicht lesbar: " .. text_of(ok) end
        if not ok then return false, "nicht lesbar: " .. text_of(occupied) end
        if last ~= nil and occupied ~= last then changed = true end
        last = occupied
        seen[#seen + 1] = occupied and "belegt" or "frei"
        pcall(sleep, 0.5)
      end
      return true, "lesbar, zuletzt " .. seen[#seen] .. (changed and ", der Wert hat gewechselt" or ", Wert blieb gleich (ein Zug darueber wuerde ihn wechseln)")
    end })
  end

  if ctx.role == "signal" then
    local adapter = create_signals.new(peri, { hardware = hw, redstone = rs })
    local device = hw.adapter(id) == "redstone" and ("Redstone " .. tostring(hw.side(id))) or tostring(hw.target(id))
    add({ id = "signal", title = "Signal " .. device, kind = "act",
      ask = "Das Signal (" .. device .. ") wird " .. hold_s .. " Sekunden freigegeben (nicht mehr erzwungen rot) und danach wieder auf ROT gestellt. Es darf dabei kein Zug in der Naehe sein.",
      run = function()
        local released, release_err = attempt(adapter.setAspect, id, "GREEN")
        local slept, sleep_err = pcall(sleep, hold_s)
        -- the safe state comes back whatever happened before
        local red = attempt(adapter.setAspect, id, "RED")
        if not red then red = attempt(adapter.setAspect, id, "RED") end
        if not slept then error(sleep_err, 0) end
        if not red then return false, "ACHTUNG: das Signal liess sich NICHT auf ROT zurueckstellen -- von Hand pruefen" end
        if not released then return false, "liess sich nicht freigeben: " .. text_of(release_err) end
        return true, "freigegeben und wieder ROT"
      end })
  end

  if ctx.role == "switch" then
    local adapter = create_switches.new(peri, { hardware = hw, redstone = rs })
    local device = hw.adapter(id) == "redstone" and ("Redstone " .. tostring(hw.side(id))) or tostring(hw.target(id))
    add({ id = "switch", title = "Weiche " .. device, kind = "act",
      ask = "Die Weiche (" .. device .. ") wird " .. hold_s .. " Sekunden auf Abzweig gestellt und danach auf geradeaus. Es darf dabei kein Zug in der Naehe sein.",
      run = function()
        local moved, move_err = attempt(adapter.setPosition, id, "DIVERGING")
        local slept, sleep_err = pcall(sleep, hold_s)
        local back = attempt(adapter.setPosition, id, "STRAIGHT")
        if not back then back = attempt(adapter.setPosition, id, "STRAIGHT") end
        if not slept then error(sleep_err, 0) end
        if not back then return false, "ACHTUNG: die Weiche liess sich NICHT auf geradeaus zurueckstellen -- von Hand pruefen" end
        if not moved then return false, "liess sich nicht stellen: " .. text_of(move_err) end
        return true, "auf Abzweig gestellt und wieder geradeaus"
      end })
  end

  if ctx.role == "station" or ctx.role == "train" then
    add({ id = "create_station", title = "Create-Bahnhof", kind = "read", run = function()
      local name = ctx.role == "train" and entry.create_station or nil
      local device = name and peri.wrap(name) or nil
      if not name then
        for _, info in ipairs(hardware.of_class(hardware.scan(opts.peripheral), "create_station")) do name = info.name; device = peri.wrap(name); break end
      end
      if not device then return false, "kein Create-Bahnhof angeschlossen" end
      if type(device.getStationName) ~= "function" or type(device.isTrainPresent) ~= "function" then return false, tostring(name) .. " hat nicht die Methoden eines Bahnhofs" end
      local ok_name, station_name = pcall(device.getStationName)
      local ok_present, present = pcall(device.isTrainPresent)
      if not ok_name or not ok_present then return false, "nicht lesbar: " .. text_of(not ok_name and station_name or present) end
      if ctx.role == "station" and entry.create_station_name and station_name ~= entry.create_station_name then
        return false, "Create meldet '" .. text_of(station_name) .. "', im Plan steht '" .. text_of(entry.create_station_name) .. "'"
      end
      return true, tostring(name) .. " heisst '" .. text_of(station_name) .. "', " .. (present and "ein Zug steht da" or "kein Zug da")
    end })
  end

  return list
end

function functest.run(ctx, o)
  local opts = o or {}
  local results = { results = {}, done = 0, failed = 0, skipped = 0 }
  for _, step in ipairs(functest.steps(ctx, opts)) do
    local result = { id = step.id, title = step.title, kind = step.kind }
    if opts.on_step then pcall(opts.on_step, step, "begin") end
    local go = true
    if step.kind == "act" then
      go = opts.confirm and opts.confirm(step.ask, false) == true or false
    end
    if not go then
      result.state, result.detail = "skipped", "uebersprungen (kein Ja)"
      results.skipped = results.skipped + 1
    else
      local ok, passed, detail = pcall(step.run)
      if not ok then
        -- an error that is not a result (Ctrl+T during the wait) goes on after the restore the step has done already
        if tostring(passed) == "Terminated" then error(passed, 0) end
        result.state, result.detail = "fail", text_of(passed)
        results.failed = results.failed + 1
      elseif passed then
        result.state, result.detail = "ok", detail
        results.done = results.done + 1
      else
        result.state, result.detail = "fail", detail
        results.failed = results.failed + 1
      end
    end
    results.results[#results.results + 1] = result
    if opts.on_step then pcall(opts.on_step, step, "end", result) end
  end
  results.ok = results.failed == 0
  return results
end

return functest
