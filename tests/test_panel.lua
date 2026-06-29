--[[
Purpose: Panel state and renderer tests.
Public API: returns table of tests.
]]

local panel_state = require("src.domain.panel_state")
local renderer = require("src.nodes.panel_renderer")

local function fake_monitor()
  local m = { lines = {}, cursor = {1, 1} }
  function m.clear() m.lines = {} end
  function m.setCursorPos(x, y) m.cursor = {x, y} end
  function m.write(text) m.lines[m.cursor[2]] = text end
  return m
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

  test_panel_state_default_pages_include_audit_maintenance = function()
    local state = panel_state.new({ nodes = {} }, "PANEL-2")
    local pages = table.concat(state.snapshot().pages, ",")
    assert(string.find(pages, "audit"))
    assert(string.find(pages, "maintenance"))
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
    -- Header: line 1 contains "CreateRailNet", line 2 has "Master:"
    assert(string.find(monitor.lines[1] or "", "CreateRailNet") or
           string.find(monitor.lines[2] or "", "Master"),
           "header must contain CreateRailNet")
    assert(string.find(monitor.lines[8] or "", "B1"), "block B1 must appear")
  end,

  test_panel_renderer_trains = function()
    local monitor = fake_monitor()
    renderer.render(monitor, { display_name = "Panel", page = "trains", master_state = "ONLINE", trains = { T1 = { state = "RUNNING", route_id = "R1", message = "ok" } } })
    assert(string.find(monitor.lines[5], "Trains"))
    assert(string.find(monitor.lines[7], "T1"))
  end,

  test_panel_renderer_audit = function()
    local monitor = fake_monitor()
    renderer.render(monitor, { display_name = "Panel", page = "audit", master_state = "ONLINE", diagnostics = { recent_audit = { { seq = 1, kind = "route_request", data = { train_id = "T1", route_id = "R1" } } } } })
    assert(string.find(monitor.lines[5], "Audit"))
    assert(string.find(monitor.lines[7], "route_request"))
  end,

  test_panel_renderer_maintenance = function()
    local monitor = fake_monitor()
    renderer.render(monitor, { display_name = "Panel", page = "maintenance", master_state = "MAINTENANCE", diagnostics = { maintenance = { enabled = true, reason = "test", changed_by = "PANEL" }, queue = {}, pending_departures = {} } })
    assert(string.find(monitor.lines[5], "Maintenance"))
    assert(string.find(monitor.lines[7], "LOCKED"))
  end
}
