--[[
Purpose: The replacement wizard on a master: the list of keys is written after every change and taken back when it cannot be written, the new key goes only to a disk (Pruefplan I-11, F-08).
Public API: returns table of tests.
]]

local replacement_setup = require("src.master.replacement_setup")
local keystore = require("src.shared.keystore")
local keyring = require("src.shared.keyring")
local memfs = require("tests.harness.memfs")

local MASTER_KEY = string.rep("3c", 32)
local PLAN = { nodes = { { id = "MASTER-1", role = "master" }, { id = "SIG-1", role = "signal", signals = { "S-A" } } } }

local function world(drive)
  local w = { fs = memfs.new(), held = {}, released = {} }
  keystore.save_master({ key = MASTER_KEY }, nil, { fs = w.fs })
  local trust = { rev = 0, nodes = {} }
  keystore.issue(trust, MASTER_KEY, "SIG-1", "signal", 1)
  keystore.save_trust(trust, nil, { fs = w.fs })
  w.peripheral = {
    getNames = function() return drive and { "drive_0" } or {} end,
    getType = function() return "drive" end,
    call = function(_, method) if method == "getMountPath" then return "disk" end end
  }
  w.setup = assert(replacement_setup.build({ config = PLAN, fs = w.fs, peripheral = w.peripheral, now = function() return 5 end,
    on_hold = function(id) w.held[#w.held + 1] = id end, on_release = function(id) w.released[#w.released + 1] = id end }))
  function w.trust() return keystore.load_trust(nil, { fs = w.fs }) end
  return w
end

return {
  test_there_is_no_wizard_without_a_master_key_and_a_list = function()
    local fs = memfs.new()
    local setup, why = replacement_setup.build({ config = PLAN, fs = fs })
    assert(setup == nil and why:find("no master key", 1, true))
  end,

  test_beginning_a_replacement_revokes_the_old_key_on_disk_at_once = function()
    local w = world(true)
    assert(w.setup.wizard.begin("SIG-1", "ED"))
    assert(w.trust().nodes["SIG-1"].status == "revoked" and w.trust().rev >= 2 and w.held[1] == "SIG-1")
  end,

  test_the_new_key_goes_to_the_disk_and_nowhere_else = function()
    local w = world(true)
    w.setup.wizard.begin("SIG-1", "ED")
    local record, fingerprint = w.setup.wizard.adopt("SIG-1", "ED")
    local ok, path = w.setup.handover(record)
    assert(ok and path == "disk/crn_key_SIG-1.json")
    local text = w.fs.files[path]
    assert(text and text:find(record.key, 1, true), "the file holds the key")
    assert(fingerprint == keyring.fingerprint(record.key))
    for name, body in pairs(w.fs.files) do
      if name ~= path and not name:find("crn_master_key", 1, true) then assert(not body:find(record.key, 1, true), name .. " must not hold the new key") end
    end
    assert(w.trust().nodes["SIG-1"].status == "active" and w.trust().nodes["SIG-1"].epoch == 2)
  end,

  test_no_drive_means_no_key_is_handed_over = function()
    local w = world(false)
    w.setup.wizard.begin("SIG-1", "ED")
    local record = w.setup.wizard.adopt("SIG-1", "ED")
    local ok, err = w.setup.handover(record)
    assert(ok == nil and err:find("Laufwerk", 1, true))
  end,

  test_a_list_that_cannot_be_written_takes_the_change_back = function()
    local w = world(true)
    w.fs.fail.open = "state/crn_trust.json.tmp"
    local ok, err = w.setup.wizard.begin("SIG-1", "ED")
    assert(ok == nil and err:find("could not be written", 1, true), tostring(err))
    assert(w.setup.wizard.state_of("SIG-1") == nil, "no replacement was started")
    assert(w.trust().nodes["SIG-1"].status == "active", "the disk and the memory agree")
    assert(#w.held == 0)
  end
}
