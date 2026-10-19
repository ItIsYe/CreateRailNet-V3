--[[
Purpose: The diagnostic file (scripts/setup.lua --export -> crn_diag.txt): what it holds, that it stays small and ASCII whatever the computer
  has attached or the plan says, that it works on a computer that is not set up at all, and that it reads and changes nothing else.
Public API: returns table of tests.
]]

pcall(dofile, "tests/harness/cc_bootstrap.lua")

local export = require("src.setup.export")
local netplan = require("src.setup.netplan")
local setup_world = require("tests.harness.setup_world")
local startup_template = require("src.shared.startup_template")
local setup_status = require("src.shared.setup_status")

local PLAN = netplan.PATH
local SIGNAL = { id = "SIG-1", role = "signal", adapter = "redstone", side = "left" }

local function installed(role, entry, opts)
  local cfg = netplan.short_plan(role, entry, 777, "MASTER-1")
  local files = {
    ["startup.lua"] = startup_template.render({ role = role, id = entry.id, config = PLAN }),
    [PLAN] = netplan.encode(cfg),
  }
  local o = opts or {}
  o.files = files
  return setup_world.new(o)
end

local function snapshot(world)
  local copy = {}
  for path, body in pairs(world.fs.files) do copy[path] = body end
  return copy
end

local function ascii_only(text)
  return not text:find("[^\n\32-\126]")
end

