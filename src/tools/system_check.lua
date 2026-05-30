--[[
Purpose: Dry-run system check without touching world hardware.
Checks config validation, registries, route resolver, and dispatcher reservation path.
]]

local config = require("src.shared.config")
local validate = require("src.shared.validate")
local trains = require("src.domain.trains")
local stations = require("src.domain.stations")
local depots = require("src.domain.depots")
local service_plans = require("src.domain.service_plans")
local route_resolver = require("src.domain.route_resolver")
local dispatcher = require("src.master.dispatcher")

local system_check = {}

local function count(t)
  local n = 0
  for _ in pairs(t or {}) do n = n + 1 end
  return n
end

local fake_adapters = {
  signals = { setAspect = function() return true end },
  switches = { setPosition = function() return true end }
}

function system_check.run(path)
  local cfg_path = path or "configs/templates/network.full.example.json"
  print("System check: " .. cfg_path)
  local cfg = config.load(cfg_path)
  local ok, errors = validate.validate_config(cfg)
  if not ok then
    print("VALIDATION FAIL")
    for _, err in ipairs(errors or {}) do print("- " .. tostring(err)) end
    return false
  end

  local train_registry = trains.new(cfg)
  local station_registry = stations.new(cfg)
  local depot_registry = depots.new(cfg)
  local service_registry = service_plans.new(cfg)
  local resolver = route_resolver.new(cfg.routes or {})
  local disp = dispatcher.new(cfg, fake_adapters)

  print("nodes=" .. tostring(#(cfg.nodes or {})))
  print("routes=" .. tostring(#(cfg.routes or {})))
  print("trains=" .. tostring(count(train_registry.list())))
  print("stations=" .. tostring(count(station_registry.list())))
  print("depots=" .. tostring(count(depot_registry.list())))
  print("service_plans=" .. tostring(count(service_registry.list())))

  local first_plan
  for _, plan in pairs(service_registry.list()) do first_plan = plan; break end
  if first_plan and first_plan.stops and first_plan.stops[1] then
    local stop = first_plan.stops[1]
    local route = resolver.resolve({ route_id = stop.route_id, from = stop.from, to = stop.to, kind = stop.kind })
    if not route then print("ROUTE RESOLVE FAIL"); return false end
    local ok_reserve, err = disp.reserve_route(first_plan.train_id or "CHECK-TRAIN", route.id)
    if not ok_reserve then print("DISPATCH FAIL: " .. tostring(err)); return false end
    print("dispatch dry-run OK route=" .. tostring(route.id))
  end

  print("SYSTEM CHECK OK")
  return true
end

return system_check
