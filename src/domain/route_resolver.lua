--[[
Purpose: Resolve route requests by route_id or from/to endpoints.
Public API: new(routes) -> resolver with resolve(request), list_candidates(from, to).
]]

local route_resolver = {}

local function copy_route(route)
  if not route then return nil end
  local out = {}
  for k, v in pairs(route) do out[k] = v end
  return out
end

local function route_matches(route, from_id, to_id, kind)
  if from_id and route.from ~= from_id then return false end
  if to_id and route.to ~= to_id then return false end
  if kind and route.kind and route.kind ~= kind and route.kind ~= "mixed" then return false end
  return true
end

local function route_score(route, request)
  local score = route.priority or 0
  if request.preferred_route_id and route.id == request.preferred_route_id then score = score + 10000 end
  if request.kind and route.kind == request.kind then score = score + 100 end
  if request.from and route.from == request.from then score = score + 10 end
  if request.to and route.to == request.to then score = score + 10 end
  return score
end

function route_resolver.new(routes)
  local by_id = {}
  local list = {}
  for _, route in ipairs(routes or {}) do
    if route.id then
      by_id[route.id] = route
      table.insert(list, route)
    end
  end

  local self = {}

  function self.list_candidates(from_id, to_id, kind)
    local out = {}
    for _, route in ipairs(list) do
      if route_matches(route, from_id, to_id, kind) then
        table.insert(out, copy_route(route))
      end
    end
    return out
  end

  function self.resolve(request)
    local req = request or {}
    if req.route_id and by_id[req.route_id] then
      return copy_route(by_id[req.route_id]), "route_id"
    end

    local best = nil
    local best_score = nil
    for _, route in ipairs(list) do
      if route_matches(route, req.from, req.to or req.destination, req.kind) then
        local score = route_score(route, req)
        if not best or score > best_score then
          best = route
          best_score = score
        end
      end
    end

    if best then return copy_route(best), "from_to" end
    return nil, "no route for from/to"
  end

  return self
end

return route_resolver
