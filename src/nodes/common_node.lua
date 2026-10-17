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
local ticker = require("src.shared.ticker")

local common_node = {}

local function read_version()
  if fs and fs.exists and fs.exists("crn_version.txt") then
    local fh = fs.open("crn_version.txt", "r")
    if fh then local text = fh.readAll(); fh.close(); return text end
  end
  return "unknown"
end

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

  node.net = net.new(node.modem, node.config.channel, node.id, node.logger, time)

  node.ticker = ticker.new({
    clock = opts.clock,
    start_timer = opts.start_timer,
    grace = opts.tick_grace,
    on_error = function(name, err, count)
      node.logger.warn("tick job failed", { job = name, error = err, count = count })
    end
  })
  -- node.heartbeat is looked up on every tick because roles replace it after construction
  node.ticker.every("heartbeat", node.heartbeat_ms / 1000, function() node.heartbeat() end)

  function node.register()
    return node.net.send_reliable("register", node.config.master_id, { role = node.role })
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
      node_updater = updater.new(node.net, node.id, node.logger, {
        fs = ota.fs, reboot = ota.reboot, sleep = ota.sleep, sources = sources,
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

  local function answer(msg, ok, err)
    if ok == false then
      node.net.send("err", msg.src, { ref_id = msg.id, error = tostring(err) })
    else
      node.net.ack_for(msg)
    end
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

    local ok, err = true, nil
    if node.handlers.on_cmd then
      ok, err = node.handlers.on_cmd(payload, msg)
    end

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
