--[[
Purpose: Which key signs and checks the messages between two computers (Gesamtkonzept Kap. 12.1).
Public API: node(opts) -> keyring of a plain computer, master(opts) -> keyring of a master, fingerprint(secret) -> "xxxx-xxxx-xxxx",
  derive_node_key(master_key, id, epoch) -> key (hex), derive_link_key(master_key, id_a, id_b) -> key (hex).
  keyring: pair_key(src, dst, epoch) -> key | nil, reason;  epoch_for(peer) -> key epoch to put into a message to that peer (nil between masters).
  node opts: id, key (64 hex characters), epoch (number), masters (list of master ids); master opts: id, master_key, trust, masters.
Notes: a message between a master and a computer is signed with that computer's own key. The master does not store it: it derives it from its
  master key, the id and the key epoch of the computer's entry in the trust list (trust = { nodes = { [id] = { epoch, status } } }). A computer
  therefore holds one key that is good for nothing but talking to the masters, and a revoked or replaced key is simply a higher epoch (or
  status "revoked") in the list. Both masters share the master key (given by hand from one to the other); between each other they use a
  key derived for that pair. The arbiter is a plain computer with its own key and never learns the master key.
  Nodes talking to nodes directly have no key here (they cannot check each other); their messages are not accepted as authenticated.
]]

local sha256 = require("src.shared.sha256")

local keyring = {}

function keyring.derive_node_key(master_key, id, epoch)
  return sha256.hmac_hex(master_key, "crn1|node|" .. tostring(id) .. "|" .. tostring(epoch))
end

function keyring.derive_link_key(master_key, id_a, id_b)
  local low, high = tostring(id_a), tostring(id_b)
  if high < low then low, high = high, low end
  return sha256.hmac_hex(master_key, "crn1|link|" .. low .. "|" .. high)
end

-- twelve hex characters of a hash of the secret, in groups of four: both ends show it so that the person handing over a key can compare it
function keyring.fingerprint(secret)
  local digest = sha256.hex("crn1|fingerprint|" .. tostring(secret))
  return digest:sub(1, 4) .. "-" .. digest:sub(5, 8) .. "-" .. digest:sub(9, 12)
end

local function id_set(list, extra)
  local set = {}
  for _, id in ipairs(list or {}) do set[id] = true end
  if extra then set[extra] = true end
  return set
end

local function valid_key(key) return type(key) == "string" and #key == 64 and key:match("^%x+$") ~= nil end
keyring.valid_key = valid_key

function keyring.node(opts)
  local self = { kind = "node", id = opts.id }
  local masters = id_set(opts.masters)
  local key, epoch = opts.key, tonumber(opts.epoch)

  function self.epoch_for() return epoch end
  function self.has_key() return valid_key(key) end

  function self.pair_key(src, dst, message_epoch)
    if not valid_key(key) then return nil, "no_key" end
    local peer
    if src == self.id then peer = dst elseif dst == self.id then peer = src else return nil, "not_mine" end
    if peer ~= "broadcast" and not masters[peer] then return nil, "unknown_peer" end
    if peer == "broadcast" and src ~= self.id then return nil, "unknown_peer" end
    if message_epoch ~= nil and message_epoch ~= epoch then return nil, "stale_key" end
    return key
  end
  return self
end

function keyring.master(opts)
  local self = { kind = "master", id = opts.id }
  local masters = id_set(opts.masters, opts.id)
  local master_key = opts.master_key
  local trust = opts.trust or { nodes = {} }

  function self.epoch_for(peer)
    local entry = trust.nodes and trust.nodes[peer]
    return type(entry) == "table" and entry.epoch or nil
  end
  function self.has_key() return valid_key(master_key) end

  -- the trust list is replaced as a whole when the operator issues or revokes a key
  function self.set_trust(new_trust) trust = new_trust or { nodes = {} } end
  function self.entry(id) return trust.nodes and trust.nodes[id] end

  function self.pair_key(src, dst, message_epoch)
    if not valid_key(master_key) then return nil, "no_key" end
    local peer
    if src == self.id then peer = dst
    elseif dst == self.id or dst == "broadcast" then peer = src
    else return nil, "not_mine" end
    if peer == "broadcast" or peer == self.id then return nil, "unknown_peer" end
    if masters[peer] then return keyring.derive_link_key(master_key, self.id, peer) end
    local entry = trust.nodes and trust.nodes[peer]
    if type(entry) ~= "table" then return nil, "unknown_peer" end
    if entry.status ~= "active" then return nil, "revoked" end
    if message_epoch ~= nil and message_epoch ~= entry.epoch then return nil, "stale_key" end
    return keyring.derive_node_key(master_key, peer, entry.epoch)
  end
  return self
end

return keyring
