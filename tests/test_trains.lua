--[[
Purpose: Train registry and train node tests.
Public API: returns table of tests.
]]

local trains = require("src.domain.trains")
local train_node = require("src.nodes.train_node")

local function fake_monitor()
  local m = { lines = {}, cursor = {1, 1} }
  function m.clear() m.lines = {} end
  function m.setCursorPos(x, y) m.cursor = {x, y} end
  function m.write(text) m.lines[m.cursor[2]] = text end
  return m
end

local function contains_line(lines, text)
  for _, line in pairs(lines or {}) do if string.find(tostring(line), text, 1, true) then return true end end
  return false
end

return {
  test_train_registry_loads_configured_train = function()
    local reg = trains.new({ nodes = { { id = "TRAIN-1", role = "train", train_id = "T1", display_name = "Local 1", default_route = "R1" } } })
    local list = reg.list()
    assert(list.T1)
    assert(list.T1.display_name == "Local 1")
    assert(list.T1.default_route == "R1")
  end,

  test_train_registry_updates_status = function()
    local reg = trains.new({ nodes = {} })
    reg.update_status("T2", { state = "RUNNING", route_id = "R2", destination = "ST-B", create_destination = "Hauptbahnhof B" })
    local train = reg.get("T2")
    assert(train.state == "RUNNING")
    assert(train.route_id == "R2")
    assert(train.destination == "ST-B")
    assert(train.create_destination == "Hauptbahnhof B")
  end,

  test_train_status_render_writes_monitor = function()
    local monitor = fake_monitor()
    train_node.render_status(monitor, { train_id = "T3", display_name = "Express", state = "IDLE", destination = "ST-B", create_destination = "Hauptbahnhof B" })
    assert(monitor.lines[1] == "CreateRailNet-V3")
    assert(contains_line(monitor.lines, "T3"))
    assert(contains_line(monitor.lines, "Express"))
    assert(contains_line(monitor.lines, "ST-B"))
    assert(contains_line(monitor.lines, "Hauptbahnhof B"))
  end
}
