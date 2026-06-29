--[[
Purpose: Shared drawing utilities for CreateRailNet monitor UIs.
Uses CC:Tweaked color API on advanced monitors; falls back to plain text on basic.
Public API: new(monitor) -> utils with color support, drawing helpers.
]]

local ui_utils = {}

-- CC:Tweaked colors
local C = {
  white      = 1,
  orange     = 2,
  magenta    = 4,
  lightBlue  = 8,
  yellow     = 16,
  lime       = 32,
  pink       = 64,
  gray       = 128,
  lightGray  = 256,
  cyan       = 512,
  purple     = 1024,
  blue       = 2048,
  brown      = 4096,
  green      = 8192,
  red        = 16384,
  black      = 32768,
}
ui_utils.colors = C

-- Color themes for different states
ui_utils.STATE_COLORS = {
  FREE       = { fg = C.lime,      bg = C.black },
  RESERVED   = { fg = C.yellow,    bg = C.black },
  OCCUPIED   = { fg = C.orange,    bg = C.black },
  FAULT      = { fg = C.white,     bg = C.red   },
  ONLINE     = { fg = C.lime,      bg = C.black },
  OFFLINE    = { fg = C.gray,      bg = C.black },
  down       = { fg = C.gray,      bg = C.black },
  RUNNING    = { fg = C.lime,      bg = C.black },
  QUEUED     = { fg = C.yellow,    bg = C.black },
  WAITING_FOR_ROUTE = { fg = C.yellow, bg = C.black },
  ROUTE_ASSIGNED    = { fg = C.cyan,   bg = C.black },
  ARRIVED    = { fg = C.lightGray, bg = C.black },
  DWELLING   = { fg = C.cyan,      bg = C.black },
  READY      = { fg = C.lime,      bg = C.black },
  READY_TO_DEPART   = { fg = C.lime,   bg = C.black },
  MAINTENANCE= { fg = C.purple,    bg = C.black },
  EMPTY      = { fg = C.lightGray, bg = C.black },
  UNKNOWN    = { fg = C.gray,      bg = C.black },
}

ui_utils.STATE_SYMBOLS = {
  FREE              = "[  ]",
  RESERVED          = "[RR]",
  OCCUPIED          = "[OO]",
  FAULT             = "[!!]",
  ONLINE            = "  OK",
  OFFLINE           = " OFF",
  down              = " OFF",
  RUNNING           = " >> ",
  QUEUED            = "  Q ",
  WAITING_FOR_ROUTE = "  W ",
  ROUTE_ASSIGNED    = "  A ",
  ARRIVED           = "  . ",
  ARRIVING          = "  v ",
  DWELLING          = "  D ",
  READY             = "  R ",
  READY_TO_DEPART   = "  R ",
  MAINTENANCE       = "  M ",
  EMPTY             = "    ",
  UNKNOWN           = "  ? ",
}

function ui_utils.new(monitor)
  local u = { monitor = monitor }
  local has_color = false

  -- Detect color support
  if monitor and monitor.isColor then
    has_color = pcall(function() return monitor.isColor() end)
    if has_color then
      local ok, v = pcall(function() return monitor.isColor() end)
      has_color = ok and v
    end
  end

  function u.has_color() return has_color end

  function u.set_color(fg, bg)
    if not monitor then return end
    if has_color then
      if fg then pcall(monitor.setTextColor, fg) end
      if bg then pcall(monitor.setBackgroundColor, bg) end
    end
  end

  function u.reset_color()
    if not monitor then return end
    if has_color then
      pcall(monitor.setTextColor, C.white)
      pcall(monitor.setBackgroundColor, C.black)
    end
  end

  function u.write_at(x, y, text, fg, bg)
    if not monitor then return end
    pcall(monitor.setCursorPos, x, y)
    if has_color then
      if fg then pcall(monitor.setTextColor, fg) end
      if bg then pcall(monitor.setBackgroundColor, bg) end
    end
    pcall(monitor.write, text)
    if has_color and (fg or bg) then
      pcall(monitor.setTextColor, C.white)
      pcall(monitor.setBackgroundColor, C.black)
    end
  end

  -- Fill a line with background color
  function u.fill_line(y, bg, w)
    if not monitor or not has_color then return end
    local mw = w or 51
    if monitor.getSize then mw = monitor.getSize() end
    pcall(monitor.setCursorPos, 1, y)
    pcall(monitor.setBackgroundColor, bg)
    pcall(monitor.write, string.rep(" ", mw))
    pcall(monitor.setBackgroundColor, C.black)
  end

  -- Draw a header bar
  function u.header(y, title, page_info, w)
    local mw = w or 51
    if monitor and monitor.getSize then mw = monitor.getSize() end
    u.fill_line(y, C.blue, mw)
    u.write_at(2, y, " " .. tostring(title), C.white, C.blue)
    if page_info then
      local pi = tostring(page_info)
      u.write_at(mw - #pi, y, pi, C.lightGray, C.blue)
    end
  end

  -- Draw a colored status badge
  function u.state_badge(x, y, state)
    local col = ui_utils.STATE_COLORS[tostring(state)] or { fg=C.lightGray, bg=C.black }
    local sym = ui_utils.STATE_SYMBOLS[tostring(state)] or "  ? "
    u.write_at(x, y, sym, col.fg, col.bg)
    return #sym
  end

  -- Draw a horizontal separator
  function u.separator(y, w)
    if not monitor then return end
    local mw = w or 51
    if monitor.getSize then mw = monitor.getSize() end
    u.fill_line(y, C.gray, mw)
    u.write_at(1, y, string.rep("-", mw), C.lightGray, C.gray)
  end

  -- Draw footer bar
  function u.footer(y, text, w)
    local mw = w or 51
    if monitor and monitor.getSize then mw = monitor.getSize() end
    u.fill_line(y, C.gray, mw)
    local t = tostring(text or ""):sub(1, mw-2)
    u.write_at(2, y, t, C.white, C.gray)
  end

  -- Clear screen with optional background
  function u.clear(bg)
    if not monitor then return end
    if has_color and bg then
      pcall(monitor.setBackgroundColor, bg)
    end
    pcall(monitor.clear)
    if has_color then
      pcall(monitor.setBackgroundColor, C.black)
      pcall(monitor.setTextColor, C.white)
    end
  end

  function u.size()
    if monitor and monitor.getSize then
      local w, h = monitor.getSize()
      return w or 51, h or 19
    end
    return 51, 19
  end

  return u
end

return ui_utils
