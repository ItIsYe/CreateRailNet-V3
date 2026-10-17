--[[
Purpose: Status lamp page: one colour for the whole network, the reasons, per role counts and a paged list of problems.
Public API: new(sources) -> panel with draw(monitor), touch(x, y), model()
  sources: registry, dispatcher, maintenance, ota (function -> ota manager), recovery (function -> { required, confirmed })
Notes: the words GRUEN / GELB / ROT stand next to the colours, so a monochrome monitor shows the same information. Faults are
  listed before nodes that are merely offline. The list pages (touch the left or right half of the bottom row), so a network with
  hundreds of nodes does not overflow the monitor.
]]

local ui_utils = require("src.master.ui.ui_utils")
local status_model = require("src.domain.status_model")

local status_panel = {}

local LAMP = {
  GREEN = { word = "BETRIEB OK", bg = ui_utils.colors.green, fg = ui_utils.colors.white },
  YELLOW = { word = "WARNUNG", bg = ui_utils.colors.yellow, fg = ui_utils.colors.black },
  RED = { word = "STOERUNG", bg = ui_utils.colors.red, fg = ui_utils.colors.white }
}

local TEXT_COLOR = { GREEN = ui_utils.colors.lime, YELLOW = ui_utils.colors.yellow, RED = ui_utils.colors.red }

local function maintenance_on(maintenance)
  if not maintenance then return false end
  if maintenance.is_locked then return maintenance.is_locked() == true end
  if maintenance.status then return maintenance.status().enabled == true end
  return maintenance.enabled == true
end

function status_panel.new(sources)
  local src = sources or {}
  local panel = { page = 1 }
  local C = ui_utils.colors
  local last_pages = 1

  function panel.model()
    local recovery = src.recovery and src.recovery() or nil
    local manager = src.ota and src.ota() or nil
    return status_model.build({
      nodes = src.registry and src.registry.all and src.registry.all() or {},
      blocks = src.dispatcher and src.dispatcher.get_overview and src.dispatcher.get_overview() or {},
      deadlocks = src.dispatcher and src.dispatcher.get_deadlocks and src.dispatcher.get_deadlocks() or {},
      maintenance = maintenance_on(src.maintenance),
      recovery_required = recovery ~= nil and recovery.required == true and recovery.confirmed ~= true,
      ota = manager and manager.status and manager.status() or {}
    })
  end

  local function center(text, w)
    local pad = math.max(0, math.floor((w - #text) / 2))
    return string.rep(" ", pad) .. text
  end

  function panel.draw(monitor)
    if not monitor then return end
    local u = ui_utils.new(monitor)
    local w, h = u.size()
    local m = panel.model()

    u.clear(C.black)
    u.header(1, "STATUS", nil, w)

    local lamp = LAMP[m.lamp]
    for row = 3, 5 do
      u.fill_line(row, lamp.bg, w)
    end
    u.write_at(1, 4, center(lamp.word, w), lamp.fg, lamp.bg)

    local row = 6
    for i = 1, math.min(#m.reasons, 3) do
      u.write_at(2, row, tostring(m.reasons[i]):sub(1, w - 2), TEXT_COLOR[m.lamp] or C.white)
      row = row + 1
    end
    if #m.reasons == 0 then
      u.write_at(2, row, "Keine Stoerungen.", C.lightGray)
      row = row + 1
    end

    row = math.max(row, 9)
    u.write_at(2, row, string.format("Nodes %d/%d online    Bloecke %d, gestoert %d", m.nodes.up, m.nodes.total, m.blocks.total, m.blocks.fault), C.white)
    row = row + 1

    -- role rows, two per line
    local col_width = math.floor((w - 2) / 2)
    for i, r in ipairs(m.roles) do
      local line = row + math.floor((i - 1) / 2)
      if line >= h - 6 then break end
      local x = 2 + ((i - 1) % 2) * col_width
      u.write_at(x, line, string.format("%-9s %d/%d", r.role:sub(1, 9), r.up, r.total), TEXT_COLOR[r.color] or C.white)
    end
    row = row + math.ceil(#m.roles / 2) + 1

    -- problems, paged; faults first
    local list_top = math.min(row, h - 3)
    u.write_at(2, list_top, "PROBLEME", C.cyan)
    local rows_per_page = math.max(1, h - list_top - 2)
    last_pages = math.max(1, math.ceil(#m.problems / rows_per_page))
    if panel.page > last_pages then panel.page = last_pages end
    local first = (panel.page - 1) * rows_per_page + 1
    for i = first, math.min(#m.problems, first + rows_per_page - 1) do
      local p = m.problems[i]
      local line = list_top + 1 + (i - first)
      u.write_at(2, line, (p.severity == "RED" and "!! " or "?  ") .. p.text:sub(1, w - 6), TEXT_COLOR[p.severity] or C.white)
    end
    if #m.problems == 0 then u.write_at(2, list_top + 1, "-", C.lightGray) end

    u.footer(h, string.format("< Seite %d/%d >   %d Probleme", panel.page, last_pages, #m.problems), w)
  end

  function panel.touch(x, y)
    local w, h = 51, 19
    if panel.size then w, h = panel.size() end
    if y ~= h then return end
    if x <= math.floor(w / 2) then panel.page = math.max(1, panel.page - 1) else panel.page = math.min(last_pages, panel.page + 1) end
  end

  -- touch() has no monitor, so it learns the height from the last draw
  local draw = panel.draw
  function panel.draw(monitor)
    if monitor and monitor.getSize then
      local w, h = monitor.getSize()
      panel.size = function() return w, h end
    end
    return draw(monitor)
  end

  return panel
end

return status_panel
