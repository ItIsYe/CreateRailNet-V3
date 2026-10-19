--[[
Purpose: installer --preview (what an installation would do, without doing it) and the warning for a ref that can move (a branch). The
  preview must leave the computer exactly as it was: no file, no journal, no copy of the installer, no restart, no wizard.
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

local function snapshot(world)
  local copy = {}
  for path, body in pairs(world.fs.files) do copy[path] = body end
  return copy
end

local function unchanged(world, before)
  for path, body in pairs(world.fs.files) do if before[path] ~= body then return false, "changed or new: " .. path end end
  for path in pairs(before) do if world.fs.files[path] == nil then return false, "gone: " .. path end end
  return true
end

local function words(world) return (world.output():gsub("%s+", " ")) end

local function startup_for(role) return startup_template.render({ role = role, id = role:upper() .. "-1", config = "configs/templates/network.full.example.json" }) end

return {
  test_a_preview_on_a_new_computer_lists_everything_as_new_and_writes_nothing = function()
    local world = installer_world.new()
    local before = snapshot(world)
    local ok, err = world.run({ "--role", "sensor", "--preview" })
    assert(ok, tostring(err) .. "\n" .. world.output())
    local same, why = unchanged(world, before)
    assert(same, why)
    local text = words(world)
    assert(text:find("Vorschau", 1, true) and text:find("nichts geaendert", 1, true), text)
    assert(text:find("Neu: ", 1, true) and text:find(" Dateien", 1, true) and text:find("Byte", 1, true), text)
    assert(text:find("Geaendert: 0", 1, true) and text:find("Entfernt: 0", 1, true), text)
    assert(#world.shell_runs == 0 and world.rebooted == 0, "no wizard, no restart")
    assert(world.requests_for("src/shared/net.lua") == 0, "not a single file of the role is downloaded")
    assert(world.requests_for("install/manifest.lua") == 1)
  end,

  test_a_long_path_is_shortened_at_the_front_and_nothing_wraps_in_the_middle_of_a_name = function()
    local world = installer_world.new()
    assert(world.run({ "--role", "master", "--preview" }))
    for _, line in ipairs(world.printed) do
      assert(#line <= 50, "line too long (" .. #line .. "): " .. line)
    end
    local shortened = false
    for _, line in ipairs(world.printed) do
      if line:find("neu: ...", 1, true) then shortened = true end
    end
    assert(shortened, "a path that does not fit keeps its end: " .. world.output())
    assert(not world.output():find("jso\nn", 1, true), "no name is cut in two")
  end,

  test_a_preview_on_an_installed_computer_names_what_would_change = function()
    local world = installer_world.new()
    local ok, err = world.run({ "--role", "sensor" })
    assert(ok, tostring(err))
    world.fs.set("startup.lua", startup_for("sensor"))
    local net_v1 = world.fs.files["src/shared/net.lua"]
    world.set_version({ ["src/shared/net.lua"] = net_v1 .. "\n-- v2\n" })
    local before = snapshot(world)
    local requests = #world.requests
    ok, err = world.run({ "--yes", "--preview" })
    assert(ok, tostring(err) .. "\n" .. world.output())
    local same, why = unchanged(world, before)
    assert(same, why)
    local text = words(world)
    assert(text:find("Geaendert: 1 Datei", 1, true) and text:find("src/shared/net.lua", 1, true), text)
    assert(text:find("Neu: 0", 1, true) and text:find("Unveraendert: ", 1, true), text)
    assert(world.rebooted == 0, "an installed computer is not restarted by a preview")
    for index = requests + 1, #world.requests do
      assert(not world.requests[index]:find("src/shared/net.lua", 1, true), "the file itself is not downloaded")
    end
  end,

  test_files_of_an_older_version_that_would_go_are_listed = function()
    local world = installer_world.new()
    world.set_version({ ["src/nodes/sensor_node.lua"] = (function()
      local body = read_disk("src/nodes/sensor_node.lua")
      return (body:gsub('local create_sensors = require%("src.adapter.create_sensors"%)', 'local create_sensors = require("src.adapter.create_sensors")\nlocal legacy = require("src.shared.legacy_module")'))
    end)(), ["src/shared/legacy_module.lua"] = "return {}\n" })
    local ok, err = world.run({ "--role", "sensor" })
    assert(ok, tostring(err))
    world.fs.set("startup.lua", startup_for("sensor"))
    world.set_version({ ["src/nodes/sensor_node.lua"] = false, ["src/shared/legacy_module.lua"] = false })
    world.set_version({ ["src/nodes/sensor_node.lua"] = read_disk("src/nodes/sensor_node.lua") })
    local before = snapshot(world)
    ok, err = world.run({ "--yes", "--preview" })
    assert(ok, tostring(err) .. "\n" .. world.output())
    assert(words(world):find("Entfernt: 1 Datei", 1, true) and words(world):find("src/shared/legacy_module.lua", 1, true), world.output())
    assert(unchanged(world, before))
  end,

  test_a_preview_says_when_the_space_would_not_be_enough_and_still_changes_nothing = function()
    local world = installer_world.new({ capacity = 120 * 1000 })
    local before = snapshot(world)
    local ok, err = world.run({ "--role", "master", "--preview" })
    assert(ok, tostring(err) .. "\n" .. world.output())
    assert(words(world):find("Speicher reicht NICHT", 1, true), world.output())
    assert(unchanged(world, before))
    -- and the real installation stops at the same point
    local real = installer_world.new({ capacity = 120 * 1000 })
    local real_ok = real.run({ "--role", "master" })
    assert(real_ok == false)
  end,

  test_a_preview_where_it_fits_says_so = function()
    local world = installer_world.new()
    assert(world.run({ "--role", "signal", "--preview" }))
    assert(words(world):find("Speicher reicht", 1, true) and not words(world):find("Speicher reicht NICHT", 1, true), world.output())
  end,

  test_a_preview_cannot_be_combined_with_resume = function()
    local world = installer_world.new()
    local ok, err = world.run({ "--resume", "--preview" })
    assert(ok == false and tostring(err):find("gehen nicht zusammen", 1, true), tostring(err))
  end,

  test_without_preview_nothing_changes_in_the_normal_install = function()
    local world = installer_world.new()
    local ok, err = world.run({ "--role", "sensor" })
    assert(ok, tostring(err))
    assert(not words(world):find("Vorschau", 1, true))
    assert(world.fs.files["crn_version.txt"] and #world.shell_runs == 1)
  end,

  -- ── a ref that can move ───────────────────────────────────────────────────────────────────────────────────────────

  test_the_kind_of_a_ref = function()
    for _, ref in ipairs({ "v1.0.0", "v2.3", "1.4.2", "v1.0.0-rc1", "0123456789abcdef0123456789abcdef01234567", "0123abc" }) do
      assert(plan.ref_kind(ref) == "fixed", ref)
    end
    for _, ref in ipairs({ "main", "master", "dev", "claude/creareailnet-review-4ucdvu", "v1", "release", "abc", "feature/1.2.3" }) do
      assert(plan.ref_kind(ref) == "branch", ref)
    end
  end,

  test_a_branch_gets_a_warning_with_the_way_out_and_a_tag_does_not = function()
    local world = installer_world.new()
    assert(world.run({ "--role", "signal", "--preview" }))
    local text = words(world)
    assert(text:find("'main' ist ein Branch", 1, true) and text:find("--ref", 1, true) and text:find("Tag", 1, true), text)
    local fixed = installer_world.new({ ref = "v1.2.0" })
    assert(fixed.run({ "--ref", "v1.2.0", "--role", "signal", "--preview" }))
    assert(not words(fixed):find("Branch", 1, true), fixed.output())
  end,

  test_the_resume_after_an_interruption_does_not_nag = function()
    local world = installer_world.new()
    assert(world.run({ "--role", "signal" }))
    world.fs.set("startup.lua", startup_for("signal"))
    local printed = #world.printed
    assert(world.run({ "--resume" }))
    for index = printed + 1, #world.printed do assert(not world.printed[index]:find("Branch", 1, true), world.printed[index]) end
  end,
}
