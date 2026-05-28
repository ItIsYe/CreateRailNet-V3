--[[
Purpose: Train registry and train node tests.
Public API: returns table of tests.
]]

local trains = require("src.domain.trains")
local train_node = require("src.nodes.train_node")

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
  test_train_registry_loads_configured_train = function()
    local reg = trains.new({ nodes = {
      { id = "TRAIN-1", role = "train", train_id = "T1", display_name = "Local 1", default_route = "R1" }
    } })
    local list = reg.list()
    assert(list.T1)
    assert(list.T1.display_name == "Local 1")
    assert(list.T1.default_route == "R1")
  end,

  test_train_registry_updates_status = function()
    local reg = trains.new({ nodes = {} })
    reg.update_status("T2", { state = "RUNNING", route_id = "R2", destination = "ST-B" })
    local train = reg.get("T2")
    assert(train.state == "RUNNING")
    assert(train.route_id == "R2")
    assert(train.destination == "ST-B")
  end,

  test_train_status_render_writes_monitor = function()
    local monitor = fake_monitor()
    train_node.render_status(monitor, { train_id = "T3", display_name = "Express", state = "IDLE" })
    assert(monitor.lines[1] == "CreateRailNet-V3")
    assert(string.find(monitor.lines[3], "T3"))
    assert(string.find(monitor.lines[4], "Express"))
  end
}
