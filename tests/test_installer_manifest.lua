--[[
Purpose: The installer's file list is exactly what the code needs: current, closed under require(), free of development files, valid for OTA.
Public API: returns table of tests.
]]

pcall(dofile, "tests/harness/cc_bootstrap.lua")

local json = require("src.shared.json")
local checksum = require("src.shared.checksum")
local plan = dofile("install/plan.lua")
local require_scan = require("src.shared.require_scan")
local manifest_builder = require("src.tools.manifest_builder")
local updater = require("src.shared.updater")
local runtime_packager = require("src.tools.runtime_packager")
local storage_budget = require("src.shared.storage_budget")

local function read(path)
  local fh = io.open(path, "rb")
  if not fh then return nil end
  local body = fh:read("*a")
  fh:close()
  return body
end

local function load_manifest() return assert(plan.parse_manifest(read("install/manifest.lua"))) end

local function role_set(manifest, role)
  local set = {}
  for path in pairs(assert(plan.files_for_role(manifest, role))) do set[path] = true end
  return set
end

return {
  test_committed_manifest_is_current = function()
    local runtime_manifest = json.decode(read("configs/install/runtime_manifest.json"))
    local built, problems = manifest_builder.build(read, runtime_manifest)
    assert(#problems == 0, table.concat(problems, "; "))
    assert(read("install/manifest.lua") == manifest_builder.render(built),
      "install/manifest.lua is out of date: run lua scripts/manifest_sync.lua --write")
  end,

  test_manifest_validates_and_every_listed_file_matches_the_disk = function()
    local manifest = load_manifest()
    assert(plan.validate(manifest))
    for path, entry in pairs(manifest.files) do
      local body = manifest_builder.shipped(path, assert(read(path), "missing " .. path))
      assert(read("dist/" .. path) == body, "dist/" .. path .. " is out of date: run lua scripts/build_dist.lua --write")
      assert(#body == entry[1] and checksum.adler32(body) == entry[2], "stale entry " .. path)
    end
  end,

  test_every_role_is_closed_under_require = function()
    local manifest = load_manifest()
    for _, role in ipairs(plan.ROLES) do
      local set = role_set(manifest, role.key)
      for path in pairs(set) do
        if path:match("%.lua$") then
          for _, name in ipairs(require_scan.modules(read(path))) do
            if name:sub(1, 4) == "src." then
              assert(set[require_scan.module_path(name)], role.key .. ": " .. path .. " needs " .. name .. ", which is not installed")
            end
          end
        end
      end
    end
  end,

  test_every_role_has_what_it_starts_from = function()
    local manifest = load_manifest()
    for _, role in ipairs(plan.ROLES) do
      local set = role_set(manifest, role.key)
      assert(set["src/shared/ota_recovery.lua"], role.key .. ": startup.lua runs the OTA recovery")
      assert(set["src/shared/startup_template.lua"] and set["scripts/setup.lua"], role.key .. ": the setup wizard")
      assert(set["configs/templates/network.full.example.json"], role.key .. ": the default config")
      if role.key == "master" then
        assert(set["src/master/main.lua"] and set["src/master/app.lua"] and set["scripts/ota_push.lua"])
      else
        assert(set["src/nodes/" .. role.key .. "_node.lua"], role.key .. ": its node module")
        assert(not set["src/master/dispatcher.lua"], role.key .. ": the dispatcher belongs on the master only")
      end
    end
  end,

  test_roles_in_the_menu_and_in_the_manifest_are_the_same = function()
    local manifest = load_manifest()
    local menu = {}
    for _, role in ipairs(plan.ROLES) do menu[role.key] = true; assert(manifest.roles[role.key], role.key .. " not in the manifest") end
    for role in pairs(manifest.roles) do assert(menu[role], role .. " has no menu entry") end
    for role in pairs(manifest_builder.ROLES) do assert(menu[role]) end
  end,

  test_no_development_file_is_installed = function()
    local manifest = load_manifest()
    local rules = json.decode(read("configs/install/runtime_manifest.json"))
    for path in pairs(manifest.files) do
      assert(runtime_packager.should_include(rules, path), path .. " is not allowed by runtime_manifest.json")
      assert(not path:match("^tests/") and not path:match("^docs/") and not path:match("^src/sim/") and not path:match("^src/tools/")
        and not path:match("^install/") and path ~= "installer", path)
      assert(not path:match("run_tests") and not path:match("check_") and not path:match("manifest_sync") and not path:match("replay_trace"), path)
    end
  end,

  test_installed_paths_can_be_updated_over_the_air_later = function()
    for path in pairs(load_manifest().files) do assert(updater.valid_path(path), "OTA would refuse " .. path) end
  end,

  test_seed_files_are_what_an_operator_edits = function()
    local manifest = load_manifest()
    local seed = {}
    for _, path in ipairs(manifest.seed) do seed[path] = true end
    assert(seed["configs/templates/network.full.example.json"] and seed["scripts/start_master.lua"])
    assert(not seed["src/shared/net.lua"])
  end,

  test_the_planner_is_part_of_the_setup_bundle_of_the_master_and_of_no_other_computer = function()
    local manifest = load_manifest()
    for _, role in ipairs(plan.ROLES) do
      local running = assert(plan.files_for_role(manifest, role.key))
      local with_bundle = assert(plan.files_for_role(manifest, role.key, true))
      for _, path in ipairs({ "src/setup/layout.lua", "src/setup/plan_builder.lua", "src/setup/bauliste.lua" }) do
        assert(running[path] == nil, path .. " is not on a running " .. role.key)
        assert((with_bundle[path] ~= nil) == (role.key == "master"), path .. " in the bundle of " .. role.key)
      end
    end
  end,

  test_the_setup_tools_are_in_the_bundle_and_not_on_a_running_computer = function()
    local manifest = load_manifest()
    for _, role in ipairs(plan.ROLES) do
      local running = assert(plan.files_for_role(manifest, role.key))
      local with_bundle = assert(plan.files_for_role(manifest, role.key, true))
      for _, path in ipairs({ "src/setup/wizard.lua", "src/setup/doctor.lua", "src/setup/keys_tool.lua", "scripts/setup_main.lua", "scripts/keys_main.lua" }) do
        assert(running[path] == nil and with_bundle[path] ~= nil, role.key .. ": " .. path)
      end
      for _, path in ipairs({ "scripts/setup.lua", "scripts/keys.lua", "src/shared/setup_bundle.lua" }) do
        assert(running[path] ~= nil, role.key .. ": the stub " .. path .. " stays")
      end
      -- the bundle is closed under require together with the running files, and a running computer needs nothing of it
      for path in pairs(with_bundle) do
        if path:match("%.lua$") then
          for _, name in ipairs(require_scan.modules(manifest_builder.shipped(path, read(path)))) do
            if name:sub(1, 4) == "src." then assert(with_bundle[require_scan.module_path(name)], role.key .. ": " .. path .. " needs " .. name) end
          end
        end
      end
      for path in pairs(running) do
        if path:match("%.lua$") and not path:match("^scripts/setup%.lua$") then
          for _, name in ipairs(require_scan.modules(read(path))) do
            local needed = name:sub(1, 4) == "src." and require_scan.module_path(name)
            assert(not needed or running[needed], role.key .. ": the running file " .. path .. " needs " .. name .. ", which is in the bundle")
          end
        end
      end
    end
  end,

  test_a_role_fits_on_a_default_computer = function()
    -- a CC:Tweaked computer holds 1 000 000 bytes and that does not change: program (the minified files of dist/, every file counted at least 500 bytes),
    -- state files at their caps and the headroom of an update have to fit (src/shared/storage_budget.lua)
    local manifest = load_manifest()
    for _, role in ipairs(plan.ROLES) do
      local counted = 0
      for _, entry in pairs(assert(plan.files_for_role(manifest, role.key))) do counted = counted + math.max(entry.size, storage_budget.MIN_FILE_COST) end
      -- the setup bundle comes on top while a computer is set up or a tool runs; that has to fit next to the state (an update has to wait until it is gone)
      local with_bundle = 0
      for _, entry in pairs(assert(plan.files_for_role(manifest, role.key, true))) do with_bundle = with_bundle + math.max(entry.size, storage_budget.MIN_FILE_COST) end
      assert(with_bundle + storage_budget.state_worst_case(role.key) <= storage_budget.LIMIT, role.key .. ": program with the setup bundle " .. with_bundle)
      local budget = storage_budget.program_budget(role.key)
      assert(counted <= budget, role.key .. " needs " .. counted .. " bytes of program, the budget is " .. budget .. " (" .. storage_budget.LIMIT .. " minus state " .. storage_budget.state_worst_case(role.key) .. " minus update headroom " .. storage_budget.OTA_HEADROOM .. ")")
      assert(counted + storage_budget.state_worst_case(role.key) + storage_budget.OTA_HEADROOM <= storage_budget.LIMIT)
    end
  end,

  test_scan_ignores_comments_and_finds_all_spellings = function()
    local body = table.concat({
      "-- local x = require(\"src.never\")",
      "--[[ require(\"src.also_never\") ]]",
      "local a = require(\"src.a\")",
      "local b = require 'src.b'",
      "local ok, c = pcall(require, \"src.c\")",
      "local d = require(\"cc.strings\")",
    }, "\n")
    local found = require_scan.modules(body)
    assert(table.concat(found, ",") == "cc.strings,src.a,src.b,src.c", table.concat(found, ","))
  end,

  test_closure_reports_what_is_missing_or_not_part_of_the_runtime = function()
    local files = {
      ["src/a.lua"] = "require('src.b') require('tests.helper') require('cc.pretty')",
      ["src/b.lua"] = "require('src.missing')",
    }
    local paths, problems = require_scan.closure({ "src.a" }, function(path) return files[path] end)
    assert(table.concat(paths, ",") == "src/a.lua,src/b.lua")
    assert(problems.missing[1] == "src.missing" and problems.external[1] == "tests.helper" and #problems.external == 1)
  end,

  test_plan_rejects_bad_manifests = function()
    local function with(change)
      local manifest = load_manifest()
      change(manifest)
      return plan.validate(manifest)
    end
    assert(not with(function(m) m.version = 2 end))
    assert(not with(function(m) m.id = "xyz" end))
    assert(not with(function(m) m.files["../../startup.lua"] = { 10, 1 } end))
    assert(not with(function(m) m.files["/etc/passwd.lua"] = { 10, 1 } end))
    assert(not with(function(m) m.files["tests/x.lua"] = { 10, 1 } end))
    assert(not with(function(m) m.files["src/shared/net.lua"] = { -1, 1 } end))
    assert(not with(function(m) m.base[#m.base + 1] = "src/shared/nowhere.lua" end))
    assert(not with(function(m) m.seed[#m.seed + 1] = "src/shared/nowhere.lua" end))
    assert(not with(function(m) m.roles = nil end))
    assert(plan.parse_manifest("not lua at all (") == nil)
    assert(plan.parse_manifest("os.exit()") == nil, "a manifest runs without any globals")
  end,

  test_diff_compares_size_first_and_leaves_seed_files_alone = function()
    local files = {
      ["a.lua"] = { size = 3, adler = checksum.adler32("abc"), seed = false },
      ["b.lua"] = { size = 3, adler = checksum.adler32("abc"), seed = false },
      ["c.lua"] = { size = 100, adler = 1, seed = false },
      ["cfg.json"] = { size = 100, adler = 1, seed = true },
      ["missing.json"] = { size = 5, adler = 1, seed = true },
    }
    local disk = { ["a.lua"] = "abc", ["b.lua"] = "abd", ["cfg.json"] = "edited by the operator" }
    local checks = 0
    local todo, unchanged = plan.diff(files, function(path) return disk[path] end, function(text) checks = checks + 1; return checksum.adler32(text) end,
      function(path) return disk[path] ~= nil end)
    assert(unchanged == 2, unchanged)
    assert(table.concat(todo, ",") == "c.lua,missing.json,b.lua" or table.concat(todo, ",") == "c.lua,b.lua,missing.json", table.concat(todo, ","))
    assert(checks == 2, "no checksum for files with the wrong size or for seed files: " .. checks)
  end,
}
