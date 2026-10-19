--[[
Purpose: The guided function test (scripts/setup.lua --test): reading needs no question, anything that switches asks first and puts the safe
  state back (signal RED, turnout straight) -- also when the step before it failed, and once more when the first attempt did not take --;
  Ctrl+T during the wait is honoured after the restore; only a complete test counts for the record of the computer.
Public API: returns table of tests.
]]

pcall(dofile, "tests/harness/cc_bootstrap.lua")

local functest = require("src.setup.functest")
local netplan = require("src.setup.netplan")
local strict_cc = require("tests.harness.strict_cc")
local setup_world = require("tests.harness.setup_world")
local setup_status = require("src.shared.setup_status")
local startup_template = require("src.shared.startup_template")

local function ctx_for(role, entry)
  local cfg = netplan.short_plan(role, entry, 777, "MASTER-1")
  return { role = role, id = entry.id, cfg = cfg, entry = entry, config = "configs/network.json" }
end

local function create_signal(failing)
  local obj = { forced = nil, calls = {}, violations = {} }
  function obj.setForcedRed(value)
    if type(value) ~= "boolean" then obj.violations[#obj.violations + 1] = "boolean expected"; error("bad argument #1 (boolean expected)", 2) end
    obj.calls[#obj.calls + 1] = value
    if failing and failing(value, #obj.calls) then error("Too many messages", 0) end
    obj.forced = value
  end
  function obj.isForcedRed() return obj.forced == true end
  return obj
end

local function world_with(devices)
  local redstone = strict_cc.redstone()
  local list = {}
  for name, device in pairs(devices or {}) do list[name] = device end
  return { redstone = redstone, peripheral = strict_cc.peripheral(list), slept = {}, answers = {}, asked = {} }
end

local function options(w, extra)
  local o = {
    peripheral = w.peripheral, redstone = w.redstone,
    sleep = function(seconds) w.slept[#w.slept + 1] = seconds; if w.during_sleep then w.during_sleep(seconds) end end,
    confirm = function(question, default)
      w.asked[#w.asked + 1] = question
      local answer = table.remove(w.answers, 1)
      if answer == nil then return default end
      return answer
    end,
  }
  for key, value in pairs(extra or {}) do o[key] = value end
  return o
end

local function result_of(report, id)
  for _, r in ipairs(report.results) do if r.id == id then return r end end
  return nil
end

local SIGNAL_RS = { id = "SIG-1", role = "signal", adapter = "redstone", side = "left" }
local MODEM = { top = { type = "modem", methods = { "open", "close", "isOpen", "transmit" }, object = strict_cc.modem() } }

return {
  test_a_signal_is_released_for_a_moment_and_ends_red = function()
    local w = world_with(MODEM)
    w.answers = { true }
    local seen_during
    w.during_sleep = function() seen_during = w.redstone.outputs.left end
    local report = functest.run(ctx_for("signal", SIGNAL_RS), options(w))
    local step = result_of(report, "signal")
    assert(step.state == "ok" and step.detail:find("wieder ROT", 1, true), tostring(step.detail))
    assert(seen_during == true, "released while it waited")
    assert(w.redstone.outputs.left == false, "RED at the end")
    assert(w.slept[1] == 3 and #w.redstone.violations == 0)
    assert(w.asked[1]:find("Redstone left", 1, true) and w.asked[1]:find("ROT", 1, true) and w.asked[1]:find("kein Zug", 1, true), w.asked[1])
  end,

  test_without_a_yes_nothing_is_switched = function()
    local w = world_with(MODEM)
    w.answers = { false }
    local report = functest.run(ctx_for("signal", SIGNAL_RS), options(w))
    assert(result_of(report, "signal").state == "skipped")
    assert(w.redstone.outputs.left == nil, "the output was not touched at all")
    assert(#w.slept == 0 and report.skipped == 1 and report.ok == true, "skipped is not failed; the test is just not complete")
    -- the default of the question is no
    local w2 = world_with(MODEM)
    local default_seen
    local o = options(w2, { confirm = function(question, default) default_seen = default; return default end })
    functest.run(ctx_for("signal", SIGNAL_RS), o)
    assert(default_seen == false and w2.redstone.outputs.left == nil, "Enter alone does not switch")
    -- no way to ask: no switching
    local w3 = world_with(MODEM)
    functest.run(ctx_for("signal", SIGNAL_RS), options(w3, { confirm = false }))
    assert(w3.redstone.outputs.left == nil)
  end,

  test_a_create_signal_is_forced_red_again_at_the_end = function()
    local signal = create_signal()
    local devices = { top = MODEM.top, Create_Signal_0 = { type = "Create_Signal", methods = { "setForcedRed", "isForcedRed" }, object = signal } }
    local w = world_with(devices)
    w.answers = { true }
    local report = functest.run(ctx_for("signal", { id = "SIG-2", role = "signal", adapter = "peripheral", peripheral = "Create_Signal_0" }), options(w))
    assert(result_of(report, "signal").state == "ok")
    assert(signal.calls[1] == false and signal.calls[#signal.calls] == true and signal.forced == true, "released first, forced red at the end")
    assert(#signal.violations == 0)
  end,

  test_when_the_release_fails_the_signal_is_still_put_to_red = function()
    local signal = create_signal(function(value) return value == false end)
    local devices = { top = MODEM.top, Create_Signal_0 = { type = "Create_Signal", methods = { "setForcedRed", "isForcedRed" }, object = signal } }
    local w = world_with(devices)
    w.answers = { true }
    local report = functest.run(ctx_for("signal", { id = "SIG-2", role = "signal", adapter = "peripheral", peripheral = "Create_Signal_0" }), options(w))
    local step = result_of(report, "signal")
    assert(step.state == "fail" and step.detail:find("liess sich nicht freigeben", 1, true), tostring(step.detail))
    assert(signal.forced == true and signal.calls[#signal.calls] == true, "red again")
    assert(not report.ok)
  end,

  test_a_signal_that_cannot_be_put_back_to_red_is_said_loudly_after_a_second_try = function()
    local signal = create_signal(function(value) return value == true end)
    local devices = { top = MODEM.top, Create_Signal_0 = { type = "Create_Signal", methods = { "setForcedRed", "isForcedRed" }, object = signal } }
    local w = world_with(devices)
    w.answers = { true }
    local report = functest.run(ctx_for("signal", { id = "SIG-2", role = "signal", adapter = "peripheral", peripheral = "Create_Signal_0" }), options(w))
    local step = result_of(report, "signal")
    assert(step.state == "fail" and step.detail:find("ACHTUNG", 1, true) and step.detail:find("NICHT auf ROT", 1, true), tostring(step.detail))
    local red_tries = 0
    for _, v in ipairs(signal.calls) do if v == true then red_tries = red_tries + 1 end end
    assert(red_tries == 2, "the second try: " .. red_tries)
  end,

  test_ctrl_t_during_the_wait_puts_the_signal_back_and_then_goes_on_terminating = function()
    local w = world_with(MODEM)
    w.answers = { true }
    w.during_sleep = function() error("Terminated", 0) end
    local ok, err = pcall(functest.run, ctx_for("signal", SIGNAL_RS), options(w))
    assert(ok == false and tostring(err):find("Terminated", 1, true), tostring(err))
    assert(w.redstone.outputs.left == false, "red before it ended")
  end,

  test_a_switch_goes_to_the_branch_and_back_straight = function()
    local w = world_with(MODEM)
    w.answers = { true }
    local seen_during
    w.during_sleep = function() seen_during = w.redstone.outputs.back end
    local report = functest.run(ctx_for("switch", { id = "SW-1", role = "switch", adapter = "redstone", side = "back" }), options(w))
    local step = result_of(report, "switch")
    assert(step.state == "ok" and seen_during == true and w.redstone.outputs.back == false, tostring(step.detail))
    assert(w.asked[1]:find("geradeaus", 1, true) and w.asked[1]:find("kein Zug", 1, true))
  end,

  test_a_side_that_does_not_exist_is_a_failed_step_not_an_error = function()
    local w = world_with(MODEM)
    w.answers = { true }
    local report = functest.run(ctx_for("switch", { id = "SW-1", role = "switch", adapter = "redstone", side = "oben" }), options(w))
    local step = result_of(report, "switch")
    assert(step.state == "fail", tostring(step.detail))
    assert(step.detail:find("ACHTUNG", 1, true), "it could not be put back either, and the test says so")
  end,

  test_a_detector_that_changes_during_the_watch_is_reported_as_changed = function()
    local observer = { passing = false }
    function observer.isTrainPassing() return observer.passing end
    function observer.getPassingTrainName() return nil end
    local w = world_with({ top = MODEM.top, Create_TrainObserver_0 = { type = "Create_TrainObserver", methods = { "isTrainPassing", "getPassingTrainName" }, object = observer } })
    local count = 0
    w.during_sleep = function() count = count + 1; if count == 4 then observer.passing = true end end
    local report = functest.run(ctx_for("sensor", { id = "SEN-1", role = "sensor", adapter = "peripheral", peripheral = "Create_TrainObserver_0" }), options(w))
    local step = result_of(report, "sensor")
    assert(step.state == "ok" and step.detail:find("gewechselt", 1, true) and step.detail:find("zuletzt belegt", 1, true), tostring(step.detail))
    -- no change is fine too, and says that it cannot know more
    local quiet = world_with({ top = MODEM.top, Create_TrainObserver_0 = { type = "Create_TrainObserver", methods = { "isTrainPassing", "getPassingTrainName" }, object = { isTrainPassing = function() return false end, getPassingTrainName = function() end } } })
    local r2 = functest.run(ctx_for("sensor", { id = "SEN-1", role = "sensor", adapter = "peripheral", peripheral = "Create_TrainObserver_0" }), options(quiet))
    assert(result_of(r2, "sensor").state == "ok" and result_of(r2, "sensor").detail:find("Wert blieb gleich", 1, true))
  end,

  test_a_detector_that_cannot_be_read_fails = function()
    local w = world_with(MODEM)
    local report = functest.run(ctx_for("sensor", { id = "SEN-1", role = "sensor", adapter = "peripheral", peripheral = "Create_TrainObserver_0" }), options(w))
    assert(result_of(report, "sensor").state == "fail" and result_of(report, "sensor").detail:find("nicht lesbar", 1, true))
  end,

  test_a_redstone_detector_is_read_from_its_side = function()
    local w = world_with(MODEM)
    w.redstone.inputs.front = true
    local report = functest.run(ctx_for("sensor", { id = "SEN-2", role = "sensor", adapter = "redstone", side = "front" }), options(w))
    local step = result_of(report, "sensor")
    assert(step.state == "ok" and step.detail:find("zuletzt belegt", 1, true))
  end,

  test_the_create_station_is_compared_with_the_name_in_the_plan = function()
    local station = { getStationName = function() return "Hauptbahnhof" end, isTrainPresent = function() return true end, setSchedule = function() end }
    local devices = { top = MODEM.top, Create_Station_0 = { type = "Create_Station", methods = { "getStationName", "isTrainPresent", "setSchedule" }, object = station } }
    local w = world_with(devices)
    local good = functest.run(ctx_for("station", { id = "ST-1", role = "station", create_station_name = "Hauptbahnhof" }), options(w))
    assert(result_of(good, "create_station").state == "ok" and result_of(good, "create_station").detail:find("ein Zug steht da", 1, true))
    local bad = functest.run(ctx_for("station", { id = "ST-1", role = "station", create_station_name = "Nordbahnhof" }), options(w))
    local step = result_of(bad, "create_station")
    assert(step.state == "fail" and step.detail:find("Create meldet 'Hauptbahnhof'", 1, true) and step.detail:find("Nordbahnhof", 1, true), tostring(step.detail))
    local none = functest.run(ctx_for("station", { id = "ST-1", role = "station", create_station_name = "x" }), options(world_with(MODEM)))
    assert(result_of(none, "create_station").state == "fail")
    -- a train computer names its station in the entry
    local train = functest.run(ctx_for("train", { id = "TRAIN-1", role = "train", create_station = "Create_Station_0" }), options(w))
    assert(result_of(train, "create_station").state == "ok")
  end,

  test_the_monitor_shows_a_line_and_the_player_says_whether_it_is_there = function()
    local monitor = strict_cc.monitor(51, 19)
    local devices = { top = MODEM.top, monitor_0 = { type = "monitor", methods = { "write", "setCursorPos", "clear" }, object = monitor } }
    local w = world_with(devices)
    w.answers = { true }
    local report = functest.run(ctx_for("panel", { id = "PANEL-1", role = "panel" }), options(w))
    assert(result_of(report, "monitor").state == "ok" and monitor.text():find("CreateRailNet Funktionstest", 1, true))
    assert(#monitor.violations == 0)
    local w2 = world_with(devices)
    w2.answers = { false }
    local report2 = functest.run(ctx_for("panel", { id = "PANEL-1", role = "panel" }), options(w2))
    assert(result_of(report2, "monitor").state == "fail" and result_of(report2, "monitor").detail:find("nicht zu sehen", 1, true))
    -- a computer without any monitor has no such step
    local report3 = functest.run(ctx_for("panel", { id = "PANEL-1", role = "panel" }), options(world_with(MODEM)))
    assert(result_of(report3, "monitor") == nil)
  end,

  test_the_modem_and_the_master_are_checked = function()
    local modem = strict_cc.modem()
    local devices = { top = { type = "modem", methods = { "open", "close", "isOpen", "transmit" }, object = modem } }
    local w = world_with(devices)
    local states = { "known", "pending", "old_master", "conflict", "rejected", "no_answer" }
    local expected = { true, true, true, false, false, false }
    for i, state in ipairs(states) do
      local report = functest.run(ctx_for("sensor", { id = "SEN-1", role = "sensor", adapter = "redstone", side = "front" }), options(w, { link = function() return { state = state } end }))
      assert((result_of(report, "master").state == "ok") == expected[i], state)
    end
    assert(modem.opened[777] and result_of(functest.run(ctx_for("sensor", { id = "SEN-1", role = "sensor", adapter = "redstone", side = "front" }), options(w)), "modem").state == "ok")
    local nothing = functest.run(ctx_for("sensor", { id = "SEN-1", role = "sensor", adapter = "redstone", side = "front" }), options(world_with({})))
    assert(result_of(nothing, "modem").state == "fail" and result_of(nothing, "modem").detail:find("kein Modem", 1, true))
    local no_link = functest.run(ctx_for("sensor", { id = "SEN-1", role = "sensor", adapter = "redstone", side = "front" }), options(w))
    assert(result_of(no_link, "master") == nil, "no way to ask: no step")
    local master = functest.run(ctx_for("master", { id = "MASTER-1", role = "master" }), options(w, { link = function() error("must not ask") end }))
    assert(result_of(master, "master") == nil, "the master does not ask itself")
  end,

  test_the_steps_are_listed_without_running_anything = function()
    local w = world_with(MODEM)
    local steps = functest.steps(ctx_for("signal", SIGNAL_RS), options(w))
    local kinds = {}
    for _, step in ipairs(steps) do kinds[step.id] = step.kind end
    assert(kinds.modem == "read" and kinds.signal == "act")
    assert(w.redstone.outputs.left == nil and #w.slept == 0)
  end,

  test_a_step_that_raises_is_a_failed_step = function()
    local w = world_with({ top = MODEM.top, Create_TrainObserver_0 = { type = "Create_TrainObserver", methods = { "isTrainPassing" }, object = { isTrainPassing = function() error("peripheral detached") end } } })
    local report = functest.run(ctx_for("sensor", { id = "SEN-1", role = "sensor", adapter = "peripheral", peripheral = "Create_TrainObserver_0" }), options(w))
    assert(result_of(report, "sensor").state == "fail")
    -- an error in the question to the master is one failed step, the others still run
    local boom = functest.run(ctx_for("sensor", { id = "SEN-1", role = "sensor", adapter = "redstone", side = "front" }),
      options(world_with(MODEM), { link = function() error("something odd") end }))
    assert(result_of(boom, "master").state == "fail" and result_of(boom, "master").detail:find("something odd", 1, true))
    assert(result_of(boom, "sensor").state == "ok" and not boom.ok)
  end,
}