return {
  test_the_file_holds_what_a_person_who_is_not_there_needs = function()
    local world = installed("signal", SIGNAL)
    local result = world.run({ "--export" }, {})
    assert(result.ok and result.path == "crn_diag.txt")
    local text = world.fs.files["crn_diag.txt"]
    assert(text, "the file is there")
    for _, expected in ipairs({
      "CreateRailNet Diagnose", "Computer: Nr 12, Name Signal West", "CC: ComputerCraft 1.115.1 (Minecraft 1.20.1)", "Version: main-test0000",
      "Rolle: signal  ID: SIG-1  Plan: configs/network.json", "Pruefung:", "[ OK ] ", "Plan: Kanal 777, Master MASTER-1",
      "Eintrag dieses Computers:", "  side: left", "  adapter: redstone", "Geraete (2):", "  top  modem  modem", "  monitor_0  monitor  monitor",
      "Dateien:", "  crn_version.txt  13 Byte", "  startup.lua.prev  fehlt", "Freier Platz:", "Pruefprotokoll: keins",
    }) do
      assert(text:find(expected, 1, true), "missing: " .. expected .. "\n" .. text)
    end
    assert(text:find("erzeugt: 2023-11-14", 1, true), "the time is there")
    assert(ascii_only(text) and #text <= export.MAX_BYTES)
    assert(world.text():find("Geschrieben: crn_diag.txt", 1, true) and world.text():find("pastebin put crn_diag.txt", 1, true))
    assert(world.check_screen(true) == nil, tostring(world.check_screen(true)))
  end,

  test_what_the_doctor_found_is_in_it_with_the_hint_what_to_do = function()
    local world = installed("signal", SIGNAL, { peripherals = {} })
    world.run({ "--export" }, {})
    local text = world.fs.files["crn_diag.txt"]
    assert(text:find("[FEHL] ", 1, true) and text:find("Abhilfe: ", 1, true), text)
    assert(text:find("Geraete (0):", 1, true))
  end,

  test_the_record_of_the_setup_and_the_function_test_is_in_it = function()
    local world = installed("signal", SIGNAL)
    world.fs.set("crn_status.lua", setup_status.render({ state = "GEPRUEFT", role = "signal", id = "SIG-1", fail = 0, warn = 1, version = "main-abc", at = 5, hw = "ok", hw_at = 6 }))
    world.run({ "--export" }, {})
    local text = world.fs.files["crn_diag.txt"]
    assert(text:find("Pruefprotokoll: GEPRUEFT, Fehler 0, Hinweise 1, Funktionstest ok, Stand main-abc", 1, true), text)
  end,

  test_it_stays_small_whatever_is_attached = function()
    local peripherals = {}
    for index = 1, 40 do
      local methods = {}
      for method = 1, 200 do methods[#methods + 1] = "a_rather_long_method_name_" .. method end
      peripherals[#peripherals + 1] = { name = "device_" .. index, type = "thing", methods = methods }
    end
    local world = installed("signal", SIGNAL, { peripherals = peripherals })
    world.run({ "--export" }, {})
    local text = world.fs.files["crn_diag.txt"]
    assert(#text <= export.MAX_BYTES, #text)
    assert(text:find("a_rather_long_method_name_1,", 1, true) and not text:find("a_rather_long_method_name_4,", 1, true), "the method lists were shortened to make it fit")
    assert(text:find("device_1  thing", 1, true) and text:find("device_40  thing", 1, true), "every device is still named")
    assert(text:find("Freier Platz:", 1, true), "the end is still there")
    -- absurdly many devices: cut with a mark, never above the limit
    local many = {}
    for index = 1, 1500 do many[#many + 1] = { name = "peripheral_with_a_long_name_" .. index, type = "some_type", methods = {} } end
    local big = installed("signal", SIGNAL, { peripherals = many })
    big.run({ "--export" }, {})
    local cut = big.fs.files["crn_diag.txt"]
    assert(#cut <= export.MAX_BYTES and cut:find("[gekuerzt]", 1, true), #cut)
  end,

  test_nothing_in_it_is_other_than_ascii = function()
    local entry = { id = "SIG-1", role = "signal", adapter = "redstone", side = "left", display_name = "Bahnhof S\195\188d\n\0\1" }
    local world = installed("signal", entry, { peripherals = { { name = "top", type = "mod\195\169m", methods = { "o\195\182ffnen" } } } })
    world.label = "Stellwerk \195\156berlin"
    world.run({ "--export" }, {})
    local text = world.fs.files["crn_diag.txt"]
    assert(ascii_only(text), "no byte above 126 and no control character")
  end,

  test_a_computer_that_is_not_set_up_gets_a_file_too = function()
    local world = setup_world.new({ version = false, peripherals = {} })
    local result = world.run({ "--export" }, {})
    assert(result.ok)
    local text = world.fs.files["crn_diag.txt"]
    assert(text:find("Version: keine", 1, true) and text:find("Rolle: ?  ID: ?", 1, true) and text:find("Plan: nicht lesbar", 1, true), text)
  end,

  test_it_changes_nothing_but_its_own_file_and_asks_nobody = function()
    local world = installed("signal", SIGNAL)
    local asked = 0
    world.link = function() asked = asked + 1; return { state = "known" } end
    world.fetch = function() asked = asked + 1; return { ok = false } end
    local before = snapshot(world)
    world.run({ "--export" }, {})
    local after = snapshot(world)
    for path, body in pairs(after) do
      if path ~= "crn_diag.txt" then assert(before[path] == body, "changed: " .. path) end
    end
    for path in pairs(before) do assert(after[path] ~= nil, "gone: " .. path) end
    assert(asked == 0, "the master is not asked")
    assert(after["crn_diag.txt.tmp"] == nil and after["crn_diag.txt.prev"] == nil, "no leftovers")
  end,

  test_a_second_run_replaces_the_file = function()
    local world = installed("signal", SIGNAL)
    world.run({ "--export" }, {})
    local first = world.fs.files["crn_diag.txt"]
    world.epoch_ms = world.epoch_ms + 3600 * 1000
    world.run({ "--export" }, {})
    assert(world.fs.files["crn_diag.txt"] ~= first and world.fs.files["crn_diag.txt.prev"] == nil)
  end,

  test_a_file_that_cannot_be_written_is_told_and_nothing_is_raised = function()
    local world = installed("signal", SIGNAL)
    local open = world.fs.open
    world.fs.open = function(path, mode)
      if mode ~= "r" and tostring(path):find("crn_diag", 1, true) then return nil end
      return open(path, mode)
    end
    local result = world.run({ "--export" }, {})
    assert(result.ok == false and world.text():gsub("%s+", " "):find("konnte nicht geschrieben werden", 1, true), world.text())
  end,

  test_it_is_a_mode_of_the_script = function()
    local wizard = require("src.setup.wizard")
    assert(wizard.parse_args({ "--export" }).export == true and wizard.parse_args({ "--doctor" }).export == nil)
  end,
}
