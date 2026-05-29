--[[
Purpose: Runtime diagnostics summary for master and panels.
Public API: build(context) -> diagnostics table.
]]

local diagnostics = {}

local function count_pairs(t)
  local n = 0
  for _ in pairs(t or {}) do n = n + 1 end
  return n
end

local function count_array(t)
  local n = 0
  for _ in ipairs(t or {}) do n = n + 1 end
  return n
end

local function recent_logs(logger, limit)
  local out = {}
  if not logger or not logger.get_buffer then return out end
  local buffer = logger.get_buffer() or {}
  local max = limit or 8
  local start = math.max(1, #buffer - max + 1)
  for i = start, #buffer do
    local entry = buffer[i]
    table.insert(out, { level = entry.level, msg = entry.msg, ts = entry.ts, context = entry.context })
  end
  return out
end

local function recent_audit(audits, limit)
  if not audits or not audits.list then return {} end
  return audits.list(limit or 8)
end

local function maintenance_status(maintenance)
  if not maintenance then return { enabled = false } end
  if maintenance.status then return maintenance.status() end
  return { enabled = maintenance.enabled == true, reason = maintenance.reason }
end

local function count_node_health(registry)
  local summary = { total = 0, up = 0, down = 0, by_role = {} }
  if not registry or not registry.all then return summary end
  for _, node in pairs(registry.all() or {}) do
    summary.total = summary.total + 1
    local status = node.status or node.state or "up"
    if status == "down" or status == "DOWN" or status == "OFFLINE" then summary.down = summary.down + 1 else summary.up = summary.up + 1 end
    local role = node.role or "unknown"
    summary.by_role[role] = (summary.by_role[role] or 0) + 1
  end
  return summary
end

local function config_report(cfg)
  return { nodes = count_array((cfg or {}).nodes), blocks = count_array((cfg or {}).blocks), routes = count_array((cfg or {}).routes), service_plans = count_array((cfg or {}).service_plans or (cfg or {}).schedules), channel = (cfg or {}).channel, master_id = (cfg or {}).master_id }
end

function diagnostics.build(context)
  local dispatcher = context.dispatcher
  local service_plans = context.service_plan_registry
  local route_integration = context.route_integration
  return {
    config = config_report(context.config),
    node_health = count_node_health(context.registry),
    recent_logs = recent_logs(context.logger, 8),
    recent_audit = recent_audit(context.audit_log, 8),
    maintenance = maintenance_status(context.maintenance),
    queue = dispatcher and dispatcher.get_queue and dispatcher.get_queue() or {},
    switch_locks = dispatcher and dispatcher.get_switch_locks and dispatcher.get_switch_locks() or {},
    deadlocks = dispatcher and dispatcher.get_deadlocks and dispatcher.get_deadlocks() or {},
    pending_departures = route_integration and route_integration.get_pending_departures and route_integration.get_pending_departures() or {},
    service_plan_count = service_plans and count_pairs(service_plans.list and service_plans.list() or {}) or 0
  }
end

return diagnostics
