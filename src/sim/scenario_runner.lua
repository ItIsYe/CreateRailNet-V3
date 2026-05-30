--[[
Purpose: Offline scenario runner using real domain/master modules without Minecraft hardware.
Public API: new(config, opts) -> scenario with send_service_plan, request_departure, arrive_station, ready_station, depot_dispatch, snapshot.
]]

local trains = require("src.domain.trains")
local stations = require("src.domain.stations")
local depots = require("src.domain.depots")
local service_plans = require("src.domain.service_plans")
local audit_log = require("src.domain.audit_log")
local maintenance = require("src.domain.maintenance")
local dispatcher = require("src.master.dispatcher")
local route_resolver = require("src.domain.route_resolver")
local route_integration = require("src.master.route_integration")
local fake_network = require("src.sim.fake_network")
local fake_clock = require("src.sim.fake_clock")

local scenario_runner = {}

local function fake_adapters()
  return {
    signals = { setAspect = function() return true end, getState = function() return true, "GREEN" end },
    switches = { setPosition = function() return true end }
  }
end

local function count(t)
  local n = 0
  for _ in pairs(t or {}) do n = n + 1 end
  return n
end

function scenario_runner.new(config, opts)
  local options = opts or {}
  local clock = options.clock or fake_clock.new(0)
  local network = options.network or fake_network.new()
  local train_registry = trains.new(config)
  local station_registry = stations.new(config)
  local depot_registry = depots.new(config)
  local service_registry = service_plans.new(config)
  local audits = audit_log.new(200)
  local maint = maintenance.new()
  local disp = dispatcher.new(config, fake_adapters())
  local resolver = route_resolver.new(config.routes or {})

  local integration = route_integration.new({
    dispatcher = disp,
    route_resolver = resolver,
    service_plan_registry = service_registry,
    maintenance = maint,
    audit_log = audits,
    network = network,
    train_registry = train_registry,
    station_registry = station_registry,
    depot_registry = depot_registry
  })

  local self = {
    config = config,
    clock = clock,
    network = network,
    trains = train_registry,
    stations = station_registry,
    depots = depot_registry,
    service_plans = service_registry,
    audit_log = audits,
    maintenance = maint,
    dispatcher = disp,
    route_resolver = resolver,
    route_integration = integration
  }

  function self.send_service_plan(train_id)
    return integration.send_service_plan(train_id)
  end

  function self.request_departure(train_id, payload)
    local body = payload or {}
    body.train_id = train_id
    return integration.handle_train_request(body, train_id)
  end

  function self.arrive_station(train_id, station_id, platform_id, route_id)
    return integration.handle_train_arrival({ train_id = train_id, station = station_id, platform_id = platform_id, route_id = route_id }, train_id)
  end

  function self.ready_station(station_id, platform_id, train_id, payload)
    local body = payload or {}
    body.station_id = station_id
    body.platform_id = platform_id
    body.train_id = train_id
    return integration.handle_station_ready(body, station_id)
  end

  function self.depot_dispatch(depot_id, track_id, train_id, payload)
    local body = payload or {}
    body.depot_id = depot_id
    body.track_id = track_id
    body.train_id = train_id
    return integration.handle_depot_request(body, depot_id)
  end

  function self.advance(seconds)
    clock.advance(seconds or 0)
    return integration.process_due(clock.now())
  end

  function self.snapshot()
    return {
      sent = network.sent,
      trains = train_registry.list(),
      stations = station_registry.list(),
      depots = depot_registry.list(),
      service_plans = service_registry.list(),
      overview = disp.get_overview(),
      audit_count = count(audits.list())
    }
  end

  return self
end

return scenario_runner
