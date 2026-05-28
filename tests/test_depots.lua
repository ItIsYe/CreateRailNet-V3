--[[
Purpose: Depot registry and depot node tests.
Public API: returns table of tests.
]]

local depots = require("src.domain.depots")
local depot_node = require("src.nodes.depot_node")

local function fake_monitor()
  return {
    lines = {},
    cursor = {1, 1},
    clear = function(self) self.lines = {} end,
    setCursorPos = function(self, x, y) self.cursor = {x, y} end,
    write = function(self, text) self.lines[self.cursor[2]] = text end
  }
end

return {
  test_depot_registry_loads_tracks = function()
    local reg = depots.new({ nodes = {
      { id = "DEPOT-1", role = "depot", depot_type = "mixed", tracks = {
        { id = "D1", kind = "storage", sensor_id = "SEN-D1" },
        { id = "S1", kind = "staging", sensor_id = "SEN-S1" }
      } }
    } })
    local depot = reg.get("DEPOT-1")
    assert(depot)
    assert(depot.tracks.D1.kind == "storage")
    assert(depot.tracks.S1.kind == "staging")
  end,

  test_depot_registry_queue = function()
    local reg = depots.new({ nodes = {} })
    reg.enqueue("DEPOT-2", { train_id = "TRAIN-1", route_id = "R1" })
    local item = reg.dequeue("DEPOT-2")
    assert(item.train_id == "TRAIN-1")
    assert(item.route_id == "R1")
  end,

  test_depot_node_builds_track_map = function()
    local tracks = depot_node.build_track_map({ depot_type = "mixed", tracks = {
      { id = "A", sensor_id = "SEN-A", ready_after_seconds = 3 }
    } })
    assert(tracks.A)
    assert(tracks.A.sensor_id == "SEN-A")
    assert(tracks.A.ready_after_seconds == 3)
  end,

  test_depot_render_writes_monitor = function()
    local monitor = fake_monitor()
    depot_node.render_status(monitor, {
      depot_id = "DEPOT-3",
      depot_type = "mixed",
      state = "ONLINE",
      queue = {},
      tracks = { D1 = { id = "D1", kind = "storage", state = "EMPTY" } }
    })
    assert(monitor.lines[1] == "CreateRailNet Depot")
    assert(string.find(monitor.lines[3], "DEPOT-3"))
    assert(string.find(monitor.lines[4], "mixed"))
  end
}
