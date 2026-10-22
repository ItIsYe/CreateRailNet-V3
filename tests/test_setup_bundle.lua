--[[
Purpose: The setup tools (wizard, doctor, key tool, planner ...) are on a computer only while it is set up or a tool runs: a computer holds a fixed 1 000 000 bytes. The installer brings and removes them (--setup / --slim), the stubs scripts/setup.lua, keys.lua and auth_bench.lua do it by themselves.
Public API: returns table of tests.
]]

pcall(dofile, "tests/harness/cc_bootstrap.lua")

local installer_world = require("tests.harness.installer_world")
local setup_bundle = require("src.shared.setup_bundle")
local plan = dofile("install/plan.lua")
local memfs = require("tests.harness.memfs")

local function record_of(world) return plan.load_data(world.fs.files["crn_install.lua"], "record") end

local function install(world, role)
  local ok, err = world.run({ "--role", role })
  assert(ok, tostring(err) .. "\n" .. world.output())
end

local function run(world, argv)
  local ok, err = world.run(argv)
  return ok, tostring(err) .. "\n" .. world.output()
end

return {
  test_a_new_computer_gets_the_bundle_because_the_wizard_needs_it = function()
    local world = installer_world.new()
    install(world, "master")
    for _, path in ipairs({ "src/setup/wizard.lua", "src/setup/layout.lua", "scripts/setup_main.lua", "src/setup/doctor.lua" }) do assert(world.fs.files[path], path) end
    local record = record_of(world)
    assert(record.bundle == true)
    local listed = {}
    for _, path in ipairs(record.bundle_files) do listed[path] = true end
    assert(listed["src/setup/wizard.lua"] and not listed["src/master/dispatcher.lua"])
  end,

  test_slim_removes_the_bundle_and_nothing_else_and_does_not_restart = function()
    local world = installer_world.new()
    install(world, "master")
    world.fs.set("startup.lua", require("src.shared.startup_template").render({ role = "master", id = "MASTER-1", config = "configs/templates/network.full.example.json" }))
    local before = world.requests_for("src/master/dispatcher.lua")
    local runtime_before = world.fs.files["src/master/dispatcher.lua"]
    world.shell_runs = {}
    local ok, why = run(world, { "--slim", "--yes" })
    assert(ok, why)
    for _, path in ipairs({ "src/setup/wizard.lua", "src/setup/layout.lua", "scripts/setup_main.lua", "src/setup/doctor.lua", "src/setup/keys_tool.lua" }) do assert(world.fs.files[path] == nil, path .. " is still there") end
    assert(world.fs.files["src/master/dispatcher.lua"] == runtime_before and world.fs.files["scripts/setup.lua"], "the running files stay")
    assert(world.requests_for("src/master/dispatcher.lua") == before, "nothing of the running files was downloaded again")
    assert(world.rebooted == 0 and #world.shell_runs == 0, "no restart, no wizard")
    local record = record_of(world)
    assert(record.bundle == false and #record.bundle_files == 0)
  end,

  test_setup_brings_the_bundle_back_without_touching_the_running_files = function()
    local world = installer_world.new()
    install(world, "signal")
    world.fs.set("startup.lua", require("src.shared.startup_template").render({ role = "signal", id = "SIG-1", config = "configs/templates/network.full.example.json" }))
    assert(run(world, { "--slim", "--yes" }))
    local net = world.fs.files["src/shared/net.lua"]
    local ops = world.fs.ops
    local ok, why = run(world, { "--setup", "--yes" })
    assert(ok, why)
    assert(world.fs.files["src/setup/wizard.lua"] and world.fs.files["scripts/setup_main.lua"])
    assert(world.fs.files["src/setup/layout.lua"] == nil, "the planner belongs to the master only")
    assert(world.fs.files["src/shared/net.lua"] == net and world.rebooted == 0)
    assert(record_of(world).bundle == true and world.fs.ops > ops)
  end,

  test_an_update_keeps_a_computer_slim_or_fat_as_it_was = function()
    local world = installer_world.new()
    install(world, "signal")
    world.fs.set("startup.lua", require("src.shared.startup_template").render({ role = "signal", id = "SIG-1", config = "configs/templates/network.full.example.json" }))
    local net = world.fs.files["src/shared/net.lua"]
    -- fat: the bundle is updated with the rest
    world.set_version({ ["src/shared/net.lua"] = "local v2 = true\n" .. require("src.tools.manifest_builder").shipped("src/shared/net.lua", io.open("src/shared/net.lua"):read("*a")) })
    assert(run(world, { "--yes" }))
    assert(world.fs.files["src/shared/net.lua"] ~= net and world.fs.files["src/setup/wizard.lua"])
    -- slim: an update does not bring it back
    assert(run(world, { "--slim", "--yes" }))
    world.set_version({ ["src/shared/net.lua"] = "local v3 = true\n" .. io.open("src/shared/net.lua"):read("*a") })
    assert(run(world, { "--yes" }))
    assert(world.fs.files["src/setup/wizard.lua"] == nil and record_of(world).bundle == false)
  end,

  test_a_bundle_of_another_state_than_the_installed_one_is_refused = function()
    local world = installer_world.new()
    install(world, "signal")
    assert(run(world, { "--slim", "--yes" }))
    world.set_version({ ["src/shared/net.lua"] = "local other = true\n" .. io.open("src/shared/net.lua"):read("*a") })
    local ok, why = run(world, { "--setup", "--yes" })
    assert(not ok and why:find("nicht der installierte", 1, true), why)
    assert(world.fs.files["src/setup/wizard.lua"] == nil)
  end,

  test_setup_and_slim_need_an_installed_computer_and_do_not_combine = function()
    local world = installer_world.new()
    local ok, why = run(world, { "--slim", "--yes" })
    assert(not ok and why:find("noch nicht installiert", 1, true), why)
    local ok2, why2 = run(world, { "--setup", "--slim" })
    assert(not ok2 and why2:find("gehen weder zusammen", 1, true), why2)
    local ok3, why3 = run(world, { "--setup", "--resume" })
    assert(not ok3 and why3:find("gehen weder zusammen", 1, true), why3)
  end,

  test_an_interrupted_update_of_a_slim_computer_resumes_slim = function()
    local world = installer_world.new()
    install(world, "signal")
    world.fs.set("startup.lua", require("src.shared.startup_template").render({ role = "signal", id = "SIG-1", config = "configs/templates/network.full.example.json" }))
    assert(run(world, { "--slim", "--yes" }))
    world.set_version({ ["src/shared/net.lua"] = "local v2 = true\n" .. io.open("src/shared/net.lua"):read("*a") })
    world.fail_next("src/shared/net.lua", 1000, "error")
    local ok = run(world, { "--yes" })
    assert(not ok and world.fs.files["crn_install_journal.lua"]:find("bundle = false", 1, true))
    world.failures = {}
    local resumed, why = run(world, { "--resume" })
    assert(resumed, why)
    assert(world.fs.files["src/setup/wizard.lua"] == nil, "still slim after the resume")
  end,

  -- the stubs -----------------------------------------------------------------------------------------------------------------

  test_the_stub_fetches_the_bundle_runs_the_tool_and_removes_the_bundle = function()
    local fs = memfs.new()
    fs.set("installer", "--[[ installer ]]")
    fs.set("crn_install.lua", 'return {\n  role = "master",\n  ref = "v1.2.0",\n  id = "abc",\n}\n')
    local calls = {}
    local shell = { run = function(...)
      local list = { ... }
      calls[#calls + 1] = table.concat(list, " ")
      if list[1] == "installer" and list[2] == "--setup" then fs.set("src/setup/wizard.lua", "x") end
      if list[1] == "installer" and list[2] == "--slim" then fs.delete("src/setup/wizard.lua") end
      return true
    end }
    local ok, err = setup_bundle.run("scripts/setup_main.lua", { "--layout", "plan.txt" }, { fs = fs, shell = shell, say = function() end })
    assert(ok, tostring(err))
    assert(calls[1] == "installer --setup --yes --ref v1.2.0", calls[1])
    assert(calls[2] == "scripts/setup_main.lua --layout plan.txt", calls[2])
    assert(calls[3] == "installer --slim --yes --ref v1.2.0", calls[3])
    assert(not setup_bundle.present(fs))
  end,

  test_a_bundle_that_is_there_is_not_fetched_again_and_a_failing_tool_still_slims = function()
    local fs = memfs.new()
    fs.set("installer", "x")
    fs.set("src/setup/wizard.lua", "x")
    local calls = {}
    local shell = { run = function(...)
      local list = { ... }
      calls[#calls + 1] = list[1] .. " " .. tostring(list[2])
      return list[1] ~= "scripts/keys_main.lua"
    end }
    local ok, err = setup_bundle.run("scripts/keys_main.lua", {}, { fs = fs, shell = shell, say = function() end })
    assert(not ok and err == "failed")
    assert(calls[1] == "scripts/keys_main.lua nil" and calls[2] == "installer --slim" and #calls == 2, table.concat(calls, "|"))
  end,

  test_without_the_installer_nothing_is_fetched_and_the_message_says_what_to_do = function()
    local fs = memfs.new()
    local shell = { run = function() error("must not run") end }
    local ok, err = setup_bundle.run("scripts/setup_main.lua", {}, { fs = fs, shell = shell, say = function() end })
    assert(not ok and err:find("Installer liegt nicht", 1, true) and err:find("wget run", 1, true), tostring(err))
  end,

  test_a_failed_fetch_is_reported_and_the_tool_does_not_run = function()
    local fs = memfs.new()
    fs.set("installer", "x")
    local ran = {}
    local shell = { run = function(...) ran[#ran + 1] = (...); return false end }
    local ok, err = setup_bundle.run("scripts/setup_main.lua", {}, { fs = fs, shell = shell, say = function() end })
    assert(not ok and err:find("nicht geladen werden", 1, true), tostring(err))
    assert(#ran == 1 and ran[1] == "installer")
  end,

  test_slim_without_a_bundle_does_nothing = function()
    local fs = memfs.new()
    local shell = { run = function() error("must not run") end }
    assert(setup_bundle.slim({ fs = fs, shell = shell }))
  end,

  test_the_ref_comes_from_the_installation_record = function()
    local fs = memfs.new()
    assert(setup_bundle.recorded_ref(fs) == nil)
    fs.set("crn_install.lua", 'return {\n  role = "x",\n  ref = "main",\n}\n')
    assert(setup_bundle.recorded_ref(fs) == "main")
  end,
}
