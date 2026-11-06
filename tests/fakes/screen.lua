--[[
Purpose: Fake fuer Terminal und Monitor (term-aehnlich): feste Groesse, Zeichen und Farben je Zelle, blit, Palette, isColour. Tests lesen den Bildschirm als Text.
API: screen.new(w, h, opts) -> s (opts.colour = false fuer Schwarz/Weiss, opts.blit = false ohne blit); s.rows(), s.text(), s.cell(x, y), s.writes
Monitor mit Bloecken: opts.blocks = { breite, hoehe } (Bloecke, Textgroesse 1,0 gibt w und h vor) liefert setTextScale/getTextScale wie das Spiel (Vielfaches von 0,5 zwischen 0,5 und 5; Raster nach der Rechnung aus ServerMonitor.rebuild, docs/MESSWERTE.md Q02); aendert sich die Groesse, wird der Inhalt geleert und opts.on_resize(s) gerufen (im Spiel kommt dann das Ereignis monitor_resize).
]]

local M = {}

function M.new(w, h, opts)
  opts = opts or {}
  local s = { w = w, h = h, writes = 0, palette = {}, cx = 1, cy = 1 }
  local ch, fg, bg = {}, {}, {}
  local cur_fg, cur_bg = 1, 32768
  local function fresh()
    ch, fg, bg = {}, {}, {}
    for y = 1, h do
      ch[y], fg[y], bg[y] = {}, {}, {}
      for x = 1, w do ch[y][x], fg[y][x], bg[y][x] = " ", 1, 32768 end
    end
  end
  fresh()
  function s.getSize() return w, h end
  if opts.blocks then
    local scale = 1
    -- Raster aus Bloecken und Textgroesse wie im Spiel: Runden((Bloecke - 0,3125) / (Textgroesse x Zeichen in Punkten / 64)), 6x9 Punkte je Zeichen
    local function grid(blocks, points) return math.max(1, math.floor((blocks - 0.3125) * 64 / (scale * points) + 0.5)) end
    function s.getTextScale() return scale end
    function s.setTextScale(value)
      if type(value) ~= "number" then error("bad argument #1 (number expected, got " .. type(value) .. ")", 2) end
      if value < 0.5 or value > 5 or value * 2 ~= math.floor(value * 2) then error("Expected number in range 0.5-5 in steps of 0.5", 2) end
      scale = value
      local nw, nh = grid(opts.blocks[1], 6), grid(opts.blocks[2], 9)
      if nw ~= w or nh ~= h then
        w, h = nw, nh
        s.w, s.h = w, h
        fresh()
        if opts.on_resize then opts.on_resize(s) end
      end
    end
  end
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
    -- wie CC: entweder (farbe, r, g, b) mit Werten 0..1 oder (farbe, 0xRRGGBB)
    function s.setPaletteColour(c, r, g, b)
      if g == nil then r, g, b = math.floor(r / 65536) % 256 / 255, math.floor(r / 256) % 256 / 255, r % 256 / 255 end
      s.palette[c] = { r, g, b }
    end
    function s.getPaletteColour(c)
      local p = s.palette[c]
      if p then return p[1], p[2], p[3] end
      return 1, 1, 1
    end
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
