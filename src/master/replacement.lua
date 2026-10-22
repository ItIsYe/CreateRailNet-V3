--[[
Purpose: The replacement wizard for a computer that was exchanged: new identity, new key, renewed peripheral binding, a test, then back into operation (Gesamtkonzept Kap. 14, Pruefplan I-11).
Public API: new({ trust, master_key, plan (config with nodes), now, on_hold(node_id), on_release(node_id), keystore }) -> wizard.
  wizard.begin(old_id, operator) -> true | nil, err        the old key is revoked, the node is held (its blocks are not trusted)
  wizard.adopt(old_id, new_id, operator, seen_fingerprint) -> node record | nil, err      the new computer gets a key; the operator typed the fingerprint he saw on the master screen
  wizard.bindings_confirmed(old_id, confirmed_signal_ids, operator) -> true | nil, err      every signal the old computer hosted has a confirmed binding on the new one
  wizard.finish(old_id, operator, test) -> true | nil, err      test = { ok = true, source = text }; only then the hold ends
  wizard.state_of(old_id) -> { state, new_id, missing }       states: WAIT_NEW_COMPUTER, WAIT_BINDINGS, WAIT_TEST, DONE
Rules: a replaced computer never keeps its old key (revoked at begin); the new key is issued by the master, so the new computer has its own identity even when it takes the old name (the key epoch rises);
  an automatic rebinding of peripherals is not done: the signals of the old computer count as bound only when the operator confirmed each one on the new computer (src/shared/signal_bindings.lua);
  the hold ends only with a passed test that names its source. A step out of order is refused. The plan entry of the node (new id) is changed by the operator in the plan; the wizard checks that the new id exists there or equals the old one.
]]

local keystore_default = require("src.shared.keystore")
local keyring = require("src.shared.keyring")

local replacement = {}

function replacement.new(opts)
  opts = opts or {}
  local keystore = opts.keystore or keystore_default
  local now = opts.now or function() return 0 end
  local records = {}
  local self = {}

  local function node_entry(id)
    for _, node in ipairs((opts.plan and opts.plan.nodes) or {}) do if node.id == id then return node end end
    return nil
  end

  local function hosted(entry)
    if not entry then return {} end
    if type(entry.signals) == "table" and #entry.signals > 0 then return entry.signals end
    if entry.role == "signal" then return { entry.id } end
    return {}
  end

  function self.begin(old_id, operator)
    if type(operator) ~= "string" or operator == "" then return nil, "operator missing" end
    local entry = node_entry(old_id)
    if not entry then return nil, "the plan has no computer " .. tostring(old_id) end
    if entry.role == "master" then return nil, "a master is replaced with the master update procedure (docs/HA.md), not here" end
    local ok, err = keystore.revoke(opts.trust, old_id)
    if not ok then return nil, err end
    records[old_id] = { state = "WAIT_NEW_COMPUTER", role = entry.role, operator = operator, started = now() }
    if opts.on_hold then opts.on_hold(old_id) end
    return true
  end

  function self.adopt(old_id, new_id, operator, seen_fingerprint)
    local rec = records[old_id]
    if not rec or rec.state ~= "WAIT_NEW_COMPUTER" then return nil, "no replacement waiting for a new computer for " .. tostring(old_id) end
    if type(operator) ~= "string" or operator == "" then return nil, "operator missing" end
    if new_id ~= old_id and not node_entry(new_id) then return nil, "the new id " .. tostring(new_id) .. " is not in the plan: enter it in the plan first" end
    if new_id ~= old_id and opts.trust.nodes[new_id] and opts.trust.nodes[new_id].status == "active" then return nil, "the id " .. tostring(new_id) .. " already has an active key" end
    local record, err = keystore.issue(opts.trust, opts.master_key, new_id, rec.role, now())
    if not record then return nil, err end
    -- the operator compares what the master shows with what he typed from the screen of the new computer
    if seen_fingerprint ~= keyring.fingerprint(record.key) then
      keystore.revoke(opts.trust, new_id)
      return nil, "the fingerprint does not match: the key was withdrawn again"
    end
    rec.state, rec.new_id = "WAIT_BINDINGS", new_id
    return record
  end

  function self.bindings_confirmed(old_id, confirmed, operator)
    local rec = records[old_id]
    if not rec or rec.state ~= "WAIT_BINDINGS" then return nil, "no replacement waiting for bindings for " .. tostring(old_id) end
    if type(operator) ~= "string" or operator == "" then return nil, "operator missing" end
    local have = {}
    for _, id in ipairs(confirmed or {}) do have[id] = true end
    local missing = {}
    for _, id in ipairs(hosted(node_entry(old_id))) do if not have[id] then missing[#missing + 1] = id end end
    rec.missing = missing
    if #missing > 0 then return nil, "not confirmed on the new computer: " .. table.concat(missing, ", ") end
    rec.state = "WAIT_TEST"
    return true
  end

  function self.finish(old_id, operator, test)
    local rec = records[old_id]
    if not rec or rec.state ~= "WAIT_TEST" then return nil, "no replacement waiting for a test for " .. tostring(old_id) end
    if type(operator) ~= "string" or operator == "" then return nil, "operator missing" end
    if type(test) ~= "table" or test.ok ~= true or type(test.source) ~= "string" or test.source == "" then return nil, "a passed test with its source is needed" end
    rec.state = "DONE"
    if opts.on_release then opts.on_release(old_id) end
    return true
  end

  function self.state_of(old_id)
    local rec = records[old_id]
    if not rec then return nil end
    return { state = rec.state, new_id = rec.new_id, missing = rec.missing }
  end

  return self
end

return replacement
