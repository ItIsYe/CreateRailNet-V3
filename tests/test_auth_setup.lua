--[[
Purpose: The authentication of a computer is built from its config and key files the same way on every role; a missing key never crashes a computer (Kap. 12).
Public API: returns table of tests.
]]

pcall(dofile, "tests/harness/cc_bootstrap.lua")

local auth_setup = require("src.shared.auth_setup")
local keystore = require("src.shared.keystore")
local keyring = require("src.shared.keyring")
local common_node = require("src.nodes.common_node")
local validate = require("src.shared.validate")
local memfs = require("tests.harness.memfs")
local auth_bench = require("src.setup.auth_bench")

local MASTER_KEY = string.rep("cd", 32)

local function recording_logger()
  local lines = {}
  local function add(level) return function(text, data) lines[#lines + 1] = { level = level, text = text, data = data } end end
  return { info = add("info"), warn = add("warn"), error = add("error"), debug = add("debug"), lines = lines }
end

local function config(mode) return { v = 1, channel = 1, master_id = "M", auth_mode = mode, nodes = {} } end

return {
  test_off_and_missing_mean_no_authentication_at_all = function()
    assert(auth_setup.build(config("off"), "N1") == nil)
    assert(auth_setup.build(config(nil), "N1") == nil)
    assert(auth_setup.build({ master_id = "M" }, "N1") == nil)
  end,

  test_an_unknown_word_never_switches_the_protection_off = function()
    local instance = auth_setup.build(config("of"), "N1", { logger = recording_logger() })
    assert(instance and instance.mode == "enforce")
  end,

  test_a_node_with_its_key_file_signs_and_a_node_without_one_signs_nothing = function()
    local fs = memfs.new()
    local trust = { rev = 0, nodes = {} }
    local record = keystore.issue(trust, MASTER_KEY, "N1", "signal", 1)
    keystore.save_node(record, "state/crn_key.json", { fs = fs })
    local logger = recording_logger()
    local with_key = auth_setup.build(config("enforce"), "N1", { fs = fs, logger = logger })
    local msg = { v = 1, id = "a", src = "N1", dst = "M", type = "event", payload = {} }
    assert(with_key.sign(msg) and msg.at and #msg.at == 32 and msg.ke == 1)
    assert(#logger.lines == 0)

    local logger2 = recording_logger()
    local without = auth_setup.build(config("enforce"), "N2", { fs = memfs.new(), logger = logger2 })
    local msg2 = { v = 1, id = "b", src = "N2", dst = "M", type = "event", payload = {} }
    assert(without.sign(msg2) == false and msg2.at == nil)
    assert(#logger2.lines == 1 and logger2.lines[1].level == "warn", "the missing key is said once")
  end,

  test_a_key_file_that_belongs_to_another_computer_is_not_used = function()
    local fs = memfs.new()
    local trust = { rev = 0, nodes = {} }
    keystore.save_node(keystore.issue(trust, MASTER_KEY, "OTHER", "signal", 1), "state/crn_key.json", { fs = fs })
    local logger = recording_logger()
    local instance = auth_setup.build(config("enforce"), "N1", { fs = fs, logger = logger })
    local msg = { v = 1, id = "a", src = "N1", dst = "M", type = "event", payload = {} }
    assert(instance.sign(msg) == false)
    assert(logger.lines[1] and logger.lines[1].data.error:find("OTHER", 1, true))
  end,

  test_a_master_reads_its_key_and_the_list_and_takes_over_a_changed_list = function()
    local fs = memfs.new()
    keystore.save_master({ key = MASTER_KEY }, "state/crn_master_key.json", { fs = fs })
    local trust = { rev = 0, nodes = {} }
    keystore.save_trust(trust, "state/crn_trust.json", { fs = fs })
    local logger = recording_logger()
    local master = auth_setup.build(config("enforce"), "M", { master = true, fs = fs, logger = logger })
    assert(master.keyring.kind == "master")
    local msg = { v = 1, id = "a", src = "M", dst = "N1", type = "cmd", payload = {} }
    assert(master.sign(msg) == false, "N1 has no key yet")
    assert(master.reload_trust() == false, "nothing changed")
    -- the operator issues a key (scripts/keys.lua writes the list)
    local loaded = keystore.load_trust("state/crn_trust.json", { fs = fs })
    keystore.issue(loaded, MASTER_KEY, "N1", "signal", 5)
    keystore.save_trust(loaded, "state/crn_trust.json", { fs = fs })
    assert(master.reload_trust() == true)
    assert(master.sign(msg) and msg.ke == 1)
    assert(master.reload_trust() == false)
  end,

  test_a_trust_list_that_cannot_be_read_leaves_the_old_one_in_force_and_says_so_once = function()
    local fs = memfs.new()
    keystore.save_master({ key = MASTER_KEY }, "state/crn_master_key.json", { fs = fs })
    local trust = { rev = 0, nodes = {} }
    keystore.issue(trust, MASTER_KEY, "N1", "signal", 1)
    keystore.save_trust(trust, "state/crn_trust.json", { fs = fs })
    local logger = recording_logger()
    local master = auth_setup.build(config("enforce"), "M", { master = true, fs = fs, logger = logger })
    fs.files["state/crn_trust.json"] = "garbage"
    fs.files["state/crn_trust.json.prev"] = nil
    assert(master.reload_trust() == false)
    assert(master.reload_trust() == false)
    local errors = 0
    for _, line in ipairs(logger.lines) do if line.level == "error" then errors = errors + 1 end end
    assert(errors == 1, "said " .. errors .. " times")
    local msg = { v = 1, id = "a", src = "M", dst = "N1", type = "cmd", payload = {} }
    assert(master.sign(msg), "the old list is still in force")
  end,

  test_a_master_without_a_master_key_starts_and_signs_nothing = function()
    local logger = recording_logger()
    local master = auth_setup.build(config("enforce"), "M", { master = true, fs = memfs.new(), logger = logger })
    assert(master)
    local msg = { v = 1, id = "a", src = "M", dst = "N1", type = "cmd", payload = {} }
    assert(master.sign(msg) == false)
    assert(logger.lines[1] and logger.lines[1].level == "error")
  end,

  test_a_common_node_builds_its_authentication_from_the_config = function()
    local fs = memfs.new()
    local trust = { rev = 0, nodes = {} }
    keystore.save_node(keystore.issue(trust, MASTER_KEY, "N1", "signal", 1), "state/crn_key.json", { fs = fs })
    local modem = { open = function() return true end, send = function() return true end, broadcast = function() return true end }
    local on = common_node.new({ id = "N1", role = "signal", config = config("enforce"), modem = modem, auth_fs = fs, logger = recording_logger() })
    assert(on.auth and on.net.auth == on.auth)
    local off = common_node.new({ id = "N1", role = "signal", config = config("off"), modem = modem, logger = recording_logger() })
    assert(off.auth == nil and off.net.auth == nil)
    local none = common_node.new({ id = "N1", role = "signal", config = { channel = 1, master_id = "M" }, modem = modem, logger = recording_logger() })
    assert(none.auth == nil)
  end,

  test_config_validation_names_a_wrong_auth_mode_and_wrong_masters = function()
    local function check(mutation)
      local cfg = { v = 1, channel = 1, master_id = "M", blocks = {}, routes = {}, nodes = { { id = "M", role = "master" } } }
      mutation(cfg)
      local ok, errors = validate.validate_config(cfg)
      return ok, table.concat(errors or {}, "\n")
    end
    assert(check(function(c) c.auth_mode = "enforce" end))
    assert(check(function(c) c.auth_mode = "monitor" end))
    local ok, text = check(function(c) c.auth_mode = "strict" end)
    assert(not ok and text:find("auth_mode", 1, true))
    ok, text = check(function(c) c.masters = "MA" end)
    assert(not ok and text:find("masters", 1, true))
    ok, text = check(function(c) c.masters = { "MA", "MA" } end)
    assert(not ok and text:find("twice", 1, true))
    ok, text = check(function(c) c.masters = { "" } end)
    assert(not ok and text:find("masters[1]", 1, true))
  end,

  test_the_benchmark_runs_a_whole_handshake_and_reports_every_figure = function()
    local ticks = 0
    local result = auth_bench.run({ rounds = 20, clock = function() ticks = ticks + 0.001; return ticks end })
    assert(result.rounds == 20 and result.backend and result.hash_ms > 0 and result.sign_ms > 0 and result.verify_ms > 0 and result.per_second > 0)
    local lines = auth_bench.lines(result)
    assert(#lines == 5 and lines[3]:find("signieren", 1, true) and lines[4]:find("Nachrichten pro Sekunde", 1, true))
  end,
}
