--[[
Purpose: Overview panel for block status and node health.
Public API: new(dispatcher, registry).
]]

local overview = {}

function overview.new(dispatcher, registry)
  local panel = {}

  function panel.draw(monitor)
    if not monitor then return end
    monitor.clear()
    monitor.setCursorPos(1, 1)
    monitor.write("Blocks")
    local row = 2
    local overview = dispatcher and dispatcher.get_overview and dispatcher.get_overview() or {}
    for id, block in pairs(overview) do
      monitor.setCursorPos(1, row)
      monitor.write(string.format("%s: %s", id, block.state or "?"))
      row = row + 1
    end
    row = row + 1
    monitor.setCursorPos(1, row)
    monitor.write("Nodes")
    row = row + 1
    local nodes = registry and registry.all and registry.all() or {}
    for id, node in pairs(nodes) do
      monitor.setCursorPos(1, row)
      monitor.write(string.format("%s: %s", id, node.status or "?"))
      row = row + 1
    end
  end

  function panel.touch()
    -- placeholder for future interactions
  end

  return panel
end

return overview
