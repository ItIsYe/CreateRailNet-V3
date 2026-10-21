--[[
Purpose: Builds the authentication of a computer from its config and its key files, so every role starts it the same way (Kap. 12).
Public API: build(config, node_id, opts) -> auth | nil (nil when config.auth_mode is off or missing), OPEN_EVENTS, OPEN_CMDS.
  opts: master (true on a master computer), logger, now_ms, entropy, fs, paths { node, master, trust }, load_trust (function) for tests.
Notes: config.auth_mode: "off" (nothing is signed or checked; the default of a plan that does not mention it), "monitor" (messages are signed and checked and
  failures are counted and logged, nothing is refused: for the first hours after keys were handed out) or "enforce" (a message without a valid MAC is dropped).
  config.masters lists the ids of the master computers (default: config.master_id). Only the open message types may arrive without a MAC: a computer that is
  not yet part of the net has to be able to say that it exists (pair_announce, pair_probe, plan_get), and the answers to those (pair_state, plan_part) are
  checked by what they carry, not by a key (docs/protocol.md).
  A computer in mode monitor / enforce without a usable key file still starts: it signs nothing and refuses everything that needs a MAC, and says so in
  its log once, so a missing key shows up as "node unreachable" and not as a crash loop.
]]

local auth = require("src.shared.auth")
local keyring = require("src.shared.keyring")
local keystore = require("src.shared.keystore")
local time = require("src.shared.time")

local auth_setup = {}

auth_setup.OPEN_EVENTS = { pair_announce = true, pair_probe = true, plan_get = true }
auth_setup.OPEN_CMDS = { pair_state = true, plan_part = true }

local MODES = { off = true, monitor = true, enforce = true }
auth_setup.MODES = MODES

function auth_setup.build(config, node_id, opts)
  opts = opts or {}
  local mode = config and config.auth_mode or "off"
  if not MODES[mode] then mode = "enforce" end -- an unknown word must not switch the protection off
  if mode == "off" then return nil end
  local logger = opts.logger
  local paths = opts.paths or {}
  local masters = {}
  for _, id in ipairs(config.masters or {}) do masters[#masters + 1] = id end
  if config.master_id then masters[#masters + 1] = config.master_id end
  local ring
  if opts.master then
    local master_record, master_err = keystore.load_master(paths.master, { fs = opts.fs })
    local trust, trust_err
    if opts.load_trust then trust, trust_err = opts.load_trust() else trust, trust_err = keystore.load_trust(paths.trust, { fs = opts.fs }) end
    if master_record and trust then
      ring = keyring.master({ id = node_id, master_key = master_record.key, trust = trust, masters = masters })
    elseif logger then
      logger.error("authentication: master key or trust list unusable", { master = master_err, trust = trust_err })
    end
  else
    local record, err = keystore.load_node(paths.node, { fs = opts.fs })
    if record and record.id == node_id then
      ring = keyring.node({ id = node_id, key = record.key, epoch = record.epoch, masters = masters })
    elseif logger then
      logger.warn("authentication: no usable key file for this computer", { error = err or "key file belongs to " .. tostring(record and record.id) })
    end
  end
  ring = ring or (opts.master and keyring.master({ id = node_id, master_key = nil, trust = { nodes = {} }, masters = masters }) or keyring.node({ id = node_id, masters = masters }))
  local instance = auth.new({
    node_id = node_id, mode = mode, keyring = ring, now_ms = opts.now_ms or time.now_ms, entropy = opts.entropy, logger = logger,
    open_events = auth_setup.OPEN_EVENTS, open_cmds = auth_setup.OPEN_CMDS
  })
  instance.keyring_kind = ring.kind
  return instance
end

return auth_setup
