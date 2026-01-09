--[[
Purpose: Master UI core with dirty redraw and touch handling.
Public API: new(monitor, panels), set_panel(name), mark_dirty(), handle_touch(x,y).
]]

local ui_core = {}

function ui_core.new(monitor, panels)
  local ui = {
    monitor = monitor,
    panels = panels or {},
    current = nil,
    dirty = true
  }

  function ui.set_panel(name)
    ui.current = name
    ui.dirty = true
  end

  function ui.mark_dirty()
    ui.dirty = true
  end

  function ui.draw()
    if not ui.dirty or not ui.current then
      return
    end
    local panel = ui.panels[ui.current]
    if panel and panel.draw then
      panel.draw(ui.monitor)
    end
    ui.dirty = false
  end

  function ui.handle_touch(x, y)
    local panel = ui.panels[ui.current]
    if panel and panel.touch then
      panel.touch(x, y)
      ui.dirty = true
    end
  end

  return ui
end

return ui_core
