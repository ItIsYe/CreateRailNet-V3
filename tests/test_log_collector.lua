--[[
Purpose: Central log: forwarder batches and limits, collector validates, bounds and filters.
Public API: returns table of tests.
]]

pcall(dofile, "tests/harness/cc_bootstrap.lua")

local log = require("src.shared.log")
local log_forwarder = require("src.shared.log_forwarder")
local log_collector = require("src.domain.log_collector")

local function setup_forwarder(opts)
  local env = { now = 0, batches = {} }
  local logger = log.new("DEBUG", 50)
  local o = { now_ms = function() return env.now end }
  for k, v in pairs(opts or {}) do o[k] = v end
  env.forwarder = log_forwarder.attach(logger, function(payload) env.batches[#env.batches + 1] = payload end, o)
  env.logger = logger
  return env
end

return {
  test_warnings_and_errors_are_forwarded_in_one_batch = function()
    local env = setup_forwarder()
    env.logger.info("just info")
    env.logger.warn("sensor slow", { sensor = "SEN-1", ms = 800, nested = { 1 } })
    env.logger.error("modem gone")
    assert(env.forwarder.flush() == 2)
    local batch = env.batches[1]
    assert(batch.type == "log_batch" and #batch.entries == 2)
    assert(batch.entries[1].lvl == "WARN" and batch.entries[1].ctx.sensor == "SEN-1" and batch.entries[1].ctx.nested == nil, "only plain values travel")
    assert(env.forwarder.flush() == 0 and #env.batches == 1, "nothing queued, nothing sent")
  end,

  test_the_local_log_still_gets_every_line = function()
    local env = setup_forwarder()
    env.logger.debug("a"); env.logger.info("b"); env.logger.warn("c")
    assert(#env.logger.get_buffer() == 3)
  end,

  test_identical_lines_are_folded_and_the_rate_is_limited = function()
    local env = setup_forwarder({ rate_per_min = 5, capacity = 100 })
    for _ = 1, 50 do env.logger.warn("same line") end
    assert(env.forwarder.flush() == 1 and env.batches[1].entries[1].n == 50)
    for i = 1, 30 do env.logger.warn("line " .. i) end
    env.forwarder.flush()
    assert(env.batches[2].dropped >= 20, "a node in a failure loop is cut off, got dropped=" .. tostring(env.batches[2].dropped))
    env.now = env.now + 60000
    env.logger.warn("after a minute")
    assert(env.forwarder.flush() == 1)
  end,

  test_network_lines_are_never_forwarded = function()
    local env = setup_forwarder()
    env.logger.warn("net retry", { id = "x" })
    env.logger.error("net max retries exceeded")
    assert(env.forwarder.flush() == 0)
  end,

  test_a_failing_sender_does_not_break_logging = function()
    local logger = log.new("DEBUG", 10)
    local forwarder = log_forwarder.attach(logger, function() error("modem unplugged") end)
    logger.error("x")
    assert(forwarder.flush() == 1)
    logger.error("y")
    assert(#logger.get_buffer() == 2)
  end,

  test_a_logger_that_cannot_be_wrapped_is_left_alone = function()
    assert(log_forwarder.attach({ warn = function() end }, function() end) == nil)
    assert(log_forwarder.attach(nil, function() end) == nil)
  end,

  test_collector_stores_newest_first_and_filters = function()
    local c = log_collector.new()
    c.ingest("SIG-1", { entries = { { lvl = "WARN", msg = "slow" }, { lvl = "ERROR", msg = "dead" }, { lvl = "INFO", msg = "chatter" } } })
    c.ingest("SEN-2", { entries = { { lvl = "WARN", msg = "flaky", n = 7 } } })
    local all = c.recent()
    assert(#all == 3 and all[1].node == "SEN-2" and all[1].n == 7 and all[2].msg == "dead" and all[3].msg == "slow", "INFO is below the default filter")
    assert(#c.recent({ min_level = "ERROR" }) == 1)
    assert(#c.recent({ node = "SIG-1", min_level = "INFO" }) == 3)
    assert(#c.recent({ limit = 1 }) == 1 and c.recent({ limit = 1, offset = 1 })[1].msg == "dead")
  end,

  test_collector_uses_the_message_source_and_validates_everything = function()
    local c = log_collector.new()
    assert(c.ingest("N1", nil) == 0 and c.ingest("N1", { entries = "x" }) == 0 and c.ingest(nil, { entries = {} }) == 0)
    assert(c.ingest("N1", { node_id = "ADMIN", entries = { { lvl = "WARN", msg = "hello", node = "ADMIN" }, { lvl = "BOGUS", msg = "x" }, { lvl = "WARN", msg = 5 }, "junk" } }) == 1)
    assert(c.recent()[1].node == "N1", "the claimed node id in the payload is ignored")
    assert(c.stats().rejected == 6, "three malformed calls and three malformed entries")
    local long = string.rep("x", 500)
    c.ingest("N1", { entries = { { lvl = "WARN", msg = long } } })
    assert(#c.recent()[1].msg <= 140)
  end,

  test_collector_is_bounded_in_lines_nodes_and_rate = function()
    local env = { ms = 0 }
    local c = log_collector.new({ total = 50, rate_per_min = 10, max_nodes = 20, now_ms = function() return env.ms end })
    for node = 1, 40 do c.ingest("N" .. node, { entries = { { lvl = "WARN", msg = "x" } } }) end
    assert(c.stats().nodes == 20, "only max_nodes senders are tracked")
    for _ = 1, 30 do c.ingest("N1", { entries = { { lvl = "WARN", msg = "burst" } } }) end
    assert(c.stats().dropped_by_nodes > 0 and c.stats().total <= 50)
    local many = {}
    for i = 1, 100 do many[i] = { lvl = "WARN", msg = "m" .. i } end
    local before = c.stats().rejected
    c.ingest("N2", { entries = many })
    assert(c.stats().rejected > before, "a batch beyond 20 entries is cut")
  end,

  test_node_forwards_its_warnings_to_the_master_in_batches = function()
    local common_node = require("src.nodes.common_node")
    local sent, now = {}, 0
    local modem = { open = function() return true end, send = function(_, _, _, m) sent[#sent + 1] = m; return true end, broadcast = function(_, _, m) sent[#sent + 1] = m; return true end }
    local node = common_node.new({
      id = "N1", role = "signal", config = { channel = 1, master_id = "M" }, modem = modem, logger = log.new("INFO", 20),
      clock = function() return now end, start_timer = function() return 1 end, tick_grace = 0
    })
    node.start()
    node.logger.warn("sensor slow", { sensor = "S1" })
    now = 6
    node.handle_event({ "peripheral", "tick" })
    local batch
    for _, m in ipairs(sent) do if m.payload and m.payload.type == "log_batch" then batch = m end end
    assert(batch and batch.dst == "M" and batch.type == "event" and batch.payload.entries[1].msg == "sensor slow")
  end,

  test_forwarding_can_be_switched_off_in_the_config = function()
    local common_node = require("src.nodes.common_node")
    local node = common_node.new({
      id = "N1", role = "signal", config = { channel = 1, master_id = "M", log_forward = false },
      modem = { open = function() return true end, send = function() return true end, broadcast = function() return true end },
      logger = log.new("INFO", 20)
    })
    assert(node.log_forwarder == nil)
  end,

  test_master_stores_forwarded_batches_by_message_source = function()
    local runtime_factory = require("src.master.runtime")
    local collector = log_collector.new()
    local rt = runtime_factory.new({
      config = { nodes = {} },
      registry = { all = function() return {} end, register = function() end, heartbeat = function() end },
      dispatcher = { get_overview = function() return {} end, timeout_node = function() end },
      network = { receive = function() return "ok" end, ack_for = function() end, send = function() end, tick = function() end },
      ui = { mark_dirty = function() end, draw = function() end, handle_touch = function() end },
      logs = collector, auto_restore_state = false, auto_save_state = false
    })
    rt.handle_event({ "modem_message", nil, nil, nil, { v = 1, id = "l.1", type = "event", src = "SIG-1", dst = "M", payload = { type = "log_batch", entries = { { lvl = "ERROR", msg = "drehgestell" } } } } })
    local entries = collector.recent()
    assert(#entries == 1 and entries[1].node == "SIG-1" and entries[1].msg == "drehgestell")
  end
}
