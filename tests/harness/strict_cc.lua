--[[
Purpose: Fakes of the CC:Tweaked peripherals that check their arguments the way the game does. The other fakes of the suite accept anything,
  and the code wraps most calls to monitors in pcall, so a call with the wrong arguments finds out only in the game (and shows up there as an
  empty screen or a silent failure). Here every such call is recorded in `violations` and raises the error CC:Tweaked would raise.
Public API:
  monitor(w, h, opts) -> monitor     opts.color (default true); methods getSize, isColor, setCursorPos, getCursorPos, write, clear, clearLine,
                                     setTextColor, setBackgroundColor, setTextScale; monitor.violations, monitor.row(n), monitor.text(), monitor.touches
  window_api(opts) -> window         the CC window API: window.create(parent, x, y, w, h, visible) -> window with the same methods and setVisible
  modem() -> modem                   open(channel), close, isOpen, transmit(channel, reply, payload); modem.opened, modem.transmitted, modem.violations
  redstone() -> redstone             setOutput(side, boolean), getOutput(side), getInput(side) with the six sides
  peripheral(devices) -> api         devices = { name = { type, methods = {...}, object = table } }; getNames, getType, getMethods, wrap, find, call
  install(fields) -> restore()       puts peripheral / window / redstone / rs into _G (a `fields` table: peripheral, window, redstone), restore() puts the old ones back
Notes: colours must be one of the 16 CC colours (a power of two up to 32768); coordinates and the text scale must be whole numbers / multiples
  of 0.5; text must be a string or a number. Writing beyond the edge is not an error, the text is cut off, like in the game.
]]

local strict_cc = {}

local function describe(value) return type(value) end

local function is_colour(value)
  if type(value) ~= "number" or value < 1 or value > 32768 or value ~= math.floor(value) then return false end
  while value > 1 do
    if value % 2 ~= 0 then return false end
    value = value / 2
  end
  return true
end

