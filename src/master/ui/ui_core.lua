--[[
Purpose: Master UI core with dirty redraw, touch handling, and defensive rendering.
Public API: new(monitor, panels, opts), set_panel(name), mark_dirty(), draw(), handle_touch(x,y).
]]

local ui_core = {}

function ui_core.new(monitor, panels, opts)
  local options = opts or {}
  local ui = {
    monitor = monitor,
    panels = panels or {},
    current = nil,
    dirty = true,
    logger = options.logger
  }

  local function log_error(msg, context)
    if ui.logger and ui.logger.error then
      ui.logger.error(msg, context)
    end
  end

  function ui.set_panel(name)
    ui.current = name
    ui.dirty = true
  end

  function ui.mark_dirty()
    ui.dirty = true
  end

  local function draw_fallback(err)
    if type(ui.monitor) ~= "table" then
      return
    end
    if type(ui.monitor.clear) == "function" then
      pcall(ui.monitor.clear, ui.monitor)
    end
    if type(ui.monitor.setCursorPos) == "function" then
      pcall(ui.monitor.setCursorPos, ui.monitor, 1, 1)
    end
    if type(ui.monitor.write) == "function" then
      pcall(ui.monitor.write, ui.monitor, "UI unavailable")
      pcall(ui.monitor.setCursorPos, ui.monitor, 1, 2)
      pcall(ui.monitor.write, ui.monitor, tostring(err or "unknown error"))
    end
  end

  function ui.draw()
    if not ui.dirty or not ui.current then
      return
    end
    local panel = ui.panels[ui.current]
    if panel and panel.draw then
      local ok, err = pcall(panel.draw, ui.monitor)
      if not ok then
        log_error("ui panel draw failed", { panel = ui.current, err = tostring(err) })
        draw_fallback(err)
      end
    end
    ui.dirty = false
  end

  function ui.handle_touch(x, y)
    local panel = ui.panels[ui.current]
    if panel and panel.touch then
      local ok, err = pcall(panel.touch, x, y)
      if not ok then
        log_error("ui panel touch failed", { panel = ui.current, err = tostring(err), x = x, y = y })
      end
      ui.dirty = true
    end
  end

  return ui
end

return ui_core
