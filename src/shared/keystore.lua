--[[
Purpose: Key files of a computer and the operations on them: generate the master key, issue and revoke a computer's key, hand a key over (Kap. 12.1).
Public API: NODE_PATH, MASTER_PATH, TRUST_PATH; load_node(path) / save_node(record, path), load_master(path) / save_master(record, path),
  load_trust(path) / save_trust(trust, path), new_master_key(entropy_text) -> hex, issue(trust, master_key, id, role, now) -> node record,
  revoke(trust, id) -> ok, err, node_body(record) -> json text, parse_node_body(text, expect_id) -> record | nil, err, find_disk_files(fs, peripheral, id) -> list.
Notes: files are written with shared.safe_write. A key is never logged: callers print fingerprints (keyring.fingerprint), not keys.
  Records: node { id, key (64 hex), epoch, issuer (fingerprint of the master key) }; master { key (64 hex) }; trust { rev, nodes = { [id] = { epoch, status, role, issued } } }.
  The trust list is shared by both masters (the operator hands it over together with the master key, later the dual-commit replicates it).
  The files lie in state/, which no update, installer or diagnostic export touches or reads out.
]]

local json = require("src.shared.json")
local safe_write = require("src.shared.safe_write")
local sha256 = require("src.shared.sha256")
local keyring = require("src.shared.keyring")

local keystore = {}

keystore.NODE_PATH = "state/crn_key.json"
keystore.MASTER_PATH = "state/crn_master_key.json"
keystore.TRUST_PATH = "state/crn_trust.json"

local MAX_ID = 32

local function read_json(path, opts)
  local body, err = safe_write.read_with_backup(path, opts)
  if not body then return nil, err end
  local ok, decoded = pcall(json.decode, body)
  if not ok or type(decoded) ~= "table" then return nil, "not valid json" end
  return decoded
end

local function write_json(path, value, opts)
  return safe_write.write(path, json.encode(value), opts)
end

local function sane_id(id) return type(id) == "string" and id ~= "" and #id <= 64 end

function keystore.parse_node_body(text, expect_id)
  local ok, decoded = pcall(json.decode, text or "")
  if not ok or type(decoded) ~= "table" then return nil, "Die Datei ist keine Schluesseldatei." end
  if decoded.v ~= 1 then return nil, "Unbekannte Version der Schluesseldatei." end
  if not sane_id(decoded.id) then return nil, "Die Schluesseldatei nennt keinen Computer." end
  if expect_id and decoded.id ~= expect_id then
    return nil, "Die Schluesseldatei gehoert zu " .. decoded.id .. ", dieser Computer ist " .. tostring(expect_id) .. "."
  end
  if not keyring.valid_key(decoded.key) then return nil, "Der Schluessel in der Datei ist nicht gueltig." end
  if type(decoded.epoch) ~= "number" or decoded.epoch < 1 or decoded.epoch ~= math.floor(decoded.epoch) then return nil, "Die Schluesselnummer in der Datei ist nicht gueltig." end
  return { id = decoded.id, key = decoded.key, epoch = decoded.epoch, issuer = type(decoded.issuer) == "string" and decoded.issuer or nil }
end

function keystore.node_body(record)
  return json.encode({ v = 1, id = record.id, key = record.key, epoch = record.epoch, issuer = record.issuer })
end

function keystore.load_node(path, opts)
  local body, err = safe_write.read_with_backup(path or keystore.NODE_PATH, opts)
  if not body then return nil, err end
  return keystore.parse_node_body(body)
end

function keystore.save_node(record, path, opts)
  return safe_write.write(path or keystore.NODE_PATH, keystore.node_body(record), opts)
end

function keystore.load_master(path, opts)
  local decoded, err = read_json(path or keystore.MASTER_PATH, opts)
  if not decoded then return nil, err end
  if decoded.v ~= 1 or not keyring.valid_key(decoded.key) then return nil, "master key file is not valid" end
  return { key = decoded.key }
end

