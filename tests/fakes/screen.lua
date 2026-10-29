--[[
Purpose: Fake fuer Terminal und Monitor (term-aehnlich): feste Groesse, Zeichen und Farben je Zelle, blit, Palette, isColour. Tests lesen den Bildschirm als Text.
API: screen.new(w, h, opts) -> s (opts.colour = false fuer Schwarz/Weiss, opts.blit = false ohne blit); s.rows(), s.text(), s.cell(x, y), s.writes
]]

local M = {}

function M.new(w, h, opts)
  opts = opts or {}
  local s = { w = w, h = h, writes = 0, palette = {}, cx = 1, cy = 1 }
  local ch, fg, bg = {}, {}, {}
  local cur_fg, cur_bg = 1, 32768
  for y = 1, h do
    ch[y], fg[y], bg[y] = {}, {}, {}
    for x = 1, w do ch[y][x], fg[y][x], bg[y][x] = " ", 1, 32768 end
  end
  function s.getSize() return w, h end
  function s.setCursorPos(x, y) s.cx, s.cy = x, y end
  function s.getCursorPos() return s.cx, s.cy end
  function s.setTextColour(c) cur_fg = c end
  function s.setBackgroundColour(c) cur_bg = c end
  function s.write(text)
    s.writes = s.writes + 1
    for i = 1, #text do
      local x = s.cx + i - 1
      if x >= 1 and x <= w and s.cy >= 1 and s.cy <= h then
        ch[s.cy][x], fg[s.cy][x], bg[s.cy][x] = text:sub(i, i), cur_fg, cur_bg
      end
    end
    s.cx = s.cx + #text
  end
  if opts.blit ~= false then
    function s.blit(text, f, b)
      s.writes = s.writes + 1
      for i = 1, #text do
        local x = s.cx + i - 1
        if x >= 1 and x <= w and s.cy >= 1 and s.cy <= h then
          ch[s.cy][x] = text:sub(i, i)
          fg[s.cy][x] = 2 ^ tonumber(f:sub(i, i), 16)
          bg[s.cy][x] = 2 ^ tonumber(b:sub(i, i), 16)
        end
      end
      s.cx = s.cx + #text
    end
  end
  function s.clear()
    for y = 1, h do for x = 1, w do ch[y][x] = " " end end
  end
  if opts.colour ~= false then
    function s.isColour() return true end
    function s.setPaletteColour(c, r, g, b) s.palette[c] = { r, g, b } end
  else
    function s.isColour() return false end
  end
  function s.rows()
    local out = {}
    for y = 1, h do out[y] = table.concat(ch[y]) end
    return out
  end
  function s.text() return table.concat(s.rows(), "\n") end
  function s.cell(x, y) return ch[y][x], fg[y][x], bg[y][x] end
  return s
end

return M
