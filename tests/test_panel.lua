--[[
Purpose: Panel state and renderer tests.
Public API: returns table of tests.
]]

local panel_state = require("src.domain.panel_state")
local renderer = require("src.nodes.panel_renderer")

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
  test_panel_state_pages = function()
    local state = panel_state.new({ nodes = { { id = "PANEL-1", role = "panel", pages = { "overview", "trains" } } } }, "PANEL-1")
    assert(state.snapshot().page == "overview")
    state.next_page()
    assert(state.snapshot().page == "trains")
    state.next_page()
    assert(state.snapshot().page == "overview")
  end,

  test_panel_state_update_snapshot = function()
    local state = panel_state.new({ nodes = {} }, "PANEL-2")
    state.update({ master_state = "ONLINE", trains = { T1 = { state = "IDLE" } } })
    assert(state.snapshot().master_state == "ONLINE")
    assert(state.snapshot().trains.T1.state == "IDLE")
  end,

  test_panel_renderer_overview = function()
    local monitor = fake_monitor()
    renderer.render(monitor, { display_name = "Panel", page = "overview", master_state = "ONLINE", overview = { B1 = { state = "FREE" } } })
    assert(monitor.lines[1] == "CreateRailNet Panel")
    assert(string.find(monitor.lines[2], "overview"))
    assert(string.find(monitor.lines[8], "B1"))
  end,

  test_panel_renderer_trains = function()
    local monitor = fake_monitor()
    renderer.render(monitor, { display_name = "Panel", page = "trains", master_state = "ONLINE", trains = { T1 = { state = "RUNNING", route_id = "R1" } } })
    assert(string.find(monitor.lines[5], "Trains"))
    assert(string.find(monitor.lines[7], "T1"))
  end
}
