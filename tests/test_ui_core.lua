--[[
Purpose: ui_core tests: fixed page order, wrap-around navigation, off-screen drawing, panels that fail alone, touch edges.
Public API: returns table of tests.
]]

pcall(dofile, "tests/harness/cc_bootstrap.lua")

local ui_core = require("src.master.ui.ui_core")

local function fake_monitor(w, h)
  local m = { calls = {}, size = { w, h } }
  m.getSize = function() return m.size[1], m.size[2] end
  m.setCursorPos = function(x, y) m.calls[#m.calls + 1] = string.format("at:%d,%d", x, y) end
  m.write = function(text) m.calls[#m.calls + 1] = "write:" .. text end
  m.clear = function() m.calls[#m.calls + 1] = "clear" end
  return m
end

local function fake_window_api()
  local api = { created = {} }
  api.create = function(parent, x, y, w, h)
    local win = { calls = {}, visible = false }
    win.getSize = function() return w, h end
    win.setCursorPos = function(cx, cy) win.calls[#win.calls + 1] = string.format("at:%d,%d", cx, cy) end
    win.write = function(text) win.calls[#win.calls + 1] = "write:" .. text end
    win.clear = function() win.calls[#win.calls + 1] = "clear" end
    win.setVisible = function(v)
      win.visible = v
      if v then for _, c in ipairs(win.calls) do parent.calls[#parent.calls + 1] = c end; win.calls = {} end
    end
    api.created[#api.created + 1] = win
    return win
  end
  return api
end

local function logger_into(lines)
  local l = {}
  for _, level in ipairs({ "info", "warn", "error" }) do l[level] = function(text, data) lines[#lines + 1] = { level = level, text = text, data = data } end end
  return l
end

local function panel(name, log) return { draw = function(target) if log then log[#log + 1] = name end; target.write("page " .. name) end } end

return {
  test_pages_follow_the_fixed_order_with_unlisted_panels_last = function()
    local ui = ui_core.new(fake_monitor(51, 19), { ota = panel("ota"), zeta = panel("zeta"), trains = panel("trains"), status = panel("status"), alpha = panel("alpha"), overview = panel("overview") }, { window = false })
    assert(table.concat(ui.page_order, ",") == "status,overview,trains,ota,alpha,zeta", table.concat(ui.page_order, ","))
  end,

  test_navigation_wraps_in_both_directions = function()
    local ui = ui_core.new(fake_monitor(51, 19), { status = panel("status"), overview = panel("overview"), trains = panel("trains") }, { window = false })
    ui.set_panel("trains")
    ui.next_panel(); assert(ui.current == "status")
    ui.prev_panel(); assert(ui.current == "trains")
    ui.prev_panel(); assert(ui.current == "overview")
  end,

  test_rebuild_order_picks_up_panels_replaced_later = function()
    local panels = { status = panel("status") }
    local ui = ui_core.new(fake_monitor(51, 19), panels, { window = false })
    panels.trains = panel("trains")
    ui.rebuild_order()
    assert(table.concat(ui.page_order, ",") == "status,trains")
  end,

  test_frames_are_drawn_off_screen_and_shown_once_with_the_page_indicator = function()
    local monitor, api = fake_monitor(51, 19), fake_window_api()
    local ui = ui_core.new(monitor, { status = panel("status"), overview = panel("overview") }, { window = api })
    ui.set_panel("overview")
    ui.draw()
    local joined = table.concat(monitor.calls, "|")
    assert(joined:find("write:page overview", 1, true) and joined:find("write:<2/2>", 1, true), joined)
    local before = #monitor.calls
    ui.draw()
    assert(#monitor.calls == before, "a clean ui does not redraw")
    ui.mark_dirty(); ui.draw()
    assert(#monitor.calls > before)
  end,

  test_a_panel_that_raises_gets_an_error_page_and_one_log_line = function()
    local monitor, lines, now = fake_monitor(51, 19), {}, 0
    local broken = { draw = function() error("kaputt", 0) end }
    local ui = ui_core.new(monitor, { status = broken, overview = panel("overview") }, { window = false, logger = logger_into(lines), now_ms = function() return now end })
    ui.set_panel("status")
    for _ = 1, 30 do ui.mark_dirty(); now = now + 200; ui.draw() end
    local errors = 0
    for _, l in ipairs(lines) do if l.level == "error" then errors = errors + 1 end end
    assert(errors == 1, "one log line per minute, got " .. errors)
    assert(table.concat(monitor.calls, "|"):find("Anzeigefehler", 1, true))
    assert(ui.last_error and ui.last_error.panel == "status")
    ui.handle_touch(51, 5)
    assert(ui.current == "overview", "navigation still works from the error page")
    ui.draw()
    assert(ui.last_error == nil)
  end,

  test_a_recovering_panel_is_announced = function()
    local lines, now, broken = {}, 0, true
    local flaky = { draw = function(target) if broken then error("noch nicht", 0) end; target.write("ok") end }
    local ui = ui_core.new(fake_monitor(51, 19), { status = flaky }, { window = false, logger = logger_into(lines), now_ms = function() return now end })
    ui.set_panel("status"); ui.draw()
    broken = false; ui.mark_dirty(); ui.draw()
    assert(lines[#lines].level == "info" and lines[#lines].text:find("recovered"))
  end,

  test_touch_edges_change_the_page_and_the_middle_goes_to_the_panel = function()
    local touched = {}
    local p = { draw = function() end, touch = function(x, y) touched[#touched + 1] = x .. "," .. y end }
    local ui = ui_core.new(fake_monitor(51, 19), { status = p, overview = panel("overview") }, { window = false })
    ui.set_panel("status")
    ui.handle_touch(1, 5); assert(ui.current == "overview")
    ui.handle_touch(50, 5); assert(ui.current == "status")
    ui.handle_touch(20, 7)
    assert(#touched == 1 and touched[1] == "20,7")
  end,

  test_a_touch_handler_that_raises_does_not_take_the_screen_down = function()
    local ui = ui_core.new(fake_monitor(51, 19), { status = { draw = function() end, touch = function() error("x", 0) end } }, { window = false })
    ui.set_panel("status")
    ui.handle_touch(20, 7)
    assert(ui.dirty == true)
  end
}
