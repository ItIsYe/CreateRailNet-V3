--[[
Purpose: Common node runtime for register/heartbeat/command handling.
Public API: new(opts) -> node with start(), run(), handle_event(event), handle_message(msg).
  node.ticker runs the periodic jobs (heartbeat built in); roles add theirs with node.ticker.every(name, seconds, fn)
  before start(). opts.clock / opts.start_timer / opts.tick_grace are for tests.
]]

local net = require("src.shared.net")
local log = require("src.shared.log")
local time = require("src.shared.time")
local updater = require("src.shared.updater")
local update_trust = require("src.shared.update_trust")
local ticker = require("src.shared.ticker")
local once_log = require("src.shared.once_log")
local log_forwarder = require("src.shared.log_forwarder")
local setup_status = require("src.shared.setup_status")
local auth_setup = require("src.shared.auth_setup")
local journal_module = require("src.shared.journal")
local storage_budget = require("src.shared.storage_budget")
local idempotency = require("src.shared.idempotency")
local fence_module = require("src.shared.fence")
local ha_module = require("src.shared.ha")
local ha_topology = require("src.shared.ha_topology")

local common_node = {}

local function read_version()
  if fs and fs.exists and fs.exists("crn_version.txt") then
    local fh = fs.open("crn_version.txt", "r")
    if fh then local text = fh.readAll(); fh.close(); return text end
  end
  return "unknown"
end

-- commands with an effect in the world that must not happen twice (a retry after a restart of this computer carries the same message id)
local DURABLE_COMMANDS = { set_schedule = true, depart_authorized = true, dispatch_train = true, apply_schedule = true }
local LEDGER_PATH = "state/node_commands.log"

local OTA_COMMANDS = { ota_offer = "offer", ota_chunk = "chunk", ota_commit = "commit", ota_abort = "abort", ota_update = "apply" }

