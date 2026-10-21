--[[
Purpose: Key files, issuing and revoking keys, handing a key over on a disk, and the key rules of the keyring (Gesamtkonzept Kap. 12.1).
Public API: returns table of tests.
]]

pcall(dofile, "tests/harness/cc_bootstrap.lua")

local keystore = require("src.shared.keystore")
local keyring = require("src.shared.keyring")
local memfs = require("tests.harness.memfs")

local MASTER_KEY = string.rep("ab", 32)

return {
  test_node_key_file_roundtrip_and_refusals = function()
    local fs = memfs.new()
    local record = { id = "SIG-1", key = string.rep("0f", 32), epoch = 3, issuer = "1234-5678-9abc" }
    assert(keystore.save_node(record, "state/crn_key.json", { fs = fs }))
    local loaded = assert(keystore.load_node("state/crn_key.json", { fs = fs }))
    assert(loaded.id == "SIG-1" and loaded.key == record.key and loaded.epoch == 3 and loaded.issuer == "1234-5678-9abc")
    local body = keystore.node_body(record)
    for _, bad in ipairs({ "", "nonsense", "{}", '{"v":2}', '{"v":1,"id":"A","key":"short","epoch":1}', '{"v":1,"id":"A","key":"' .. string.rep("zz", 32) .. '","epoch":1}',
      '{"v":1,"id":"A","key":"' .. string.rep("ab", 32) .. '","epoch":0}', '{"v":1,"id":"A","key":"' .. string.rep("ab", 32) .. '","epoch":1.5}', '{"v":1,"key":"' .. string.rep("ab", 32) .. '","epoch":1}' }) do
      assert(not keystore.parse_node_body(bad), "accepted: " .. bad)
    end
    assert(not keystore.parse_node_body(body, "SIG-2"), "a key file for another computer must be refused")
    local text, err = keystore.parse_node_body(body, "SIG-2")
    assert(text == nil and err:find("SIG-1", 1, true) and err:find("SIG-2", 1, true))
    assert(keystore.parse_node_body(body, "SIG-1"))
  end,

  test_a_damaged_key_file_is_an_error_and_a_missing_one_is_read_from_the_backup = function()
    local fs = memfs.new()
    local first = { id = "SIG-1", key = string.rep("11", 32), epoch = 1 }
    local second = { id = "SIG-1", key = string.rep("22", 32), epoch = 2 }
    assert(keystore.save_node(first, "state/crn_key.json", { fs = fs }))
    assert(keystore.save_node(second, "state/crn_key.json", { fs = fs }))
    -- a write that was interrupted between its steps leaves the previous file only: that one is read
    local current = fs.files["state/crn_key.json"]
    fs.files["state/crn_key.json"] = nil
    assert(keystore.load_node("state/crn_key.json", { fs = fs }).epoch == 1)
    -- a file that exists but is damaged is never replaced by guesswork
    fs.files["state/crn_key.json"] = "{ damaged"
    local record, err = keystore.load_node("state/crn_key.json", { fs = fs })
    assert(record == nil and err)
    fs.files["state/crn_key.json"] = current
    assert(keystore.load_node("state/crn_key.json", { fs = fs }).epoch == 2)
  end,

  test_issuing_gives_a_key_that_only_the_master_can_check_and_raises_the_epoch = function()
    local trust = { rev = 0, nodes = {} }
    local first = assert(keystore.issue(trust, MASTER_KEY, "SIG-1", "signal", 100))
    assert(first.epoch == 1 and trust.nodes["SIG-1"].epoch == 1 and trust.nodes["SIG-1"].status == "active" and trust.nodes["SIG-1"].role == "signal")
    assert(first.key == keyring.derive_node_key(MASTER_KEY, "SIG-1", 1))
    assert(first.issuer == keyring.fingerprint(MASTER_KEY))
    local second = assert(keystore.issue(trust, MASTER_KEY, "SIG-1", "signal", 200))
    assert(second.epoch == 2 and second.key ~= first.key)
    local other = assert(keystore.issue(trust, MASTER_KEY, "SIG-2", "signal", 200))
    assert(other.key ~= second.key and other.epoch == 1)
    assert(not keystore.issue(trust, MASTER_KEY, "", "signal", 0))
    assert(not keystore.issue(trust, MASTER_KEY, string.rep("x", 40), "signal", 0))
  end,

  test_revoking_marks_the_entry_and_reissuing_activates_it_again_with_a_new_key = function()
    local trust = { rev = 0, nodes = {} }
    local first = keystore.issue(trust, MASTER_KEY, "SIG-1", "signal", 1)
    assert(keystore.revoke(trust, "SIG-1"))
    assert(trust.nodes["SIG-1"].status == "revoked")
    local ring = keyring.master({ id = "M", master_key = MASTER_KEY, trust = trust, masters = { "M" } })
    local key, reason = ring.pair_key("SIG-1", "M", 1)
    assert(key == nil and reason == "revoked")
    local second = keystore.issue(trust, MASTER_KEY, "SIG-1", "signal", 2)
    assert(second.key ~= first.key and trust.nodes["SIG-1"].status == "active")
    assert(ring.pair_key("SIG-1", "M", 1) == nil, "the old key epoch is stale")
    assert(select(2, ring.pair_key("SIG-1", "M", 1)) == "stale_key")
    assert(ring.pair_key("SIG-1", "M", 2) == second.key)
    assert(not keystore.revoke(trust, "NOBODY"))
  end,

  test_trust_list_roundtrip_and_a_damaged_list_is_an_error_not_an_empty_list = function()
    local fs = memfs.new()
    local empty = assert(keystore.load_trust("state/crn_trust.json", { fs = fs }))
    assert(next(empty.nodes) == nil, "no file: nobody has a key yet")
    local trust = { rev = 0, nodes = {} }
    keystore.issue(trust, MASTER_KEY, "SIG-1", "signal", 1)
    keystore.issue(trust, MASTER_KEY, "SIG-2", "sensor", 1)
    keystore.revoke(trust, "SIG-2")
    assert(keystore.save_trust(trust, "state/crn_trust.json", { fs = fs }))
    local loaded = assert(keystore.load_trust("state/crn_trust.json", { fs = fs }))
    assert(loaded.rev == 1 and loaded.nodes["SIG-1"].status == "active" and loaded.nodes["SIG-2"].status == "revoked")
    -- both copies damaged: an error, never "nobody is revoked"
    fs.files["state/crn_trust.json"] = "garbage"
    fs.files["state/crn_trust.json.prev"] = "garbage"
    local result, err = keystore.load_trust("state/crn_trust.json", { fs = fs })
    assert(result == nil and err, "a damaged trust list must not read as an empty one")
  end,

  test_entries_of_a_hand_edited_trust_list_are_cleaned = function()
    local fs = memfs.new()
    fs.set("state/crn_trust.json", '{"rev":2,"nodes":{"A":{"epoch":1,"status":"active"},"B":{"epoch":0,"status":"active"},"C":{"epoch":2,"status":"maybe"},"D":"x"}}')
    local loaded = assert(keystore.load_trust("state/crn_trust.json", { fs = fs }))
    assert(loaded.nodes.A and not loaded.nodes.B and not loaded.nodes.C and not loaded.nodes.D)
  end,

  test_master_key_file_roundtrip_and_validation = function()
    local fs = memfs.new()
    assert(keystore.save_master({ key = MASTER_KEY }, "state/crn_master_key.json", { fs = fs }))
    assert(keystore.load_master("state/crn_master_key.json", { fs = fs }).key == MASTER_KEY)
    fs.files["state/crn_master_key.json"] = '{"v":1,"key":"short"}'
    fs.files["state/crn_master_key.json.prev"] = nil
    assert(not keystore.load_master("state/crn_master_key.json", { fs = fs }))
  end,

  test_new_master_keys_are_valid_and_differ = function()
    local a = keystore.new_master_key("typed by the operator")
    local b = keystore.new_master_key("typed by the operator")
    assert(keyring.valid_key(a) and keyring.valid_key(b) and a ~= b)
  end,

  test_fingerprint_is_stable_short_and_not_the_secret = function()
    local fp = keyring.fingerprint(MASTER_KEY)
    assert(fp:match("^%x%x%x%x%-%x%x%x%x%-%x%x%x%x$"))
    assert(fp == keyring.fingerprint(MASTER_KEY))
    assert(fp ~= keyring.fingerprint(string.rep("cd", 32)))
    assert(not MASTER_KEY:find(fp:gsub("-", ""), 1, true))
  end,

  test_a_plain_computer_only_has_a_key_for_the_masters = function()
    local ring = keyring.node({ id = "SIG-1", key = string.rep("0f", 32), epoch = 2, masters = { "MA", "MB" } })
    assert(ring.pair_key("SIG-1", "MA", 2) and ring.pair_key("MB", "SIG-1", 2))
    assert(ring.pair_key("SIG-1", "broadcast"))
    assert(not ring.pair_key("broadcast", "SIG-1"))
    assert(select(2, ring.pair_key("SIG-1", "SIG-2")) == "unknown_peer", "no key to talk to another node")
    assert(select(2, ring.pair_key("SIG-2", "MA")) == "not_mine")
    assert(select(2, ring.pair_key("SIG-1", "MA", 1)) == "stale_key")
    local keyless = keyring.node({ id = "SIG-1", masters = { "MA" } })
    assert(select(2, keyless.pair_key("SIG-1", "MA")) == "no_key")
  end,

  test_a_master_derives_node_keys_and_keeps_links_between_masters_apart = function()
    local trust = { rev = 0, nodes = {} }
    keystore.issue(trust, MASTER_KEY, "SIG-1", "signal", 1)
    local a = keyring.master({ id = "MA", master_key = MASTER_KEY, trust = trust, masters = { "MA", "MB" } })
    local b = keyring.master({ id = "MB", master_key = MASTER_KEY, trust = trust, masters = { "MA", "MB" } })
    assert(a.pair_key("SIG-1", "MA", 1) == b.pair_key("MB", "SIG-1", 1), "both masters derive the same key for a node")
    assert(a.pair_key("MA", "MB") == b.pair_key("MB", "MA"))
    assert(a.pair_key("MA", "MB") ~= a.pair_key("SIG-1", "MA", 1))
    assert(select(2, a.pair_key("UNKNOWN", "MA")) == "unknown_peer")
    assert(select(2, a.pair_key("MA", "broadcast")) == "unknown_peer")
    assert(select(2, a.pair_key("SIG-1", "MB")) == "not_mine")
    assert(a.epoch_for("SIG-1") == 1 and a.epoch_for("MB") == nil)
  end,

  test_key_files_on_disks_are_found_by_name_and_computer = function()
    local fs = memfs.new()
    fs.set("disk/crn_key_SIG-1.json", "x")
    fs.set("disk2/crn_key.json", "y")
    fs.set("disk3/other.txt", "z")
    local mounts = { drive_0 = "disk", drive_1 = "disk2", drive_2 = "disk3", modem_0 = "none" }
    local api = {
      getNames = function() return { "drive_2", "modem_0", "drive_0", "drive_1" } end,
      getType = function(name) return name:match("^drive") and "drive" or "modem" end,
      call = function(name, method) assert(method == "getMountPath"); return mounts[name] end
    }
    local found = keystore.find_disk_files(fs, api, "SIG-1")
    assert(#found == 2 and found[1] == "disk/crn_key_SIG-1.json" and found[2] == "disk2/crn_key.json", table.concat(found, ","))
    assert(#keystore.find_disk_files(fs, nil, "SIG-1") == 0)
    assert(#keystore.find_disk_files(fs, { getNames = function() error("boom") end }, "SIG-1") == 0)
  end
}
