--[[
Purpose: Two computers on one modem channel for tests: a client (a station / depot computer, its setup wizard) and a master, with a clock the
  test moves, messages that can be dropped, and the real master runtime with its plan service on a plan file.
Public API:
  template(name) -> text of configs/templates/<name>
  new() -> bus { clock, inbox { client, master }, sent_to_master, filter(msg, direction) -> boolean, client_modem, master_modem, time }
  real_master(bus, plan_text, opts) -> master { fs, cfg, channel, master_id, runtime, step() }
      opts: chunk_size (400)    the plan file is configs/network.json on the master's disk
  puller(bus, master) -> pull_event(timeout): the master reads its inbox first, then the client's inbox is read; time moves by the timeout
]]

local net = require("src.shared.net")
local runtime_factory = require("src.master.runtime")
local registry_factory = require("src.shared.registry")
local alerts_module = require("src.domain.alerts")
local plan_service_module = require("src.master.plan_service")
local pairing_module = require("src.master.pairing")
local netplan = require("src.setup.netplan")
local memfs = require("tests.harness.memfs")

local plan_bus = {}

plan_bus.PLAN = "configs/network.json"
local quiet = { info = function() end, warn = function() end, error = function() end, debug = function() end }
plan_bus.quiet = quiet

function plan_bus.template(name)
  local fh = assert(io.open("configs/templates/" .. name, "r"))
  local text = fh:read("*a")
  fh:close()
  return text
end

function plan_bus.new()
  local b = { clock = 1000, inbox = { client = {}, master = {} }, sent_to_master = {}, filter = function() return true end }
  -- the queues are looked up on every message: the reader replaces them when it takes the messages
  local function deliver(name, direction)
    return function(msg)
      if b.filter(msg, direction) then b.inbox[name][#b.inbox[name] + 1] = msg end
      return true
    end
  end
  local to_master, to_client = deliver("master", "to_master"), deliver("client", "to_client")
  b.client_modem = { open = function() return true end, send = function(_, _, _, msg) b.sent_to_master[#b.sent_to_master + 1] = msg; return to_master(msg) end,
    broadcast = function(_, _, msg) return to_master(msg) end }
  b.master_modem = { open = function() return true end, send = function(_, _, _, msg) return to_client(msg) end, broadcast = function(_, _, msg) return to_client(msg) end }
  b.time = { now_ms = function() return b.clock * 1000 end, now_s = function() return b.clock end }
  return b
end

function plan_bus.real_master(b, plan_text, opts)
  local o = opts or {}
  local fs = memfs.new()
  local cfg = assert(netplan.parse(plan_text))
  fs.set(plan_bus.PLAN, plan_text)
  local network = net.new(b.master_modem, cfg.channel, cfg.master_id, quiet, b.time)
  local m = { fs = fs, cfg = cfg, network = network, channel = cfg.channel, master_id = cfg.master_id }
  m.runtime = runtime_factory.new({
    config = cfg, registry = registry_factory.new(),
    dispatcher = { get_overview = function() return {} end, timeout_node = function() end },
    network = network,
    ui = { mark_dirty = function() end, draw = function() end, handle_touch = function() end },
    audit_log = { record = function() end }, alerts = alerts_module.new({ now_s = b.time.now_s }),
    pairing = pairing_module.new({ config = cfg, plan_path = plan_bus.PLAN, fs = fs, now_s = b.time.now_s }),
    plan_service = plan_service_module.new({ plan_path = plan_bus.PLAN, fs = fs, chunk_size = o.chunk_size or 400, now_s = b.time.now_s }),
    auto_restore_state = false, auto_save_state = false,
  })
  function m.step()
    local inbox = b.inbox.master
    b.inbox.master = {}
    for _, msg in ipairs(inbox) do m.runtime.handle_event({ "modem_message", nil, nil, nil, msg }) end
  end
  return m
end

function plan_bus.puller(b, m)
  return function(timeout)
    if m then m.step() end
    local msg = table.remove(b.inbox.client, 1)
    if msg then return { "modem_message", nil, nil, nil, msg } end
    b.clock = b.clock + timeout
    return nil
  end
end

return plan_bus
