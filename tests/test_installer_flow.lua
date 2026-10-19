--[[
Purpose: The installer end to end on a fake computer: fresh install, update, repair, seed files, space check, bad downloads, interrupted
  installs (crash at every filesystem operation), the startup.lua guard, and that every role's installed files really load.
Public API: returns table of tests.
]]

pcall(dofile, "tests/harness/cc_bootstrap.lua")

local installer_world = require("tests.harness.installer_world")
local plan = dofile("install/plan.lua")
local startup_template = require("src.shared.startup_template")

local function read_disk(path)
  local fh = assert(io.open(path, "rb"))
  local body = fh:read("*a")
  fh:close()
  return body
end

local function manifest() return assert(plan.parse_manifest(read_disk("install/manifest.lua"))) end

local function files_of(role, m) return assert(plan.files_for_role(m or manifest(), role)) end

local function sorted(set)
  local list = {}
  for key in pairs(set) do list[#list + 1] = key end
  table.sort(list)
  return list
end

local function has_leftovers(fs)
  for path in pairs(fs.files) do
    if path:match("%.tmp$") or path:match("%.prev$") or path:match("^crn_install_journal") then return path end
  end
  return nil
end

local function install(world, role)
  local ok, err = world.run({ "--role", role })
  assert(ok, tostring(err) .. "\n" .. world.output())
end

-- the sensor node of a later version: it no longer needs create_sensors and needs a new module
local function sensor_node_v2()
  local body = read_disk("src/nodes/sensor_node.lua")
  local changed = body:gsub('local create_sensors = require%("src.adapter.create_sensors"%)', 'local extra = require("src.shared.extra_module")\nlocal create_sensors = { new = function() end }')
  assert(changed ~= body)
  return changed
end

local function startup_for(role) return startup_template.render({ role = role, id = role:upper() .. "-1", config = "configs/templates/network.full.example.json" }) end

return {
  test_fresh_install_puts_the_role_files_on_the_computer_and_starts_the_wizard = function()
    local world = installer_world.new()
    install(world, "sensor")
    local m = manifest()
    for path, entry in pairs(files_of("sensor", m)) do
      assert(world.fs.files[path] == read_disk(path), "wrong or missing: " .. path)
      assert(#world.fs.files[path] == entry.size)
    end
    assert(world.fs.files["src/nodes/sensor_node.lua"] and not world.fs.files["src/master/dispatcher.lua"] and not world.fs.files["src/nodes/signal_node.lua"])
    assert(world.fs.files["crn_version.txt"] == "main-" .. m.id)
    assert(world.fs.files["installer"] == read_disk("installer"), "the installer keeps a copy of itself for startup.lua to resume with")
    local record = plan.load_data(world.fs.files["crn_install.lua"], "record")
    assert(record.role == "sensor" and record.ref == "main" and record.id == m.id and #record.files > 20)
    for _, path in ipairs(record.files) do assert(not path:match("^configs/templates/") and not path:match("start_"), "seed files are not tracked: " .. path) end
    assert(not has_leftovers(world.fs), has_leftovers(world.fs))
    assert(world.shell_runs[1] == "scripts/setup.lua --role sensor", tostring(world.shell_runs[1]))
    assert(world.rebooted == 0 and world.fs.files["startup.lua"] == nil, "the wizard writes startup.lua, not the installer")
  end,

  test_nothing_is_downloaded_twice_and_an_update_restarts_the_computer = function()
    local world = installer_world.new()
    install(world, "sensor")
    world.fs.set("startup.lua", startup_for("sensor"))
    local before = #world.requests
    local ok, err = world.run({ "--yes" })
    assert(ok, tostring(err))
    for i = before + 1, #world.requests do
      local url = world.requests[i]:gsub("%?.*$", "")
      assert(not url:find("src/nodes/sensor_node.lua", 1, true) and not url:find("src/shared/net.lua", 1, true), "downloaded again: " .. url)
    end
    assert(world.rebooted == 1 and #world.shell_runs == 1, "restart, no wizard: " .. world.rebooted)
    assert(world.sleeps[#world.sleeps] == 2)
    assert(world.output():find("Alle Dateien sind auf dem Stand", 1, true))
  end,

  test_only_the_changed_file_is_replaced = function()
    local world = installer_world.new()
    install(world, "sensor")
    world.fs.set("startup.lua", startup_for("sensor"))
    local net_v1 = world.fs.files["src/shared/net.lua"]
    local other = world.fs.files["src/shared/util.lua"]
    world.set_version({ ["src/shared/net.lua"] = net_v1 .. "\n-- v2\n" })
    local ops = world.fs.ops
    local ok, err = world.run({ "--yes" })
    assert(ok, tostring(err))
    assert(world.fs.files["src/shared/net.lua"] == net_v1 .. "\n-- v2\n")
    assert(world.fs.files["src/shared/util.lua"] == other)
    assert(world.requests_for("src/shared/net.lua") == 2, "once at install, once at the update")
    assert(world.fs.ops - ops < 20, "few writes for one file: " .. (world.fs.ops - ops))
    local record = plan.load_data(world.fs.files["crn_install.lua"], "record")
    assert(record.id == plan.parse_manifest(world.served["install/manifest.lua"]).id)
  end,

  test_new_files_arrive_and_files_of_the_old_version_go = function()
    local world = installer_world.new()
    install(world, "sensor")
    world.fs.set("startup.lua", startup_for("sensor"))
    assert(world.fs.files["src/adapter/create_sensors.lua"])
    world.set_version({
      ["src/nodes/sensor_node.lua"] = sensor_node_v2(),
      ["src/shared/extra_module.lua"] = "return {}\n",
    })
    local old_set = files_of("sensor")
    local new_set = files_of("sensor", plan.parse_manifest(world.served["install/manifest.lua"]))
    local ok, err = world.run({ "--yes" })
    assert(ok, tostring(err))
    assert(world.fs.files["src/shared/extra_module.lua"] == "return {}\n", "new file")
    assert(world.fs.files["src/adapter/create_sensors.lua"] == nil, "old file removed")
    local gone = 0
    for path, entry in pairs(old_set) do
      if not new_set[path] and not entry.seed then
        gone = gone + 1
        assert(world.fs.files[path] == nil, "left behind: " .. path)
      end
    end
    assert(gone >= 1 and world.output():find(gone .. " entfernt", 1, true), gone)
  end,

  test_files_an_operator_edits_are_never_replaced_but_restored_when_missing = function()
    local world = installer_world.new()
    install(world, "master")
    world.fs.set("startup.lua", startup_for("master"))
    world.fs.set("configs/templates/network.full.example.json", '{"v":1,"channel":4242}')
    world.fs.files["scripts/start_master.lua"] = nil
    world.set_version({ ["configs/templates/network.full.example.json"] = '{"v":1,"channel":777}' })
    local ok, err = world.run({ "--yes" })
    assert(ok, tostring(err))
    assert(world.fs.files["configs/templates/network.full.example.json"] == '{"v":1,"channel":4242}', "the operator's config survives")
    assert(world.fs.files["scripts/start_master.lua"] == read_disk("scripts/start_master.lua"), "a missing seed file comes back")
  end,

  test_a_change_of_role_replaces_the_files_of_the_old_role = function()
    local world = installer_world.new()
    install(world, "sensor")
    world.fs.set("startup.lua", startup_for("sensor"))
    world.shell_runs = {}
    local ok, err = world.run({ "--role", "signal" })
    assert(ok, tostring(err))
    assert(world.fs.files["src/nodes/signal_node.lua"] and not world.fs.files["src/nodes/sensor_node.lua"])
    assert(world.shell_runs[1] == "scripts/setup.lua --role signal", "the wizard configures the new role")
    assert(world.rebooted == 0)
  end,

  test_nothing_is_touched_when_the_files_do_not_fit = function()
    local world = installer_world.new({ capacity = 60000 })
    local ok = world.run({ "--role", "master" })
    assert(not ok)
    assert(world.output():find("Speicher", 1, true), world.output())
    assert(world.fs.ops == 0 and next(world.fs.files) == nil, "the check comes before the first write")
  end,

  test_an_update_that_does_not_fit_leaves_the_working_version_alone = function()
    local world = installer_world.new()
    install(world, "sensor")
    world.fs.set("startup.lua", startup_for("sensor"))
    world.fs.capacity = world.fs.used() + 100
    local before = world.fs.snapshot()
    world.set_version({ ["src/shared/net.lua"] = read_disk("src/shared/net.lua") .. string.rep("-- padding\n", 2000) })
    local ok = world.run({ "--yes" })
    assert(not ok)
    assert(world.output():find("Speicher", 1, true))
    for path, body in pairs(before) do assert(world.fs.files[path] == body, "changed: " .. path) end
  end,

  test_a_damaged_download_is_repeated_until_it_matches = function()
    local world = installer_world.new()
    world.fail_next("src/shared/net.lua", 2, "corrupt")
    install(world, "signal")
    assert(world.fs.files["src/shared/net.lua"] == read_disk("src/shared/net.lua"))
    assert(world.requests_for("src/shared/net.lua") == 3)
  end,

  test_content_still_cached_in_the_cdn_is_noticed = function()
    local world = installer_world.new()
    world.fail_next("src/shared/net.lua", 1, "stale")
    install(world, "signal")
    assert(world.fs.files["src/shared/net.lua"] == read_disk("src/shared/net.lua"))
    assert(world.requests_for("src/shared/net.lua") == 2)
  end,

  test_cdn_error_pages_are_retried_with_waiting_in_between = function()
    local world = installer_world.new()
    world.fail_next("install/manifest.lua", 2, "html")
    install(world, "signal")
    assert(world.requests_for("install/manifest.lua") == 3)
    assert(world.sleeps[1] == 2 and world.sleeps[2] == 5, table.concat(world.sleeps, ","))
  end,

  test_a_file_that_cannot_be_loaded_stops_the_installation_and_keeps_the_journal = function()
    local world = installer_world.new()
    world.fail_next("src/nodes/signal_node.lua", 1000, "error")
    local ok = world.run({ "--role", "signal" })
    assert(not ok)
    assert(world.output():find("signal_node.lua", 1, true) and world.output():find("--resume", 1, true), world.output())
    assert(world.fs.files["crn_install_journal.lua"], "unfinished installation is marked")
    assert(#world.shell_runs == 0 and world.rebooted == 0)
    -- the network is back: resume finishes the job
    world.failures = {}
    local resumed, err = world.run({ "--resume", "--role", "signal" })
    assert(resumed, tostring(err))
    assert(not has_leftovers(world.fs), has_leftovers(world.fs))
    assert(world.fs.files["src/nodes/signal_node.lua"] == read_disk("src/nodes/signal_node.lua"))
  end,

  test_a_ref_that_does_not_exist_fails_clearly = function()
    local world = installer_world.new({ ref = "other-ref" })
    local ok, err = world.run({ "--ref", "no-such-branch", "--role", "signal" })
    assert(not ok)
    assert(tostring(err):find("install/http.lua", 1, true), tostring(err))
    assert(next(world.fs.files) == nil)
  end,

  test_bad_arguments_are_refused_before_anything_is_downloaded = function()
    local world = installer_world.new()
    local ok, err = world.run({ "--wat" })
    assert(not ok and tostring(err):find("Unbekannte Option", 1, true))
    ok, err = world.run({ "--ref" })
    assert(not ok and tostring(err):find("Wert", 1, true))
    ok, err = world.run({ "--ref", "../../etc" })
    assert(not ok and tostring(err):find("Ungueltiger Ref", 1, true))
    assert(#world.requests == 0)
    ok = world.run({ "--role", "wizard" })
    assert(not ok and world.output():find("Unbekannte Rolle", 1, true))
  end,

  test_role_menu_and_questions = function()
    local world = installer_world.new()
    local ok, err = world.run({}, { "3" })
    assert(ok, tostring(err))
    assert(world.shell_runs[1] == "scripts/setup.lua --role sensor", "3 is the sensor")
    assert(world.output():find("Master", 1, true) and world.output():find("Monitor", 1, true), "the menu uses the words of the wizard")

    local second = installer_world.new()
    local failed = second.run({}, { "x" })
    assert(not failed and second.output():find("Ungueltige Rolle", 1, true))

    -- an installed computer is asked whether it keeps its role
    local third = installer_world.new()
    install(third, "sensor")
    third.fs.set("startup.lua", startup_for("sensor"))
    third.shell_runs = {}
    assert(third.run({}, { "n", "2" }))
    assert(third.shell_runs[1] == "scripts/setup.lua --role signal")
    local fourth = installer_world.new()
    install(fourth, "sensor")
    fourth.fs.set("startup.lua", startup_for("sensor"))
    assert(fourth.run({}, { "j" }))
    assert(fourth.rebooted == 1)
  end,

  test_unattended_run_needs_a_known_role = function()
    local world = installer_world.new()
    local ok = world.run({ "--yes" })
    assert(not ok and world.output():find("--role", 1, true), world.output())
    assert(next(world.fs.files) == nil)
  end,

  test_unattended_new_computer_does_not_block_on_the_wizard = function()
    local world = installer_world.new()
    assert(world.run({ "--yes", "--role", "panel" }))
    assert(#world.shell_runs == 0 and world.output():find("scripts/setup.lua", 1, true))
  end,

  test_startup_lua_does_not_start_the_role_while_an_installation_is_unfinished = function()
    local text = startup_for("sensor")
    local function run(fs_files, shell_available)
      local state = { started = false, shell = {}, printed = {} }
      local env = setmetatable({
        fs = { exists = function(path) return fs_files[path] ~= nil end, open = function() return nil end },
        shell = shell_available and { run = function(...) state.shell[#state.shell + 1] = table.concat({ ... }, " ") end } or nil,
        print = function(line) state.printed[#state.printed + 1] = tostring(line) end,
        require = function(name)
          if name == "src.shared.ota_recovery" then return { recover = function() return "none" end } end
          state.required = name
          return { new_runtime = function() return { run = function() state.started = true end } end }
        end,
      }, { __index = _G })
      local chunk = assert(installer_world.compile_with_env(text, "startup", env))
      chunk()
      return state
    end
    local clean = run({}, true)
    assert(clean.started and clean.required == "src.nodes.sensor_node")
    for _, leftover in ipairs({ "crn_install_journal.lua", "crn_install_journal.lua.prev" }) do
      local broken = run({ [leftover] = "x", ["installer"] = "x" }, true)
      assert(not broken.started and broken.required == nil, leftover)
      assert(broken.shell[1] == "installer --resume")
    end
    local no_installer = run({ ["crn_install_journal.lua"] = "x" }, true)
    assert(not no_installer.started and #no_installer.shell == 0 and table.concat(no_installer.printed, " "):find("Installer", 1, true))
  end,

  -- the interrupted installation ----------------------------------------------------------------------------------

  test_a_crash_at_any_filesystem_operation_is_repaired_by_resuming = function()
    local function prepare(scenario)
      local world = installer_world.new()
      world.fs.sticky_crash = true
      if scenario == "update" then
        install(world, "sensor")
        world.fs.set("startup.lua", startup_for("sensor"))
        world.set_version({
          ["src/nodes/sensor_node.lua"] = sensor_node_v2(),
          ["src/shared/extra_module.lua"] = "return {}\n",
          ["src/shared/net.lua"] = read_disk("src/shared/net.lua") .. "\n-- v2\n",
        })
      end
      return world
    end
    local argv = { "--yes", "--role", "sensor" }

    for _, scenario in ipairs({ "fresh", "update" }) do
      local probe = prepare(scenario)
      local start = probe.fs.ops
      assert(probe.run(argv))
      local total = probe.fs.ops - start
      assert(total > 10, scenario .. ": " .. total)
      local expected = {}
      for path, entry in pairs(files_of("sensor", plan.parse_manifest(probe.served["install/manifest.lua"] or read_disk("install/manifest.lua")))) do
        expected[path] = probe.fs.files[path]
        assert(expected[path], path)
      end

      for n = 1, total do
        local world = prepare(scenario)
        local before = world.fs.snapshot()
        world.fs.crash_at = world.fs.ops + n
        local ok = world.run(argv)
        -- a crash during the very last operation can be swallowed by a pcall around a delete: the computer is dead all the same
        assert(not ok or world.fs.crashed, scenario .. " n=" .. n .. ": the crash did not happen")

        -- whatever is on the disk is a complete old or a complete new file, and an unfinished installation says so
        local changed = false
        for path, new_body in pairs(expected) do
          local body = world.fs.files[path]
          if body ~= before[path] then changed = true end
          assert(body == nil or body == before[path] or body == new_body, scenario .. " n=" .. n .. ": half a file: " .. path)
        end
        if changed then
          assert(world.fs.files["crn_install_journal.lua"] or world.fs.files["crn_install_journal.lua.prev"], scenario .. " n=" .. n .. ": changed files without a journal")
        end

        -- reboot, the startup guard runs `installer --resume`
        world.fs.crashed = false
        world.fs.crash_at = nil
        local resumed, err = world.run({ "--resume", "--role", "sensor" })
        assert(resumed, scenario .. " n=" .. n .. ": " .. tostring(err) .. "\n" .. world.output())
        for path, new_body in pairs(expected) do assert(world.fs.files[path] == new_body, scenario .. " n=" .. n .. ": " .. path) end
        assert(not has_leftovers(world.fs), scenario .. " n=" .. n .. ": " .. tostring(has_leftovers(world.fs)))
        assert(world.fs.files["crn_install.lua"] and world.fs.files["crn_version.txt"])
        if scenario == "update" then assert(world.fs.files["src/adapter/create_sensors.lua"] == nil, "n=" .. n .. ": old file left") end
      end
    end
  end,

  -- every role really starts --------------------------------------------------------------------------------------

  test_the_installed_files_of_every_role_load_without_anything_else = function()
    for _, role in ipairs(plan.ROLES) do
      local world = installer_world.new()
      install(world, role.key)
      local loaded = {}
      local env
      local function sandbox_require(name)
        if loaded[name] ~= nil then return loaded[name] end
        if name:sub(1, 3) == "cc." then return {} end
        local path = name:gsub("%.", "/") .. ".lua"
        local body = world.fs.files[path]
        assert(body, role.key .. ": module not installed: " .. name)
        local chunk = assert(installer_world.compile_with_env(body, name, env))
        local value = chunk()
        if value == nil then value = true end
        loaded[name] = value
        return value
      end
      env = setmetatable({ require = sandbox_require }, { __index = _G })
      local entry = role.key == "master" and sandbox_require("src.master.app") or sandbox_require("src.nodes." .. role.key .. "_node")
      assert(type(entry) == "table" and (type(entry.new) == "function" or type(entry.new_runtime) == "function"), role.key .. ": entry module")
      -- what startup.lua and setup.lua load
      sandbox_require("src.shared.ota_recovery")
      sandbox_require("src.shared.startup_template")
      sandbox_require("src.shared.startup_guard")
    end
  end,

  -- the wizard the installer hands over to ------------------------------------------------------------------------

  test_the_setup_script_takes_the_role_from_the_installer_and_runs_the_wizard = function()
    local memfs = require("tests.harness.memfs")
    local netplan = require("src.setup.netplan")
    local function run_script(argv, answers)
      local fs = memfs.new()
      local queue, lines, rebooted = {}, {}, 0
      for _, a in ipairs(answers) do queue[#queue + 1] = a end
      local env = setmetatable({
        fs = fs,
        print = function(text) lines[#lines + 1] = tostring(text) end,
        write = function(text) lines[#lines + 1] = tostring(text) end,
        read = function() return table.remove(queue, 1) end,
        peripheral = { getNames = function() return { "top" } end, getType = function() return "modem" end, getMethods = function() return {} end },
        os = setmetatable({ reboot = function() rebooted = rebooted + 1 end }, { __index = os }),
      }, { __index = _G })
      local chunk = assert(installer_world.compile_with_env(read_disk("scripts/setup.lua"), "setup", env))
      local unpack_fn = table.unpack or unpack
      local ok, err = pcall(chunk, unpack_fn(argv))
      assert(ok, tostring(err) .. "\n" .. table.concat(lines, "\n"))
      return fs, table.concat(lines, "\n"), rebooted
    end

    -- the installer starts it with the role: every question has a suggestion, so Enter all the way
    local fs, output, rebooted = run_script({ "--role", "signal" }, { "", "", "", "", "", "", "", "j" })
    local parsed = startup_template.parse(fs.files["startup.lua"] or "")
    assert(parsed and parsed.role == "signal" and parsed.id == "SIG-1" and parsed.config == netplan.PATH, output)
    assert(not output:find("Welche Aufgabe", 1, true), "no role menu when the installer chose the role")
    assert(fs.files["startup.lua"]:find("crn_install_journal", 1, true), "the new startup.lua carries the install guard")
    local cfg, errors = netplan.parse(fs.files[netplan.PATH])
    assert(cfg and errors == nil, "the plan the wizard wrote validates")
    assert(rebooted == 1)

    -- without a role it asks; input that ends cancels without writing
    local asked_fs, asked_output = run_script({}, { "" })
    assert(asked_output:find("Abgebrochen. Es wurde nichts geaendert.", 1, true) and next(asked_fs.files) == nil)
  end,
}