local function check_colour(violations, value, name)
  if not is_colour(value) then
    violations[#violations + 1] = name .. ": Colour out of range (" .. tostring(value) .. ")"
    error("Colour out of range", 3)
  end
end

-- the drawing surface that a monitor and a window share
local function surface(w, h, violations, opts)
  local o = opts or {}
  local s = { width = w, height = h, cx = 1, cy = 1, fg = 1, bg = 32768, color = o.color ~= false, chars = {}, fgs = {}, bgs = {} }
  local function blank()
    for y = 1, s.height do
      s.chars[y], s.fgs[y], s.bgs[y] = {}, {}, {}
      for x = 1, s.width do s.chars[y][x], s.fgs[y][x], s.bgs[y][x] = " ", s.fg, s.bg end
    end
  end
  blank()
  local function whole(value, position, name)
    if type(value) ~= "number" or value ~= math.floor(value) then
      violations[#violations + 1] = name .. ": bad argument #" .. position .. " (number with an integer representation expected, got " .. describe(value) .. " " .. tostring(value) .. ")"
      error("bad argument #" .. position .. " to " .. name, 3)
    end
  end
  local api = {}
  function api.getSize() return s.width, s.height end
  function api.isColor() return s.color end
  api.isColour = api.isColor
  function api.setCursorPos(x, y) whole(x, 1, "setCursorPos"); whole(y, 2, "setCursorPos"); s.cx, s.cy = x, y end
  function api.getCursorPos() return s.cx, s.cy end
  function api.write(text)
    if type(text) ~= "string" and type(text) ~= "number" then
      violations[#violations + 1] = "write: bad argument #1 (string expected, got " .. describe(text) .. ")"
      error("bad argument #1 to write (string expected, got " .. describe(text) .. ")", 2)
    end
    text = tostring(text)
    for i = 1, #text do
      local x = s.cx + i - 1
      if s.cy >= 1 and s.cy <= s.height and x >= 1 and x <= s.width then
        s.chars[s.cy][x], s.fgs[s.cy][x], s.bgs[s.cy][x] = text:sub(i, i), s.fg, s.bg
      end
    end
    s.cx = s.cx + #text
  end
  function api.clear() blank() end
  function api.clearLine() if s.cy >= 1 and s.cy <= s.height then for x = 1, s.width do s.chars[s.cy][x], s.fgs[s.cy][x], s.bgs[s.cy][x] = " ", s.fg, s.bg end end end
  function api.setTextColor(value)
    if not s.color then violations[#violations + 1] = "setTextColor on a monitor without colour" end
    check_colour(violations, value, "setTextColor"); s.fg = value
  end
  function api.setBackgroundColor(value)
    if not s.color then violations[#violations + 1] = "setBackgroundColor on a monitor without colour" end
    check_colour(violations, value, "setBackgroundColor"); s.bg = value
  end
  api.setTextColour, api.setBackgroundColour = api.setTextColor, api.setBackgroundColor
  function api.setTextScale(scale)
    if type(scale) ~= "number" or scale < 0.5 or scale > 5 or scale * 2 ~= math.floor(scale * 2) then
      violations[#violations + 1] = "setTextScale: bad scale " .. tostring(scale)
      error("Expected number in range 0.5-5", 2)
    end
  end
  function api.getRow(y)
    local out = {}
    for x = 1, s.width do out[x] = (s.chars[y] and s.chars[y][x]) or " " end
    return table.concat(out)
  end
  return s, api
end

function strict_cc.monitor(w, h, opts)
  local violations = {}
  local s, api = surface(w, h, violations, opts)
  local m = api
  m.violations = violations
  m.touches = {}
  function m.row(n) return (api.getRow(n):gsub("%s+$", "")) end
  function m.text()
    local lines = {}
    for y = 1, s.height do local line = m.row(y); if line ~= "" then lines[#lines + 1] = line end end
    return table.concat(lines, "\n")
  end
  m.surface = s
  return m
end

function strict_cc.window_api()
  local window = {}
  function window.create(parent, x, y, w, h, visible)
    if type(parent) ~= "table" or not parent.write then error("bad argument #1 to create (table expected)", 2) end
    for position, value in ipairs({ x, y, w, h }) do
      if type(value) ~= "number" or value ~= math.floor(value) then error("bad argument #" .. (position + 1) .. " to create (number expected)", 2) end
    end
    local violations = parent.violations or {}
    local s, api = surface(w, h, violations, { color = parent.isColor and parent.isColor() })
    local shown = visible ~= false
    function api.setVisible(flag)
      shown = flag and true or false
      if shown then
        -- the whole window is drawn on the parent
        for row = 1, h do
          local column = 1
          while column <= w do
            local fg, bg = s.fgs[row][column], s.bgs[row][column]
            local last = column
            while last < w and s.fgs[row][last + 1] == fg and s.bgs[row][last + 1] == bg do last = last + 1 end
            parent.setCursorPos(x + column - 1, y + row - 1)
            if parent.isColor and parent.isColor() then parent.setTextColor(fg); parent.setBackgroundColor(bg) end
            parent.write(api.getRow(row):sub(column, last))
            column = last + 1
          end
        end
      end
    end
    function api.isVisible() return shown end
    function api.getPosition() return x, y end
    return api
  end
  return window
end

function strict_cc.modem()
  local m = { opened = {}, transmitted = {}, violations = {} }
  local function number(value, position, name)
    if type(value) ~= "number" then
      m.violations[#m.violations + 1] = name .. ": bad argument #" .. position .. " (number expected, got " .. type(value) .. ")"
      error("bad argument #" .. position .. " (number expected, got " .. type(value) .. ") in " .. name, 3)
    end
  end
  function m.open(channel) number(channel, 1, "open"); m.opened[channel] = true end
  function m.close(channel) number(channel, 1, "close"); m.opened[channel] = nil end
  function m.isOpen(channel) number(channel, 1, "isOpen"); return m.opened[channel] == true end
  function m.closeAll() m.opened = {} end
  function m.transmit(channel, reply, payload)
    number(channel, 1, "transmit"); number(reply, 2, "transmit")
    m.transmitted[#m.transmitted + 1] = { channel = channel, reply = reply, payload = payload }
  end
  return m
end

local SIDES = { top = true, bottom = true, left = true, right = true, front = true, back = true }

function strict_cc.redstone()
  local r = { outputs = {}, inputs = {}, violations = {} }
  local function side(value, name)
    if not SIDES[value] then
      r.violations[#r.violations + 1] = name .. ": Invalid side (" .. tostring(value) .. ")"
      error("Invalid side.", 3)
    end
  end
  function r.setOutput(name, value)
    side(name, "setOutput")
    if type(value) ~= "boolean" then r.violations[#r.violations + 1] = "setOutput: boolean expected"; error("bad argument #2 (boolean expected)", 2) end
    r.outputs[name] = value
  end
  function r.getOutput(name) side(name, "getOutput"); return r.outputs[name] == true end
  function r.getInput(name) side(name, "getInput"); return r.inputs[name] == true end
  return r
end

function strict_cc.peripheral(devices)
  local api = {}
  local function sorted()
    local names = {}
    for name in pairs(devices) do names[#names + 1] = name end
    table.sort(names)
    return names
  end
  function api.getNames() return sorted() end
  function api.getType(name) local d = devices[name]; return d and d.type or nil end
  function api.getMethods(name)
    local d = devices[name]
    if not d then return nil end
    return d.methods or {}
  end
  function api.wrap(name) local d = devices[name]; return d and d.object or nil end
  function api.find(kind)
    for _, name in ipairs(sorted()) do
      if devices[name].type == kind then return devices[name].object, name end
    end
    return nil
  end
  function api.call(name, method, ...)
    local d = devices[name]
    if not d then error("No peripheral attached", 2) end
    local f = d.object and d.object[method]
    if type(f) ~= "function" then error("No such method " .. tostring(method), 2) end
    return f(...)
  end
  api.isPresent = function(name) return devices[name] ~= nil end
  return api
end

-- puts the fakes into the global environment (the code reads _G.peripheral, _G.window, _G.redstone); returns the function that undoes it
function strict_cc.install(fields)
  local saved = { peripheral = _G.peripheral, window = _G.window, redstone = _G.redstone, rs = _G.rs }
  if fields.peripheral then _G.peripheral = fields.peripheral end
  if fields.window then _G.window = fields.window end
  if fields.redstone then _G.redstone = fields.redstone; _G.rs = fields.redstone end
  return function()
    _G.peripheral, _G.window, _G.redstone, _G.rs = saved.peripheral, saved.window, saved.redstone, saved.rs
  end
end

return strict_cc