function common_node.new(opts)
  local node = {
    id = opts.id,
    role = opts.role,
    config = opts.config,
    modem = opts.modem,
    logger = opts.logger or log.new("INFO", 200),
    handlers = opts.handlers or {},
    pull_event = opts.pull_event or os.pullEvent,
    heartbeat_ms = opts.heartbeat_ms or 2000
  }

  -- opts.auth is for tests; otherwise config.auth_mode (off / monitor / enforce) and the key file of this computer decide
  node.auth = opts.auth or auth_setup.build(node.config, node.id, { logger = node.logger, fs = opts.auth_fs, paths = opts.auth_paths })
  -- a plan with two masters: the node reports to both (the standby needs liveness and observations to take over) and takes commands only from the newest leadership.
  -- A node with a short plan learns the masters from its master (pair_state) and remembers them (state/crn_ha.json).
  if node.config.masters == nil then
    local known = ha_topology.load(opts.topology_path, { fs = opts.topology_fs })
    if known and ha_topology.sane(known.masters, known.arbiter, node.config.master_id) then
      node.config.masters, node.config.arbiter = known.masters, known.arbiter
    end
  end
  local mirrors = {}
  local function refresh_mirrors()
    for key in pairs(mirrors) do mirrors[key] = nil end
    local list = node.config.masters or {}
    if #list > 1 and node.config.master_id then
      local others = {}
      for _, id in ipairs(list) do if id ~= node.config.master_id then others[#others + 1] = id end end
      mirrors[node.config.master_id] = others
    end
  end
  refresh_mirrors()
  node.net = net.new(node.modem, node.config.channel, node.id, node.logger, time, { auth = node.auth, mirrors = mirrors })
  node.fence = fence_module.new({ masters = node.config.masters, required = ha_module.is_ha(node.config), fs = opts.fence_fs, path = opts.fence_path })

  -- the master tells which computers are the masters and the arbiter: remembered, and applied at once
  function node.apply_topology(masters, arbiter)
    local ok, why = ha_topology.sane(masters, arbiter, node.config.master_id)
    if not ok then return false, why end
    local same = node.config.masters ~= nil and #node.config.masters == #masters and node.config.arbiter == arbiter
    if same then for i, id in ipairs(masters) do if node.config.masters[i] ~= id then same = false end end end
    if same then return true end
    local saved, err = ha_topology.save(masters, arbiter, opts.topology_path, { fs = opts.topology_fs })
    if not saved then node.logger.warn("high availability: topology not stored", { error = err }) end
    node.config.masters, node.config.arbiter = masters, arbiter
    refresh_mirrors()
    node.fence.set_topology(masters, true)
    node.logger.info("high availability: masters and arbiter learned from the master", { masters = table.concat(masters, ","), arbiter = arbiter })
    if node.on_topology then node.on_topology() end
    return true
  end

  -- durable exactly-once bookkeeping for the commands above: on in the game (config.durable_commands = false switches it off), off in offline tests unless asked for
  -- (opts.ledger = false / true, opts.journal_fs for a test filesystem). The journal sits in state/ and compacts itself.
  do
    local wanted
    if opts.ledger ~= nil then wanted = opts.ledger ~= false
    elseif node.config.durable_commands ~= nil then wanted = node.config.durable_commands == true
    else wanted = rawget(_G, "_HOST") ~= nil end
    if wanted then
      local ledger
      local commands_journal = journal_module.new(opts.journal_path or LEDGER_PATH, {
        fs = opts.journal_fs, max_entries = storage_budget.JOURNAL.node.max_entries, max_bytes = storage_budget.JOURNAL.node.max_bytes, max_snapshot_bytes = storage_budget.SNAPSHOT_MAX_BYTES,
        state_fn = function() return { ledger = ledger and ledger.to_state() or {} } end
      })
      ledger = idempotency.new({ journal = commands_journal, ttl_s = 3600, max = 250 })
      local status, info = commands_journal.open()
      if status == "corrupt" or status == "failed" then
        node.logger.error("command journal unusable: critical commands are refused", { status = status, reason = info and info.reason })
      else
        local recovered = commands_journal.recovered()
        if recovered.state and recovered.state.ledger then ledger.load_state(recovered.state.ledger) end
        ledger.recover(recovered.entries)
        if status == "tail_repaired" then node.logger.warn("command journal: torn end cut off") end
      end
      node.ledger, node.commands_journal = ledger, commands_journal
    end
  end

  node.ticker = ticker.new({
    clock = opts.clock,
    start_timer = opts.start_timer,
    grace = opts.tick_grace,
    on_error = function(name, err, count)
      node.logger.warn("tick job failed", { job = name, error = err, count = count })
    end
  })
  -- pairing (below): asked every few seconds until the master has said that it knows this computer
  node.pair = { state = nil, announced_at = nil }
  node.ticker.every("pair", 5, function()
    local revision = node.net.peer_revision(node.config.master_id)
    if not revision or revision < 3 then return end
    local now = (opts.clock or function() return time.now_ms() / 1000 end)()
    -- not heard back yet: every 20 s; waiting for the operator: every 5 minutes; known: every 10 minutes (the master forgets the
    -- setup record it was told when it restarts, and the operator sees it on the setup page)
    local wait = node.pair.state == "known" and 600 or (node.pair.state and 300 or 20)
    if node.pair.announced_at and now - node.pair.announced_at < wait then return end
    node.pair.announced_at = now
    node.announce()
  end)

  -- node.heartbeat is looked up on every tick because roles replace it after construction
  node.ticker.every("heartbeat", node.heartbeat_ms / 1000, function() node.heartbeat() end)

  -- warnings and errors go to the master's network log in batches (config.log_forward = false switches it off,
  -- config.log_sink names another receiver)
  if node.config.log_forward ~= false then
    node.log_forwarder = log_forwarder.attach(node.logger, function(payload)
      node.net.send("event", node.config.log_sink or node.config.master_id, payload)
    end)
    if node.log_forwarder then node.ticker.every("logs", 5, function() node.log_forwarder.flush() end) end
  end

  function node.register()
    return node.net.send_reliable("register", node.config.master_id, { role = node.role })
  end

  -- Pairing: the node tells the master which entry of the plan it is (and how far its setup got). A master that does not know the
  -- computer shows it to the operator; the answer (cmd pair_state) is kept here and written to the log when it changes.
  -- Asked once the master has shown that it understands it (protocol revision 3), then again now and then (see the job below).
  function node.announce()
    local entry = nil
    for _, candidate in ipairs(node.config.nodes or {}) do if candidate.id == node.id then entry = candidate end end
    local setup = nil
    local ok, status = pcall(setup_status.read)
    if ok and status then setup = { state = status.state, fail = status.fail, warn = status.warn, version = status.version, hw = status.hw } end
    return node.net.send_reliable("event", node.config.master_id, { type = "pair_announce", role = node.role, entry = entry, setup = setup })
  end


  function node.heartbeat()
    return node.net.heartbeat(node.config.master_id, { role = node.role })
  end

  -- Lazy-init updater so it only exists when needed
  local node_updater = nil
  local function get_updater()
    if not node_updater then
      local sources = { node.config.master_id }
      for _, id in ipairs(node.config.ota_sources or { "OTA-TOOL" }) do sources[#sources + 1] = id end
      local ota = opts.ota or {}
      -- with a key the node checks the signed package of an offer; the plan can demand one (ota_require_package), enforced authentication does by default
      local fsys = ota.fs or _G.fs
      local require_package = node.config.ota_require_package
      if require_package == nil then require_package = node.auth ~= nil and node.auth.mode == "enforce" end
      local verify = ota.verify_package
      if not verify and node.auth and node.auth.keyring then
        verify = update_trust.verifier({
          keyring = node.auth.keyring, master_id = node.config.master_id, node_id = node.id, role = node.role, protocol = net.PROTOCOL_REVISION,
          free_space = fsys and fsys.getFreeSpace and function() return fsys.getFreeSpace("/") end or nil, require = require_package
        })
      elseif not verify and require_package then
        verify = function(package) if package == nil then return false, "no_package", "this computer takes only signed update packages" end return false, "no_key", "this computer has no key" end
      end
      node_updater = updater.new(node.net, node.id, node.logger, {
        fs = ota.fs, reboot = ota.reboot, sleep = ota.sleep, sources = sources, verify_package = verify,
        -- roles put their outputs into a known state before the files are swapped (signals: RED)
        quiesce = function()
          if node.handlers.on_quiesce then return node.handlers.on_quiesce() end
          return true
        end
      })
    end
    return node_updater
  end

  -- Outcome of recent commands by message id. A duplicate means the sender never saw our answer: answer again, same outcome,
  -- without running the command twice.
  local outcomes, outcome_count = {}, 0
  local OUTCOME_TTL_MS = 30000
  local OUTCOME_PRUNE_AT = 64

  local function outcome_key(msg) return tostring(msg.src) .. "/" .. tostring(msg.id) end

  local function remember_outcome(msg, ok, err)
    local now = time.now_ms()
    if outcome_count >= OUTCOME_PRUNE_AT then
      outcome_count = 0
      for id, entry in pairs(outcomes) do
        if now - entry.at > OUTCOME_TTL_MS then outcomes[id] = nil else outcome_count = outcome_count + 1 end
      end
    end
    local key = outcome_key(msg)
    if not outcomes[key] then outcome_count = outcome_count + 1 end
    outcomes[key] = { ok = ok ~= false, err = err, at = now }
  end

  -- the command was executed (or refused with an error): this is the "applied" kind of acknowledgement
  local function answer(msg, ok, err)
    if ok == false then
      node.net.send("err", msg.src, { ref_id = msg.id, error = tostring(err) })
    else
      node.net.ack_for(msg, true)
    end
  end

  -- commands steer hardware: only the master (and ids listed in config.cmd_sources) may send them; OTA commands have their own
  -- list in the updater (master_id plus config.ota_sources)
  local source_log = once_log.new(node.logger)
  local function command_allowed(msg, payload)
    if OTA_COMMANDS[payload.cmd] then return true end
    if msg.src == node.config.master_id then return true end
    for _, id in ipairs(node.config.masters or {}) do if id == msg.src then return true end end
    for _, id in ipairs(node.config.cmd_sources or {}) do if id == msg.src then return true end end
    return false
  end

  function node.handle_message(msg)
    local status = node.net.receive(msg)
    if status == "duplicate" and msg.type == "cmd" then
      local previous = outcomes[outcome_key(msg)]
      if previous then answer(msg, previous.ok, previous.err) end
      return status
    end
    if status ~= "ok" or msg.type ~= "cmd" then
      return status
    end

    local payload = msg.payload or {}

    if not command_allowed(msg, payload) then
      source_log.warn("cmd:" .. tostring(msg.src), "command from a sender that is not allowed", { src = msg.src, cmd = payload.cmd })
      node.net.send("err", msg.src, { ref_id = msg.id, error = "source not allowed: " .. tostring(msg.src) })
      return status
    end

    -- the election between the masters and the arbiter (only a role that takes part has node.ha)
    if payload.cmd == "election" then
      if node.ha then node.ha.handle(msg) end
      return status
    end

    -- fencing: a command of a master carries the epoch of its leadership; a lower epoch than the highest seen comes from a leader that was replaced
    if not ha_module.EXEMPT_CMDS[payload.cmd] then
      local is_master = msg.src == node.config.master_id
      for _, id in ipairs(node.config.masters or {}) do if id == msg.src then is_master = true end end
      if is_master then
        local fenced, why = node.fence.check(payload, msg.src)
        if not fenced then
          source_log.warn("fence:" .. tostring(msg.src) .. ":" .. tostring(why), "command refused by the epoch check", { src = msg.src, cmd = payload.cmd, reason = why, epoch = payload.election_epoch, highest = node.fence.epoch() })
          answer(msg, false, "fenced: " .. tostring(why))
          return status
        end
      end
    end

    -- OTA: offer / chunk / commit / abort, or the single-message update of older senders
    local ota_step = OTA_COMMANDS[payload.cmd]
    if ota_step then
      remember_outcome(msg, true)
      node.net.ack_for(msg)
      if payload.cmd ~= "ota_chunk" and node.logger then node.logger.info("OTA command received", { cmd = payload.cmd, version = payload.version, update_id = payload.update_id }) end
      -- runs in pcall so a write failure doesn't crash the node
      local ran, ok, err = pcall(function() return get_updater()[ota_step](payload, msg.src) end)
      if not ran then
        node.net.send("event", msg.src, { type = "ota_result", node_id = node.id, update_id = payload.update_id, success = false, errors = { tostring(ok) } })
      elseif ok == false then
        node.net.send("err", msg.src, { ref_id = msg.id, error = tostring(err) })
      end
      return status
    end

    -- the master's answer to an announcement: where this computer stands (known / pending / conflict / rejected / muted / full)
    if payload.cmd == "pair_state" then
      remember_outcome(msg, true)
      node.net.ack_for(msg, true)
      -- the masters and the arbiter, from the master of this computer; believed only when the message is authenticated (or authentication is off)
      if type(payload.masters) == "table" and (not node.auth or node.auth.mode == "off" or msg.authenticated == true) then
        node.apply_topology(payload.masters, type(payload.arbiter) == "string" and payload.arbiter or nil)
      end
      if type(payload.state) == "string" and node.pair.state ~= payload.state then
        node.pair.state = payload.state
        node.logger.info("pairing", { state = payload.state, detail = payload.detail })
      end
      return status
    end

    -- a command that changes the world: a durable record first, the action second, the outcome third
    local ledger_key
    if node.ledger and DURABLE_COMMANDS[payload.cmd] then
      if payload.command_id then
        ledger_key = "cid:" .. tostring(payload.election_epoch) .. "/" .. tostring(payload.command_id)
      else
        ledger_key = tostring(msg.src) .. "/" .. tostring(msg.id)
      end
      local state, detail = node.ledger.begin(ledger_key)
      if state == nil then
        answer(msg, false, "no durable record, command refused: " .. tostring(detail))
        return status
      elseif state == "done" then
        answer(msg, detail == "ok", detail ~= "ok" and detail or nil)
        return status
      elseif state == "uncertain" then
        source_log.warn("uncertain:" .. ledger_key, "command from before a restart: outcome unknown, not repeated", { cmd = payload.cmd, id = msg.id })
        answer(msg, false, "uncertain after restart")
        return status
      elseif state == "started" then
        return status
      end
    end

    local ok, err = true, nil
    if node.handlers.on_cmd then
      ok, err = node.handlers.on_cmd(payload, msg)
    end
    if ledger_key then node.ledger.finish(ledger_key, ok ~= false and "ok" or tostring(err)) end

    remember_outcome(msg, ok, err)
    answer(msg, ok, err)

    return status
  end

  function node.handle_event(event)
    node.ticker.handle_event(event)

    if event[1] == "modem_message" then
      node.handle_message(event[5])
    elseif event[1] == "peripheral_detach" and node.peripherals then
      -- Invalidate cached peripheral wrapper so next access re-wraps
      node.peripherals.invalidate(event[2])
    end

    if node.handlers.on_event then
      node.handlers.on_event(event)
    end

    node.net.tick()
  end

  function node.start()
    if node.modem and node.modem.open then
      local ok, err = node.modem:open(node.config.channel)
      if ok == false then
        node.logger.error("node modem open failed", { error = err })
      end
    end

    node.register()
    node.heartbeat()
    node.ticker.start()
    -- the code of an update that just landed got this far: keep it (an unconfirmed first boot is rolled back)
    pcall(function()
      if get_updater().confirm_boot() then
        node.net.send_reliable("event", node.config.master_id, { type = "ota_confirmed", node_id = node.id, version = read_version() })
      end
    end)
  end

  function node.run()
    node.start()
    while true do
      node.handle_event({ node.pull_event() })
    end
  end

  return node
end

return common_node
