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
    dirty = true,
    page_order = {}
  }

  -- Build ordered page list for navigation
  local function rebuild_order()
    ui.page_order = {}
    for name, _ in pairs(ui.panels) do
      table.insert(ui.page_order, name)
    end
    table.sort(ui.page_order)
  end

  function ui.set_panel(name)
    ui.current = name
    ui.dirty = true
  end

  function ui.next_panel()
    if #ui.page_order == 0 then rebuild_order() end
    for i, name in ipairs(ui.page_order) do
      if name == ui.current then
        local next_i = (i % #ui.page_order) + 1
        ui.set_panel(ui.page_order[next_i])
        return
      end
    end
    if #ui.page_order > 0 then ui.set_panel(ui.page_order[1]) end
  end

  function ui.prev_panel()
    if #ui.page_order == 0 then rebuild_order() end
    for i, name in ipairs(ui.page_order) do
      if name == ui.current then
        local prev_i = ((i - 2) % #ui.page_order) + 1
        ui.set_panel(ui.page_order[prev_i])
        return
      end
    end
    if #ui.page_order > 0 then ui.set_panel(ui.page_order[#ui.page_order]) end
  end

  function ui.mark_dirty()
    ui.dirty = true
  end

  function ui.draw()
    if not ui.dirty or not ui.current then return end
    local panel = ui.panels[ui.current]
    if panel and panel.draw then panel.draw(ui.monitor) end
    -- Draw page indicator at top-right
    if ui.monitor and ui.monitor.getSize and ui.monitor.setCursorPos and ui.monitor.write then
      local w = ui.monitor.getSize()
      if #ui.page_order == 0 then rebuild_order() end
      local idx = 0
      for i, name in ipairs(ui.page_order) do
        if name == ui.current then idx = i; break end
      end
      local nav = string.format("<%d/%d>", idx, #ui.page_order)
      local col = math.max(1, w - #nav)
      pcall(function()
        ui.monitor.setCursorPos(col, 1)
        ui.monitor.write(nav)
      end)
    end
    ui.dirty = false
  end

  function ui.handle_touch(x, y)
    local w = 51
    if ui.monitor and ui.monitor.getSize then w = ui.monitor.getSize() end
    -- Left edge (x <= 2): previous page
    -- Right edge (x >= w-1): next page
    if x <= 2 then
      ui.prev_panel()
      return
    elseif x >= w - 1 then
      ui.next_panel()
      return
    end
    -- Pass touch to current panel
    local panel = ui.panels[ui.current]
    if panel and panel.touch then
      panel.touch(x, y)
      ui.dirty = true
    end
  end

  rebuild_order()
  return ui
end

return ui_core
