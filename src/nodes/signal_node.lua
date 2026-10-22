--[[
Purpose: Signal node entrypoint and runtime factory.
Public API: new_runtime(args_or_context).
Notes: the signal goes to RED when the node starts; the master re-sends its aspect on register/reconnect.
  A node entry with `signals` (logical ids) hosts several signals: cmd set_aspect carries payload.signal_id, the bindings are local (signal_bindings), the heartbeat carries `signals` (state per id).
]]

local create_signals = require("src.adapter.create_signals")
local common_node = require("src.nodes.common_node")
local bootstrap = require("src.nodes.bootstrap")
local signal_bindings = require("src.shared.signal_bindings")
local signal_host = require("src.nodes.signal_host")

local signal_node = {}

local function build_context(args_or_context)
  if args_or_context.config and args_or_context.logger and args_or_context.peripherals and args_or_context.modem then return args_or_context end
  return bootstrap.create_context({ "--id", args_or_context.id, "--config", args_or_context.config }, "signal")
end

local function own_entry(config, id)
  for _, node in ipairs((config and config.nodes) or {}) do
    if type(node) == "table" and node.id == id then return node end
  end
  return nil
end

-- Several signals on one computer (config node entry with `signals`): each logical signal goes to the peripheral it was bound to
-- (state/signal_bindings.json, made on this computer with the operator's confirmation), see src/nodes/signal_host.lua.
local function multi_runtime(context, entry)
  local peripherals = context.peripherals
  local bindings = signal_bindings.new({ fs = context.fs, node_id = context.id })
  local state, why = bindings.load()
  if state == "corrupt" then context.logger.error("signal bindings unreadable: no signal of this node is used", { reason = why }) end
  local host = signal_host.new({ bindings = bindings, peripherals = peripherals, logger = context.logger, expected = entry.signals })
  -- a computer that just started does not know what its signals show: RED, and what cannot be set is said
  local ok_red, failed = host.all_red()
  if not ok_red then context.logger.warn("signals that could not be set to RED at the start", { signals = table.concat(failed, ",") }) end
  local node = common_node.new({
    id = context.id, role = context.role, config = context.config, modem = context.modem, logger = context.logger, clock = context.clock,
    start_timer = context.start_timer, tick_grace = context.tick_grace,
    handlers = {
      on_quiesce = function()
        local ok = host.all_red()
        return ok
      end,
      on_cmd = function(payload)
        if not payload or not payload.aspect then return false, "missing payload.aspect" end
        if not payload.signal_id then return false, "missing payload.signal_id" end
        return host.set_aspect(payload.signal_id, payload.aspect)
      end
    }
  })
  node.signal_host = host
  node.signal_bindings = bindings
  -- the heartbeat tells the master which of the signals can be used: a signal that is missing or of another type is a fault there
  node.heartbeat = function()
    return node.net.heartbeat(node.config.master_id, { role = node.role, signals = host.brief() })
  end
  return node
end

function signal_node.new_runtime(args_or_context)
  local context = build_context(args_or_context)
  local entry = own_entry(context.config, context.id)
  if entry and type(entry.signals) == "table" and #entry.signals > 0 then return multi_runtime(context, entry) end
  local adapter = create_signals.new(context.peripherals, { hardware = context.hardware })
  -- a computer that just started does not know what its signal shows: RED until the master says otherwise
  -- (it sends the aspect again when the node registers)
  pcall(adapter.setAspect, context.id, "RED")
  return common_node.new({
    id = context.id,
    role = context.role,
    config = context.config,
    modem = context.modem,
    logger = context.logger,
    clock = context.clock,
    start_timer = context.start_timer,
    tick_grace = context.tick_grace,
    handlers = {
      -- before an update swaps files and reboots, the signal goes to RED
      on_quiesce = function() return adapter.setAspect(context.id, "RED") end,
      on_cmd = function(payload)
        if not payload or not payload.aspect then return false, "missing payload.aspect" end
        return adapter.setAspect(context.id, payload.aspect)
      end
    }
  })
end

local raw = {...}
if raw and raw[1] == "--run" then signal_node.new_runtime(bootstrap.create_context(raw, "signal")).run() end

return signal_node
