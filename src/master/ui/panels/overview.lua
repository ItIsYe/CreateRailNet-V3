--[[
Purpose: Overview panel for block status and node health.
Public API: new(dispatcher, registry).
]]

local overview = {}

-- State color indicators
local STATE_SYMBOLS = {
  FREE     = "+",
  RESERVED = "R",
  OCCUPIED = "O",
  FAULT    = "!",
  ONLINE   = ".",
  OFFLINE  = "x",
  down     = "x",
}

local function symbol(state)
  return STATE_SYMBOLS[tostring(state)] or "?"
end

function overview.new(dispatcher, registry)
  local panel = {}

  function panel.draw(monitor)
    if not monitor then return end
    local w, h = 51, 19
    if monitor.getSize then w, h = monitor.getSize() end
    monitor.clear()

    -- Header
    monitor.setCursorPos(1, 1)
    monitor.write("== OVERVIEW ==  [touch: next page]")

    -- Left column: Blocks
    local row = 3
    monitor.setCursorPos(1, row); monitor.write("BLOCKS"); row = row + 1
    local bdata = dispatcher and dispatcher.get_overview and dispatcher.get_overview() or {}
    local sorted_blocks = {}
    for id, b in pairs(bdata) do table.insert(sorted_blocks, {id=id, b=b}) end
    table.sort(sorted_blocks, function(a,b) return a.id < b.id end)
    for _, entry in ipairs(sorted_blocks) do
      if row > h - 3 then break end
      local s = symbol(entry.b.state)
      local owner = entry.b.occupied_by or entry.b.reserved_by or ""
      monitor.setCursorPos(1, row)
      monitor.write(string.format("%s %s %s", s, entry.id:sub(1,10), owner:sub(1,8)))
      row = row + 1
    end

    -- Right column: Nodes
    local nrow = 3
    local nodes = registry and registry.all and registry.all() or {}
    local sorted_nodes = {}
    for id, n in pairs(nodes) do table.insert(sorted_nodes, {id=id, n=n}) end
    table.sort(sorted_nodes, function(a,b) return a.id < b.id end)
    local col2 = math.floor(w/2) + 2
    monitor.setCursorPos(col2, nrow); monitor.write("NODES"); nrow = nrow + 1
    for _, entry in ipairs(sorted_nodes) do
      if nrow > h - 3 then break end
      local s = symbol(entry.n.status)
      monitor.setCursorPos(col2, nrow)
      monitor.write(string.format("%s %s %s", s, (entry.n.role or "?"):sub(1,7), entry.id:sub(1,8)))
      nrow = nrow + 1
    end

    -- Footer
    monitor.setCursorPos(1, h)
    monitor.write("FREE:+ RESV:R OCCUP:O FAULT:!")
  end

  function panel.touch(x, y)
    -- Touch on overview does nothing special; page switching handled by ui_core
  end

  return panel
end

return overview