function keystore.save_master(record, path, opts)
  return write_json(path or keystore.MASTER_PATH, { v = 1, key = record.key }, opts)
end

local function clean_trust(decoded)
  local trust = { rev = tonumber(decoded.rev) or 0, nodes = {} }
  for id, entry in pairs(type(decoded.nodes) == "table" and decoded.nodes or {}) do
    if sane_id(id) and type(entry) == "table" and type(entry.epoch) == "number" and entry.epoch >= 1 and (entry.status == "active" or entry.status == "revoked") then
      trust.nodes[id] = { epoch = entry.epoch, status = entry.status, role = type(entry.role) == "string" and entry.role or nil, issued = tonumber(entry.issued) }
    end
  end
  return trust
end

-- a missing file is an empty list (nobody has a key yet); a damaged one is an error and must not be read as "nobody is revoked"
function keystore.load_trust(path, opts)
  local body, err = safe_write.read_with_backup(path or keystore.TRUST_PATH, opts)
  if not body then
    if err == "missing" then return { rev = 0, nodes = {} } end
    return nil, err
  end
  local ok, decoded = pcall(json.decode, body)
  if not ok or type(decoded) ~= "table" then return nil, "trust list is not valid json" end
  return clean_trust(decoded)
end

function keystore.save_trust(trust, path, opts)
  trust.rev = (trust.rev or 0) + 1
  return write_json(path or keystore.TRUST_PATH, trust, opts)
end

-- the master key: 32 bytes from everything the computer can offer plus what the operator typed. Lua cannot do better than that (risk R-05).
function keystore.new_master_key(entropy_text)
  local parts = { tostring(entropy_text or ""), tostring(os.clock and os.clock() or 0), tostring(os.time and os.time() or 0) }
  if os.epoch then parts[#parts + 1] = tostring(os.epoch("utc")) end
  if os.getComputerID then parts[#parts + 1] = tostring(os.getComputerID()) end
  if math.random then
    for _ = 1, 32 do parts[#parts + 1] = tostring(math.random(0, 2147483646)) end
  end
  parts[#parts + 1] = tostring({}) -- an address differs between runs
  return sha256.hex(table.concat(parts, "|"))
end

-- gives the computer a key (a new one when it had one: the old one stops working at once). The trust list is changed, the caller saves it.
function keystore.issue(trust, master_key, id, role, now)
  if not sane_id(id) or #id > MAX_ID then return nil, "Ungueltige Computer-ID." end
  local entry = trust.nodes[id]
  local epoch = (entry and entry.epoch or 0) + 1
  trust.nodes[id] = { epoch = epoch, status = "active", role = role, issued = now }
  return { id = id, key = keyring.derive_node_key(master_key, id, epoch), epoch = epoch, issuer = keyring.fingerprint(master_key) }
end

function keystore.revoke(trust, id)
  local entry = trust.nodes[id]
  if not entry then return false, "Dieser Computer hat keinen Schluessel." end
  entry.status = "revoked"
  return true
end

-- key files on disks in attached drives (the way a key travels from the master to a computer): <mount>/crn_key_<id>.json or <mount>/crn_key.json
function keystore.find_disk_files(fsys, peripheral_api, id)
  local found = {}
  if not (fsys and peripheral_api and peripheral_api.getNames) then return found end
  local ok, names = pcall(peripheral_api.getNames)
  if not ok or type(names) ~= "table" then return found end
  table.sort(names)
  for _, name in ipairs(names) do
    local type_ok, kind = pcall(peripheral_api.getType, name)
    if type_ok and kind == "drive" then
      local mount_ok, mount = pcall(peripheral_api.call, name, "getMountPath")
      if mount_ok and type(mount) == "string" then
        for _, file in ipairs({ "crn_key_" .. tostring(id) .. ".json", "crn_key.json" }) do
          local path = mount .. "/" .. file
          if fsys.exists(path) then found[#found + 1] = path end
        end
      end
    end
  end
  return found
end

return keystore
