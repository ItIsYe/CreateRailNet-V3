--[[
Purpose: window_buffer tests: draws stay off the monitor until finish, a failed frame is dropped, resize recreates the window,
  no window API falls back to the monitor.
Public API: returns table of tests.
]]

pcall(dofile, "tests/harness/cc_bootstrap.lua")

local window_buffer = require("src.shared.window_buffer")

local function fake_monitor(w, h)
  local m = { calls = {}, size = { w, h } }
  m.getSize = function() return m.size[1], m.size[2] end
  m.write = function(text) m.calls[#m.calls + 1] = "write:" .. text end
  m.clear = function() m.calls[#m.calls + 1] = "clear" end
  return m
end

local function fake_window_api()
  local api = { created = {} }
  api.create = function(parent, x, y, w, h, visible)
    local win = { parent = parent, w = w, h = h, visible = visible, calls = {} }
    win.getSize = function() return w, h end
    win.write = function(text) win.calls[#win.calls + 1] = "write:" .. text; if win.visible then parent.write(text) end end
    win.clear = function() win.calls[#win.calls + 1] = "clear" end
    win.setVisible = function(v)
      win.calls[#win.calls + 1] = "visible:" .. tostring(v)
      win.visible = v
      if v then parent.write("<frame of " .. #win.calls .. " calls>") end
    end
    api.created[#api.created + 1] = win
    return win
  end
  return api
end

return {
  test_drawing_stays_off_the_monitor_until_finish = function()
    local monitor, api = fake_monitor(51, 19), fake_window_api()
    local buffer = window_buffer.new(monitor, { window = api })
    local target = buffer.begin()
    assert(target ~= monitor and buffer.buffered())
    target.clear(); target.write("hello")
    assert(#monitor.calls == 0, "the monitor must not see a half drawn frame")
    assert(buffer.finish() == true)
    assert(#monitor.calls == 1 and monitor.calls[1]:find("frame"))
    local win = api.created[1]
    assert(win.calls[#win.calls] == "visible:false", "the window goes back to buffering")
  end,

  test_a_dropped_frame_never_reaches_the_monitor = function()
    local monitor, api = fake_monitor(51, 19), fake_window_api()
    local buffer = window_buffer.new(monitor, { window = api })
    local target = buffer.begin()
    target.write("half a frame")
    buffer.abort()
    assert(#monitor.calls == 0)
  end,

  test_the_window_is_reused_and_recreated_on_resize = function()
    local monitor, api = fake_monitor(51, 19), fake_window_api()
    local buffer = window_buffer.new(monitor, { window = api })
    local first = buffer.begin()
    assert(buffer.begin() == first and #api.created == 1)
    monitor.size = { 80, 40 }
    local second = buffer.begin()
    assert(second ~= first and #api.created == 2 and api.created[2].w == 80 and api.created[2].h == 40)
  end,

  test_without_a_window_api_the_monitor_is_drawn_on_directly = function()
    local monitor = fake_monitor(51, 19)
    local buffer = window_buffer.new(monitor, { window = false })
    assert(buffer.begin() == monitor and buffer.buffered() == false and buffer.finish() == false)
  end,

  test_a_monitor_without_getsize_is_drawn_on_directly = function()
    local monitor = { write = function() end }
    local buffer = window_buffer.new(monitor, { window = fake_window_api() })
    assert(buffer.begin() == monitor)
  end,

  test_failing_window_creation_falls_back_to_the_monitor = function()
    local monitor = fake_monitor(51, 19)
    local buffer = window_buffer.new(monitor, { window = { create = function() error("no window") end } })
    assert(buffer.begin() == monitor)
  end
}
