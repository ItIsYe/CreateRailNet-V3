--[[
Purpose: Overview panel for block status and node health.
Public API: new(dispatcher, registry).
]]

local overview = {}

function overview.new(dispatcher, registry)
  local panel = {}

  function panel.draw(monitor)
    monitor.clear()
    monitor.setCursorPos(1, 1)
    monitor.write("Blocks")
    local row = 2
    for id, block in pairs(dispatcher.get_overview()) do
      monitor.setCursorPos(1, row)
      monitor.write(string.format("%s: %s", id, block.state))
      row = row + 1
    end
    row = row + 1
    monitor.setCursorPos(1, row)
    monitor.write("Nodes")
    row = row + 1
    for id, node in pairs(registry.all()) do
      monitor.setCursorPos(1, row)
      monitor.write(string.format("%s: %s", id, node.status))
      row = row + 1
    end
  end

  function panel.touch()
    -- placeholder for future interactions
  end

  return panel
end

return overview
