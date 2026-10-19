--[[
Purpose: scripts/setup.lua --layout on the master: reads the description of a network, builds the plan, tells what comes out of it and writes the
  build list and -- only after a yes -- the plan (the old file stays as .prev). What it does to a computer that is not the master, to a file that is
  missing or wrong, and what it keeps of the old plan.
Public API: returns table of tests.
]]

pcall(dofile, "tests/harness/cc_bootstrap.lua")

local setup_world = require("tests.harness.setup_world")
local netplan = require("src.setup.netplan")
local layout = require("src.setup.layout")
local startup_template = require("src.shared.startup_template")
local setup_status = require("src.shared.setup_status")

local PLAN = netplan.PATH
local DEFAULT_FILE = "configs/layout.txt"

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

local function master_world(extra_files, entry_extra, old_nodes)
  local entry = { id = "MASTER-1", role = "master" }
  for key, value in pairs(entry_extra or {}) do entry[key] = value end
  local cfg = netplan.short_plan("master", entry, 555, "MASTER-1")
  for _, node in ipairs(old_nodes or {}) do cfg.nodes[#cfg.nodes + 1] = node end
  local files = {
    ["startup.lua"] = startup_template.render({ role = "master", id = "MASTER-1", config = PLAN }),
    [PLAN] = netplan.encode(cfg),
  }
  for path, body in pairs(extra_files or {}) do files[path] = body end
  local world = setup_world.new({ files = files })
  return world, files[PLAN]
end

local function words(world) return (world.text():gsub("%s+", " ")) end

local function plan_of(world) return assert(netplan.parse(world.fs.files[PLAN])) end

local DESCRIPTION = layout.EXAMPLE

return {
  test_the_example_description_is_a_working_network = function()
    local l, errors = layout.parse(layout.EXAMPLE)
    assert(l, table.concat(errors or {}, "\n"))
    local plan = require("src.setup.plan_builder").build(l)
    assert(plan and #plan.routes > 0)
  end,

  test_it_builds_the_plan_tells_what_comes_out_and_writes_list_and_plan_after_a_yes = function()
    local world, old_plan = master_world({ [DEFAULT_FILE] = DESCRIPTION }, { monitor = "monitor_0", monitor_scale = 0.5 })
    local result = world.run({ "--layout" }, responder({ { "Bauliste", "j" }, { "Den Plan als configs/network.json speichern?", "j" } }))
    assert(result.ok and result.state == "written" and result.wrote_plan and result.wrote_list, tostring(result.state))
    local text = words(world)
    assert(text:find("Mein erstes Netz", 1, true) and text:find("Bloecke", 1, true) and text:find("Routen", 1, true) and text:find("Computer", 1, true), text)
    local cfg = plan_of(world)
    assert(#cfg.blocks > 0 and #cfg.routes > 0 and cfg.service_plans[1].id == "SP-TRAIN-1")
    assert(world.fs.files[PLAN .. ".prev"] == old_plan, "the old plan stays as .prev")
    assert(world.fs.files["crn_bauliste.txt"]:find("CreateRailNet Bauliste: Mein erstes Netz", 1, true))
    -- this computer stays what it was: its channel, its id, its devices
    local master = netplan.find_node(cfg, "MASTER-1")
    assert(cfg.channel == 555 and cfg.master_id == "MASTER-1" and master.role == "master" and master.monitor == "monitor_0" and master.monitor_scale == 0.5)
    assert(text:find("reboot", 1, true) or text:find("neu starten", 1, true), "the master has to restart to use it")
    assert(setup_status.read(world.fs), "the record of the check was written again")
    assert(world.check_screen(true) == nil, tostring(world.check_screen(true)))
  end,

  test_enter_alone_writes_the_list_but_not_the_plan = function()
    local world, old_plan = master_world({ [DEFAULT_FILE] = DESCRIPTION })
    local result = world.run({ "--layout" }, function() return "" end)
    assert(result.ok and result.state == "declined" and result.wrote_list == true and not result.wrote_plan, tostring(result.state))
    assert(world.fs.files[PLAN] == old_plan and world.fs.files[PLAN .. ".prev"] == nil, "the plan is untouched")
    assert(world.fs.files["crn_bauliste.txt"], "the list is harmless and written by default")
    -- input that ends is a no for both
    local ended = master_world({ [DEFAULT_FILE] = DESCRIPTION })
    local r = ended.run({ "--layout" }, function() return nil end)
    assert(r.wrote_plan ~= true and ended.fs.files["crn_bauliste.txt"] == nil and ended.fs.files[PLAN] == select(2, master_world({ [DEFAULT_FILE] = DESCRIPTION })))
  end,

  test_a_missing_file_offers_an_example_and_writes_it_only_after_a_yes = function()
    local world, old_plan = master_world()
    local declined = world.run({ "--layout" }, responder({ { "Beispiel", "n" } }))
    assert(declined.ok == false and declined.state == "missing" and world.fs.files[DEFAULT_FILE] == nil and world.fs.files[PLAN] == old_plan)
    assert(words(world):find(DEFAULT_FILE, 1, true))
    local again = master_world()
    local accepted = again.run({ "--layout" }, responder({ { "Beispiel", "j" } }))
    assert(accepted.state == "example" and again.fs.files[DEFAULT_FILE] == layout.EXAMPLE, "the example is the file")
    assert(again.fs.files[PLAN] == old_plan, "and nothing else changed")
    assert(words(again):find("edit " .. DEFAULT_FILE, 1, true), "it says how to edit it")
  end,

  test_a_wrong_description_lists_every_mistake_with_its_line_and_changes_nothing = function()
    local world, old_plan = master_world({ [DEFAULT_FILE] = "bahnhof ST-A\nbahnhoff ST-B\nstrecke ST-A ST-Q\n" })
    local result = world.run({ "--layout" }, function() return "j" end)
    assert(result.ok == false and result.state == "invalid")
    local text = words(world)
    assert(text:find("Zeile 2", 1, true) and text:find("Zeile 3", 1, true) and text:find("ST-Q", 1, true), text)
    assert(world.fs.files[PLAN] == old_plan and world.fs.files["crn_bauliste.txt"] == nil)
  end,

  test_a_network_the_builder_refuses_is_told_and_changes_nothing = function()
    local lines = {}
    for i = 1, 20 do lines[#lines + 1] = string.format("bahnhof S%02d", i) end
    for i = 1, 20 do lines[#lines + 1] = string.format("strecke S%02d S%02d 12", i, (i % 20) + 1) end
    local world, old_plan = master_world({ [DEFAULT_FILE] = table.concat(lines, "\n") })
    local result = world.run({ "--layout" }, function() return "j" end)
    assert(result.ok == false and result.state == "invalid" and words(world):find("zu gross", 1, true), words(world))
    assert(world.fs.files[PLAN] == old_plan)
  end,

  test_only_the_master_builds_a_network = function()
    local cfg = netplan.short_plan("signal", { id = "SIG-1", role = "signal", adapter = "redstone", side = "left" }, 777, "MASTER-1")
    local world = setup_world.new({ files = {
      ["startup.lua"] = startup_template.render({ role = "signal", id = "SIG-1", config = PLAN }), [PLAN] = netplan.encode(cfg), [DEFAULT_FILE] = DESCRIPTION } })
    local result = world.run({ "--layout" }, function() return "j" end)
    assert(result.ok == false and result.state == "no_master" and words(world):find("Master", 1, true))
    assert(world.fs.files["crn_bauliste.txt"] == nil)
    local blank = setup_world.new()
    assert(blank.run({ "--layout" }, function() return "j" end).state == "setup")
  end,

  test_the_master_id_is_the_id_of_this_computer_and_a_different_one_is_a_mistake = function()
    local world = master_world({ [DEFAULT_FILE] = DESCRIPTION .. "\nmaster ANDERS-1\n" })
    local result = world.run({ "--layout" }, function() return "j" end)
    assert(result.state == "invalid" and words(world):find("ANDERS-1", 1, true) and words(world):find("MASTER-1", 1, true), words(world))
    -- the same id is fine
    local same = master_world({ [DEFAULT_FILE] = DESCRIPTION .. "\nmaster MASTER-1\n" })
    assert(same.run({ "--layout" }, function() return "" end).state == "declined")
  end,

  test_the_plan_is_built_for_the_id_this_master_has = function()
    local cfg = netplan.short_plan("master", { id = "ZENTRALE-1", role = "master" }, 555, "ZENTRALE-1")
    local world = setup_world.new({ files = {
      ["startup.lua"] = startup_template.render({ role = "master", id = "ZENTRALE-1", config = PLAN }), [PLAN] = netplan.encode(cfg), [DEFAULT_FILE] = DESCRIPTION } })
    local result = world.run({ "--layout" }, responder({ { "configs/network.json speichern?", "j" } }))
    assert(result.state == "written", tostring(result.state) .. words(world))
    local plan = plan_of(world)
    assert(plan.master_id == "ZENTRALE-1" and netplan.find_node(plan, "ZENTRALE-1").role == "master" and netplan.find_node(plan, "MASTER-1") == nil)
  end,

  test_a_channel_in_the_description_wins_over_the_old_one = function()
    local world = master_world({ [DEFAULT_FILE] = DESCRIPTION .. "\nkanal 4242\n" })
    world.run({ "--layout" }, responder({ { "configs/network.json speichern?", "j" } }))
    assert(plan_of(world).channel == 4242)
  end,

  test_computers_of_the_old_plan_that_the_new_one_lacks_are_named = function()
    local world = master_world({ [DEFAULT_FILE] = DESCRIPTION }, nil, { { id = "SIG-OLD-1", role = "signal", adapter = "redstone", side = "left" }, { id = "SEN-OLD-1", role = "sensor", adapter = "redstone", side = "front" } })
    world.run({ "--layout" }, responder({ { "configs/network.json speichern?", "n" } }))
    local text = words(world)
    assert(text:find("SIG-OLD-1", 1, true) and text:find("SEN-OLD-1", 1, true) and text:find("fehlen", 1, true), text)
  end,

  test_another_file_can_be_named_and_json_works_as_well = function()
    local json = '{"name": "Json-Netz", "stations": [{"id": "ST-A"}, {"id": "ST-B"}], "lines": [{"from": "ST-A", "to": "ST-B", "blocks": 1}]}'
    local world = master_world({ ["netz.json"] = json })
    local result = world.run({ "--layout", "netz.json" }, responder({ { "configs/network.json speichern?", "j" } }))
    assert(result.state == "written" and words(world):find("Json-Netz", 1, true))
    assert(#plan_of(world).blocks == 2)
  end,

  test_a_plan_that_cannot_be_written_is_said_and_the_old_one_stays = function()
    local world, old_plan = master_world({ [DEFAULT_FILE] = DESCRIPTION })
    local open = world.fs.open
    world.fs.open = function(path, mode)
      if mode ~= "r" and tostring(path):find("network.json", 1, true) then return nil end
      return open(path, mode)
    end
    local result = world.run({ "--layout" }, responder({ { "configs/network.json speichern?", "j" } }))
    assert(result.ok == false and result.state == "write" and words(world):find("nicht gespeichert", 1, true), words(world))
    assert(world.fs.files[PLAN] == old_plan)
  end,

  test_it_is_a_mode_of_the_script_and_takes_a_file_name = function()
    local wizard = require("src.setup.wizard")
    local a = wizard.parse_args({ "--layout" })
    assert(a.layout == true and a.layout_path == nil)
    local b = wizard.parse_args({ "--layout", "netz.txt" })
    assert(b.layout == true and b.layout_path == "netz.txt")
    local c = wizard.parse_args({ "--layout", "--doctor" })
    assert(c.layout == true and c.layout_path == nil and c.doctor == true)
  end,
}
