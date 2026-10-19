--[[
Purpose: The release check (scripts/release_check.lua, src/tools/release_check.lua): it runs the checks of the CI, looks at the state of git, and
  only when everything is green does it print the commands for a version tag -- it never runs them. A tag is a statement that this state
  was checked; nothing here makes that statement for a person.
Public API: returns table of tests.
]]

pcall(dofile, "tests/harness/cc_bootstrap.lua")

local release_check = require("src.tools.release_check")

local HASH = "0123456789abcdef0123456789abcdef01234567"

-- a world where everything is fine; overrides change one thing
local function world(over)
  local o = over or {}
  local w = { ran = {}, git_calls = {} }
  w.run = function(cmd)
    w.ran[#w.ran + 1] = cmd
    if o.fail and cmd:find(o.fail, 1, true) then return false, "rot" end
    if o.missing and cmd:find(o.missing, 1, true) then return false, "not found", true end
    return true, "ok"
  end
  w.git = function(args)
    w.git_calls[#w.git_calls + 1] = args
    if args == "status --porcelain" then return o.dirty or "" end
    if args == "rev-parse HEAD" then return HASH end
    if args == "rev-parse --abbrev-ref HEAD" then return o.branch or "main" end
    if args:match("^tag %-%-list ") then return o.tag_exists and "v1.0.0" or "" end
    return nil
  end
  return w
end

local function check(w, version, extra)
  local opts = { version = version, run = w.run, git = w.git, lua = "lua5.4", lua51 = "lua5.1" }
  for key, value in pairs(extra or {}) do opts[key] = value end
  return release_check.run(opts)
end

local function text_of(report) return table.concat(report.lines, "\n") end

return {
  test_everything_green_prints_the_tag_commands_and_runs_none_of_them = function()
    local w = world()
    local report = check(w, "v1.0.0")
    assert(report.ok, text_of(report))
    local text = text_of(report)
    assert(text:find('git tag -a v1.0.0 -m "CreateRailNet v1.0.0" ' .. HASH, 1, true), text)
    assert(text:find("git push origin v1.0.0", 1, true), text)
    assert(text:find("raw.githubusercontent.com/ItIsYe/CreateRailNet-V3/v1.0.0/installer --ref v1.0.0", 1, true), text)
    for _, cmd in ipairs(w.ran) do
      assert(not cmd:find("git tag", 1, true) and not cmd:find("push", 1, true), "the release check runs checks only: " .. cmd)
    end
    for _, args in ipairs(w.git_calls) do
      assert(args:match("^status") or args:match("^rev%-parse") or args:match("^tag %-%-list"), "git is only asked, never told: " .. args)
    end
  end,

  test_it_runs_the_checks_of_the_ci = function()
    local w = world()
    check(w, "v1.0.0")
    local joined = table.concat(w.ran, "\n")
    for _, expected in ipairs({ "lua5.4 scripts/check_syntax.lua", "lua5.4 scripts/check_configs.lua", "lua5.4 scripts/check_test_registry.lua",
      "lua5.4 scripts/manifest_sync.lua --check", "lua5.1 scripts/cc_parse_guard.lua", "lua5.4 scripts/run_tests.lua", "lua5.1 scripts/run_tests.lua" }) do
      assert(joined:find(expected, 1, true), "not run: " .. expected)
    end
  end,

  test_one_failed_check_means_no_tag_commands = function()
    local w = world({ fail = "check_configs" })
    local report = check(w, "v1.0.0")
    assert(report.ok == false)
    local text = text_of(report)
    assert(text:find("[FEHL]", 1, true) and text:find("check_configs", 1, true), text)
    assert(not text:find("git tag", 1, true) and not text:find("git push", 1, true), "nothing to copy while something is red")
    assert(text:find("Noch kein Tag", 1, true), text)
  end,

  test_a_failing_test_suite_on_one_interpreter_counts = function()
    local report = check(world({ fail = "lua5.1 scripts/run_tests.lua" }), "v1.0.0")
    assert(report.ok == false)
  end,

  test_a_dirty_working_tree_is_no_release = function()
    local report = check(world({ dirty = " M src/shared/net.lua\n?? notes.txt" }), "v1.0.0")
    assert(report.ok == false and text_of(report):find("nicht eingecheckt", 1, true), text_of(report))
  end,

  test_a_tag_that_exists_is_no_release_either = function()
    local report = check(world({ tag_exists = true }), "v1.0.0")
    assert(report.ok == false and text_of(report):find("gibt es schon", 1, true), text_of(report))
  end,

  test_an_interpreter_that_is_missing_is_said_and_is_a_failure = function()
    local report = check(world({ missing = "lua5.1 scripts/cc_parse_guard.lua" }), "v1.0.0")
    assert(report.ok == false)
    assert(text_of(report):find("nicht gefunden", 1, true) and text_of(report):find("--lua51", 1, true), text_of(report))
  end,

  test_the_version_must_look_like_a_version = function()
    for _, bad in ipairs({ "main", "1.0.0", "v1", "v1.0", "v1.0.0; rm -rf /", "v1.0.0 -f", "../v1.0.0", "", "v1.0.0\nx" }) do
      local w = world()
      local report = check(w, bad)
      assert(report.ok == false and text_of(report):find("vX.Y.Z", 1, true), "accepted: " .. bad)
      assert(#w.ran == 0, "nothing is run for a version that is wrong: " .. bad)
    end
    for _, good in ipairs({ "v0.1.0", "v12.34.56", "v1.0.0-rc1" }) do
      assert(check(world(), good).ok, good)
    end
  end,

  test_without_a_version_the_checks_run_and_no_commands_are_printed = function()
    local report = check(world(), nil)
    assert(report.ok == true)
    assert(not text_of(report):find("git tag", 1, true) and text_of(report):find("--version", 1, true), text_of(report))
  end,

  test_a_branch_other_than_the_default_is_pointed_out_but_not_forbidden = function()
    local report = check(world({ branch = "claude/some-work" }), "v1.0.0")
    assert(report.ok == true and text_of(report):find("claude/some-work", 1, true), text_of(report))
  end,

  test_git_that_does_not_answer_is_a_failure = function()
    local w = world()
    w.git = function() return nil end
    local report = check(w, "v1.0.0")
    assert(report.ok == false and text_of(report):find("git", 1, true))
  end,
}
