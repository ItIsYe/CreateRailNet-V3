--[[
Purpose: Puts the replacement wizard together for a master: the key and trust files, saving the list of keys after every change, and the hand-over of a new key on a disk (Gesamtkonzept Kap. 14, Pruefplan I-11).
Public API: build({ config, fs, peripheral, now, on_hold, on_release, paths }) -> setup | nil, why
  setup.wizard                        the replacement wizard (src/master/replacement.lua)
  setup.handover(record) -> true, path | nil, err      writes the key file of a new computer to the disk in a drive; a key never leaves this computer over the network
Notes: nil when this master has no master key or no list of keys (authentication is off or not set up). Every change of the list is written at once (the trust revision rises, a running master picks the list up
  within seconds, src/shared/auth_setup.lua); a list that cannot be written is a failure and the change is taken back, so what the master believes and what is on the disk never differ.
  The key file is written next to nothing else: only to a disk, never into state/ and never into a message.
]]

local keystore = require("src.shared.keystore")
local replacement = require("src.master.replacement")

local replacement_setup = {}

local function copy_trust(trust)
  local out = { rev = trust.rev, nodes = {} }
  for id, entry in pairs(trust.nodes) do
    local e = {}
    for k, v in pairs(entry) do e[k] = v end
    out.nodes[id] = e
  end
  return out
end

function replacement_setup.build(opts)
  local paths = opts.paths or {}
  local master_path, trust_path = paths.master or keystore.MASTER_PATH, paths.trust or keystore.TRUST_PATH
  local io_opts = { fs = opts.fs }
  local master_record = keystore.load_master(master_path, io_opts)
  local trust = keystore.load_trust(trust_path, io_opts)
  if not master_record or not trust then return nil, "no master key or no list of keys" end

  -- the wizard works on the list in memory; a change is written, and taken back when it cannot be written
  local store = {}
  local function persist(change)
    local before = copy_trust(trust)
    local a, b = change()
    local saved, err = keystore.save_trust(trust, trust_path, io_opts)
    if not saved then
      trust.rev, trust.nodes = before.rev, before.nodes
      return nil, "the list of keys could not be written: " .. tostring(err)
    end
    return a, b
  end
  function store.issue(t, key, id, role, now) return persist(function() return keystore.issue(t, key, id, role, now) end) end
  function store.revoke(t, id) return persist(function() return keystore.revoke(t, id) end) end

  local setup = {}
  setup.wizard = replacement.new({ trust = trust, master_key = master_record.key, plan = opts.config, now = opts.now, keystore = store, on_hold = opts.on_hold, on_release = opts.on_release })

  function setup.handover(record)
    local mounts = keystore.drive_mounts(opts.peripheral)
    if #mounts == 0 then return nil, "kein Laufwerk mit Diskette gefunden" end
    local path = mounts[1] .. "/crn_key_" .. record.id .. ".json"
    local fh = opts.fs and opts.fs.open and opts.fs.open(path, "w")
    if not fh then return nil, "die Diskette ist nicht beschreibbar" end
    fh.write(keystore.node_body(record))
    fh.close()
    return true, path
  end

  return setup
end

return replacement_setup
