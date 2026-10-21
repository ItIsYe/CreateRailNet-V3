--[[
Purpose: The operator's key tool end to end: master key, issuing on a disk, installing on a computer, revoking, carrying the master key to the second master,
  and a real message that is signed with what the tool wrote (docs/KEYS.md).
Public API: returns table of tests.
]]

pcall(dofile, "tests/harness/cc_bootstrap.lua")

local keys_tool = require("src.setup.keys_tool")
local keystore = require("src.shared.keystore")
local keyring = require("src.shared.keyring")
local auth_setup = require("src.shared.auth_setup")
local net = require("src.shared.net")
local memfs = require("tests.harness.memfs")
local prng = require("tests.harness.prng")
local lossy_link = require("tests.harness.lossy_link")

local function computer(disk, answers)
  local c = { fs = memfs.new(), said = {}, asked = {}, answers = answers or {} }
  c.env = {
    fs = c.fs,
    peripheral = {
      getNames = function() return disk and { "drive_0" } or {} end,
      getType = function() return "drive" end,
      call = function(_, method) assert(method == "getMountPath"); return "disk" end
    },
    say = function(text) c.said[#c.said + 1] = text end,
    ask = function(prompt) c.asked[#c.asked + 1] = prompt; return table.remove(c.answers, 1) or "" end,
    now = function() return 1000 end,
    entropy = function() return "test" end
  }
  function c.run(...) return keys_tool.run({ ... }, c.env) end
  function c.output() return table.concat(c.said, "\n") end
  return c
end

-- the disk is carried from one computer to the other: files below disk/
local function carry(from, to)
  for path, body in pairs(from.fs.files) do
    if path:sub(1, 5) == "disk/" then to.fs.files[path] = body end
  end
end

return {
  test_no_command_prints_the_help = function()
    local c = computer(false)
    assert(c.run() == 0)
    assert(c.output():find("issue <ID>", 1, true))
    assert(c.run("nonsense") == 1)
  end,

  test_init_makes_the_master_key_and_refuses_to_replace_it_silently = function()
    local c = computer(false, { "zufaellige zeichen" })
    assert(c.run("init") == 0)
    local master = assert(keystore.load_master(nil, { fs = c.fs }))
    assert(keyring.valid_key(master.key))
    assert(c.output():find(keyring.fingerprint(master.key), 1, true))
    assert(c.output():find("keys export-master", 1, true))
    -- again: refused, nothing changes
    local again = computer(false)
    again.fs.files = c.fs.files
    assert(again.run("init") == 1)
    assert(keystore.load_master(nil, { fs = again.fs }).key == master.key)
    assert(again.output():find("--force", 1, true))
    -- --force without the word: refused
    local forced = computer(false, { "nein" })
    forced.fs.files = c.fs.files
    assert(forced.run("init", "--force") == 1)
    assert(keystore.load_master(nil, { fs = forced.fs }).key == master.key)
    -- --force with the word: a new key, the old entries are dead
    local trust = keystore.load_trust(nil, { fs = c.fs })
    keystore.issue(trust, master.key, "SIG-1", "signal", 1)
    keystore.save_trust(trust, nil, { fs = c.fs })
    local really = computer(false, { "JA", "mehr zufall" })
    really.fs.files = c.fs.files
    assert(really.run("init", "--force") == 0)
    local replaced = keystore.load_master(nil, { fs = really.fs })
    assert(replaced.key ~= master.key)
    assert(keystore.load_trust(nil, { fs = really.fs }).nodes["SIG-1"].status == "revoked")
  end,

  test_issue_needs_a_master_key = function()
    local c = computer(true)
    assert(c.run("issue", "SIG-1") == 1)
    assert(c.output():find("keys init", 1, true))
  end,

  test_a_key_travels_from_the_master_to_a_computer_on_a_disk_and_signs_real_messages = function()
    local master = computer(true, { "zufall" })
    assert(master.run("init") == 0)
    assert(master.run("issue", "SIG-1", "--role", "signal") == 0)
    assert(master.fs.files["disk/crn_key_SIG-1.json"], "the key file is on the disk")
    assert(not master.output():find("Schluessel: ", 1, true), "a key is not printed when a disk takes it")

    local node = computer(true, { "j", "j" })
    carry(master, node)
    assert(node.run("install", "--id", "SIG-1") == 0)
    local record = assert(keystore.load_node(nil, { fs = node.fs }))
    assert(record.id == "SIG-1" and record.epoch == 1)
    assert(node.fs.files["disk/crn_key_SIG-1.json"] == nil, "the key file was deleted from the disk on request")
    -- both sides name the same fingerprint of the key
    local issued_line = master.output():match("Pruefsumme (%x%x%x%x%-%x%x%x%x%-%x%x%x%x)%)")
    assert(issued_line == keyring.fingerprint(record.key), "master said " .. tostring(issued_line))
    assert(node.output():find(keyring.fingerprint(record.key), 1, true))

    -- a real exchange with what the tool wrote: master and node build their authentication from their files
    local rng = prng.new(5)
    local link = lossy_link.new(rng, {})
    local clock = { now_ms = function() return link.now() end }
    local quiet = { info = function() end, warn = function() end, error = function() end }
    local cfg = { v = 1, channel = 1, master_id = "M", auth_mode = "enforce", nodes = {} }
    local m_auth = auth_setup.build(cfg, "M", { master = true, fs = master.fs, now_ms = clock.now_ms, logger = quiet })
    local n_auth = auth_setup.build(cfg, "SIG-1", { fs = node.fs, now_ms = clock.now_ms, logger = quiet })
    local m_net = net.new(link.modem("M"), 1, "M", quiet, clock, { auth = m_auth })
    local n_net = net.new(link.modem("SIG-1"), 1, "SIG-1", quiet, clock, { auth = n_auth })
    local heard = 0
    link.set_receiver("M", function(msg) if m_net.receive(msg) == "ok" and msg.payload.type == "sensor" then heard = heard + 1; m_net.ack_for(msg, true) end end)
    link.set_receiver("SIG-1", function(msg) n_net.receive(msg) end)
    n_net.send_reliable("event", "M", { type = "sensor" })
    for _ = 1, 20 do link.advance(50); m_net.tick(); n_net.tick() end
    link.close()
    assert(heard == 1, "heard " .. heard)
    assert(next(n_net.pending) == nil)
  end,

  test_install_refuses_the_file_of_another_computer_and_a_missing_file = function()
    local master = computer(true, { "zufall" })
    master.run("init")
    master.run("issue", "SIG-1")
    local node = computer(true, { "j" })
    carry(master, node)
    assert(node.run("install", "--id", "SIG-2") == 1)
    assert(node.output():find("Keine Schluesseldatei", 1, true))
    assert(keystore.load_node(nil, { fs = node.fs }) == nil)
    local empty = computer(false)
    assert(empty.run("install", "--id", "SIG-1") == 1)
  end,

  test_install_asks_before_it_writes_and_nothing_changes_on_no = function()
    local master = computer(true, { "zufall" })
    master.run("init")
    master.run("issue", "SIG-1")
    local node = computer(true, { "n" })
    carry(master, node)
    assert(node.run("install", "--id", "SIG-1") == 1)
    assert(keystore.load_node(nil, { fs = node.fs }) == nil)
  end,

  test_a_key_can_also_be_typed = function()
    local master = computer(false, { "zufall" })
    master.run("init")
    master.run("issue", "SIG-1")
    local text = master.output()
    local grouped = text:match("Schluessel: ([%x ]+)")
    local epoch = text:match("Nummer:%s+(%d+)")
    assert(grouped and epoch, text)
    local node = computer(false, { "j" })
    assert(node.run("install", "--id", "SIG-1", "--key", grouped, "--epoch", epoch) == 0)
    local record = keystore.load_node(nil, { fs = node.fs })
    assert(record and record.key == grouped:gsub(" ", ""))
    -- wrong input
    assert(computer(false).run("install", "--id", "SIG-1", "--key", "abc", "--epoch", "1") == 1)
    assert(computer(false).run("install", "--id", "SIG-1", "--key", string.rep("a", 64), "--epoch", "0") == 1)
  end,

  test_revoke_and_list = function()
    local master = computer(false, { "zufall" })
    master.run("init")
    master.run("issue", "SIG-1", "--role", "signal")
    master.run("issue", "SIG-2", "--role", "sensor")
    assert(master.run("revoke", "SIG-1") == 0)
    master.said = {}
    assert(master.run("list") == 0)
    local text = master.output()
    assert(text:find("SIG-1", 1, true) and text:find("GESPERRT", 1, true) and text:find("SIG-2", 1, true) and text:find("aktiv", 1, true))
    assert(master.run("revoke", "NOBODY") == 1)
    assert(master.run("revoke") == 1)
  end,

  test_the_second_master_takes_over_key_and_list_after_comparing_the_fingerprint = function()
    local first = computer(true, { "zufall" })
    first.run("init")
    first.run("issue", "SIG-1")
    assert(first.run("export-master") == 0)
    local second = computer(true, { "j" })
    carry(first, second)
    assert(second.run("import-master") == 0)
    local a = keystore.load_master(nil, { fs = first.fs })
    local b = keystore.load_master(nil, { fs = second.fs })
    assert(a.key == b.key)
    assert(keystore.load_trust(nil, { fs = second.fs }).nodes["SIG-1"].status == "active")
    -- a second master with another key keeps it
    local other = computer(true, { "zufall", "j" })
    other.run("init")
    carry(first, other)
    assert(other.run("import-master") == 1)
    assert(keystore.load_master(nil, { fs = other.fs }).key ~= a.key)
    -- no disk at all
    assert(computer(false).run("export-master") == 1)
    -- answer "no" to the fingerprint question
    local careful = computer(true, { "n" })
    carry(first, careful)
    assert(careful.run("import-master") == 1)
    assert(keystore.load_master(nil, { fs = careful.fs }) == nil)
  end,

  test_status_never_prints_a_key = function()
    local master = computer(false, { "zufall" })
    master.run("init")
    master.run("issue", "SIG-1")
    local secret = keystore.load_master(nil, { fs = master.fs }).key
    master.said = {}
    master.env.config = { auth_mode = "monitor" }
    assert(master.run("status") == 0)
    assert(master.output():find("monitor", 1, true))
    assert(not master.output():find(secret, 1, true))
    local node = computer(false, { "j" })
    node.run("install", "--id", "SIG-1", "--key", string.rep("ab", 32), "--epoch", "2")
    node.said = {}
    node.run("status")
    assert(node.output():find("Nummer 2", 1, true) and not node.output():find(string.rep("ab", 32), 1, true))
  end
}
