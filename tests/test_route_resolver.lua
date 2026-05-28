--[[
Purpose: Route resolver tests.
Public API: returns table of tests.
]]

local route_resolver = require("src.domain.route_resolver")

return {
  test_resolve_by_route_id = function()
    local resolver = route_resolver.new({
      { id = "R1", from = "A", to = "B", priority = 1 }
    })
    local route, source = resolver.resolve({ route_id = "R1" })
    assert(route.id == "R1")
    assert(source == "route_id")
  end,

  test_resolve_by_from_to = function()
    local resolver = route_resolver.new({
      { id = "R1", from = "A", to = "B", priority = 1 }
    })
    local route, source = resolver.resolve({ from = "A", to = "B" })
    assert(route.id == "R1")
    assert(source == "from_to")
  end,

  test_resolve_prefers_priority = function()
    local resolver = route_resolver.new({
      { id = "LOW", from = "A", to = "B", priority = 1 },
      { id = "HIGH", from = "A", to = "B", priority = 9 }
    })
    local route = resolver.resolve({ from = "A", to = "B" })
    assert(route.id == "HIGH")
  end,

  test_resolve_filters_kind = function()
    local resolver = route_resolver.new({
      { id = "PASS", from = "A", to = "B", kind = "passenger", priority = 5 },
      { id = "FREIGHT", from = "A", to = "B", kind = "freight", priority = 9 }
    })
    local route = resolver.resolve({ from = "A", to = "B", kind = "passenger" })
    assert(route.id == "PASS")
  end,

  test_no_route_returns_error = function()
    local resolver = route_resolver.new({})
    local route, err = resolver.resolve({ from = "A", to = "B" })
    assert(route == nil)
    assert(err == "no route for from/to")
  end
}
