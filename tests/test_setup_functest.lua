--[[
Purpose: scripts/setup.lua --test on a computer that has been set up: what it shows, that nothing switches without a yes, what goes into the
  record of the computer (only a complete test counts, a failure counts too), and what the master makes of it.
Public API: returns table of tests.
]]

pcall(dofile, "tests/harness/cc_bootstrap.lua")

local setup_world = require("tests.harness.setup_world")
local strict_cc = require("tests.harness.strict_cc")
local netplan = require("src.setup.netplan")
local startup_template = require("src.shared.startup_template")
local setup_status = require("src.shared.setup_status")
local pairing_module = require("src.master.pairing")
local memfs = require("tests.harness.memfs")

local PLAN = netplan.PATH

local function installed(role, entry, extra)
  local cfg = netplan.short_plan(role, entry, 777, "MASTER-1")
  local files = {
    ["startup.lua"] = startup_template.render({ role = role, id = entry.id, config = PLAN }),
    [PLAN] = netplan.encode(cfg),
  }
  for path, body in pairs(extra or {}) do files[path] = body end
  return setup_world.new({ files = files, peripherals = { setup_world.MODEM, setup_world.MONITOR } })
end

local function responder(rules)
  return function(text)
    local lines = {}
    for line in text:gmatch("[^\n]+") do lines[#lines + 1] = line end
    local tail = table.concat(lines, "\n", math.max(1, #lines - 4))
    for _, rule in ipairs(rules or {}) do
      if tail:find(rule[1], 1, true) then return rule[2] end
    end
    return ""
  end
end

local SIGNAL = { id = "SIG-1", role = "signal", adapter = "redstone", side = "left" }

local function equip(world)
  world.redstone = strict_cc.redstone()
  world.slept = {}
  world.sleep = function(seconds) world.slept[#world.slept + 1] = seconds end
end

return {
  test_the_whole_test_with_two_yes_answers_is_recorded_as_passed = function()
    local world = installed("signal", SIGNAL)
    equip(world)
    local result = world.run({ "--test" }, responder({ { "Funktionstest starten?", "j" }, { "freigegeben", "j" } }))
    assert(result.ok and result.state == "passed", tostring(result.state))
    local text = world.text()
    assert(text:find("[liest]", 1, true) and text:find("[SCHALTET]", 1, true), "what is planned is listed first")
    assert(text:find("[ OK ] Signal Redstone left", 1, true) and text:find("wieder ROT", 1, true), text)
    assert(world.redstone.outputs.left == false and world.slept[1] == 3)
    local status = setup_status.read(world.fs)
    assert(status and status.hw == "ok" and type(status.hw_at) == "number", "the record knows")
    assert(text:find("Hardwaretest bestanden", 1, true))
  end,

  test_without_the_yes_for_the_signal_nothing_is_switched_and_the_record_stays = function()
    local world = installed("signal", SIGNAL, { ["crn_status.lua"] = setup_status.render({ state = "GEPRUEFT", role = "signal", id = "SIG-1", fail = 0, warn = 0, at = 5 }) })
    equip(world)
    local result = world.run({ "--test" }, responder({ { "Funktionstest starten?", "j" }, { "freigegeben", "n" } }))
    assert(result.ok and result.state == "incomplete", tostring(result.state))
    assert(world.redstone.outputs.left == nil, "nothing was switched")
    local status = setup_status.read(world.fs)
    assert(status.hw == nil and status.state == "GEPRUEFT", "the record is as it was")
    assert(world.text():find("Nicht alle Schritte", 1, true))
  end,

  test_enter_alone_never_switches = function()
    local world = installed("signal", SIGNAL)
    equip(world)
    world.run({ "--test" }, function() return "" end)
    -- Enter starts the test (default yes) but the question about the signal has the default no
    assert(world.redstone.outputs.left == nil)
  end,

  test_a_failed_step_is_recorded_as_failed = function()
    local world = installed("signal", { id = "SIG-1", role = "signal", adapter = "redstone", side = "oben" })
    equip(world)
    local result = world.run({ "--test" }, responder({ { "Funktionstest starten?", "j" }, { "freigegeben", "j" } }))
    assert(result.ok == false and result.state == "failed", tostring(result.state))
    assert(setup_status.read(world.fs).hw == "fail")
    assert(world.text():find("[FEHL]", 1, true) and world.text():find("fehlgeschlagen", 1, true))
  end,

  test_declining_at_the_start_does_nothing = function()
    local world = installed("signal", SIGNAL)
    equip(world)
    local result = world.run({ "--test" }, responder({ { "Funktionstest starten?", "n" } }))
    assert(result.state == "declined" and world.redstone.outputs.left == nil and #world.slept == 0)
    assert(setup_status.read(world.fs) == nil)
    -- input that ends is a no
    local ended = installed("signal", SIGNAL)
    equip(ended)
    local r = ended.run({ "--test" }, function() return nil end)
    assert(r.state == "declined" and ended.redstone.outputs.left == nil)
  end,

  test_a_computer_that_is_not_set_up_is_sent_to_the_wizard = function()
    local world = setup_world.new()
    equip(world)
    local result = world.run({ "--test" }, responder({}))
    assert(result.ok == false and result.state == "setup" and world.text():find("scripts/setup.lua", 1, true))
  end,

  test_a_switch_is_tested_with_the_same_care = function()
    local world = installed("switch", { id = "SW-1", role = "switch", adapter = "redstone", side = "back" })
    equip(world)
    local result = world.run({ "--test" }, responder({ { "Funktionstest starten?", "j" }, { "geradeaus", "j" } }))
    assert(result.ok and world.redstone.outputs.back == false)
    assert(setup_status.read(world.fs).hw == "ok")
  end,

  test_a_sensor_needs_no_question_at_all = function()
    local world = installed("sensor", { id = "SEN-1", role = "sensor", adapter = "redstone", side = "front" })
    equip(world)
    world.redstone.inputs.front = false
    local asked = false
    local result = world.run({ "--test" }, function(text)
      if text:find("[j/N]", 1, true) then asked = true end
      return ""
    end)
    assert(result.ok and not asked, "reading is not asked for")
    assert(setup_status.read(world.fs).hw == "ok")
  end,

  -- what the master makes of it ------------------------------------------------------------------------------------------

  test_the_master_keeps_the_result_of_the_function_test_of_a_computer_of_the_plan = function()
    local fs = memfs.new()
    local cfg = { v = 1, channel = 1, master_id = "M", nodes = { { id = "M", role = "master" }, { id = "SIG-1", role = "signal" } }, blocks = {}, routes = {} }
    fs.set(PLAN, netplan.encode(cfg))
    local pairing = pairing_module.new({ config = cfg, plan_path = PLAN, fs = fs })
    assert(pairing.announce("SIG-1", { role = "signal", setup = { state = "GEPRUEFT", hw = "ok" } }) == "known")
    assert(pairing.setup_of("SIG-1").hw == "ok")
    pairing.announce("SIG-1", { role = "signal", setup = { state = "GEPRUEFT", hw = "bestens" } })
    assert(pairing.setup_of("SIG-1").hw == nil, "a word of the master's vocabulary only")
    -- a damaged record is not believed field by field
    assert(setup_status.parse(setup_status.render({ state = "GEPRUEFT", hw = "ok" })) ~= nil)
    assert(setup_status.parse('return { state = "GEPRUEFT", hw = "bestens" }') == nil)
    assert(setup_status.parse('return { state = "GEPRUEFT", hw = "ok", hw_at = -1 }') == nil)
  end,
}
