--[[
Purpose: Terminal output and input of the setup wizard: pages that fit a 51 x 19 computer screen, word wrap, colours where the screen has them.
Public API: new(env) -> terminal
  env: print(text), write(text), read() -> line | nil, term (optional CC term api), colors (optional CC colors api), width, height (optional overrides)
  terminal.width(), terminal.height()
  terminal.page(title, trail, current)     clears the screen; header "CreateRailNet  title", the trail of step names with the current one in
                                           [ ] (names of steps that do not apply are simply not in the trail), and a rule
  terminal.say(text, kind)                 wrapped to the width; kind nil | "dim" | "ok" | "err" | "title"
  terminal.aside(title) -> done()          a page of its own (help); done() makes the page before it current again
  terminal.restore()                       draws the current page again as it was
  terminal.blank()
  terminal.ask(prompt) -> string           one line; "" when the player just presses Enter, nil when input ends
  terminal.wrap(text, width) -> lines
Notes: ASCII only. CC:Tweaked draws bytes, not UTF-8, so box characters and typographic dashes show up as junk.
  A text that is longer than a line is wrapped; leading blanks of a line are kept as a hanging indent.
]]

local terminal = {}

local DEFAULT_WIDTH, DEFAULT_HEIGHT = 51, 19

function terminal.wrap(text, width)
  local lines = {}
  for raw in (tostring(text) .. "\n"):gmatch("([^\n]*)\n") do
    local indent = raw:match("^(%s*)") or ""
    local body = raw:sub(#indent + 1)
    if body == "" then
      lines[#lines + 1] = ""
    elseif #raw <= width then
      -- fits: kept exactly as written (columns made with blanks stay columns)
      lines[#lines + 1] = (raw:gsub("%s+$", ""))
    else
      local room = math.max(10, width - #indent)
      local line = ""
      for word in body:gmatch("%S+") do
        while #word > room do
          -- a word longer than the line (a path): cut it
          if line ~= "" then lines[#lines + 1] = indent .. line; line = "" end
          lines[#lines + 1] = indent .. word:sub(1, room)
          word = word:sub(room + 1)
        end
        if line == "" then line = word
        elseif #line + 1 + #word <= room then line = line .. " " .. word
        else lines[#lines + 1] = indent .. line; line = word end
      end
      if line ~= "" then lines[#lines + 1] = indent .. line end
    end
  end
  return lines
end

function terminal.new(env)
  local self = {}
  local term_api = env.term
  local colors_api = env.colors

  local function size()
    if term_api and term_api.getSize then
      local ok, w, h = pcall(term_api.getSize)
      if ok and type(w) == "number" then return w, h end
    end
    return DEFAULT_WIDTH, DEFAULT_HEIGHT
  end

  function self.width() return env.width or math.min(80, math.max(30, (size()))) end
  function self.height() return env.height or select(2, size()) or DEFAULT_HEIGHT end

  local function colored(name)
    if not (term_api and term_api.isColor and term_api.setTextColor and colors_api) then return end
    local ok, color = pcall(term_api.isColor)
    if ok and color and colors_api[name] then pcall(term_api.setTextColor, colors_api[name]) end
  end

  local KIND_COLOR = { title = "yellow", ok = "lime", err = "red", dim = "lightGray" }

  local current_page = nil

  local function emit(text, kind)
    local width = self.width() - 1
    colored(KIND_COLOR[kind] or "white")
    for _, line in ipairs(terminal.wrap(text, width)) do env.print(line) end
    colored("white")
  end

  function self.say(text, kind)
    if current_page then current_page.lines[#current_page.lines + 1] = { text, kind } end
    emit(text, kind)
  end

  function self.blank()
    if current_page then current_page.lines[#current_page.lines + 1] = { "" } end
    env.print("")
  end

  local function draw_header(title, trail, current)
    if term_api and term_api.clear and term_api.setCursorPos then
      pcall(term_api.clear)
      pcall(term_api.setCursorPos, 1, 1)
    end
    local head = "CreateRailNet"
    if title and title ~= "" then head = head .. "  " .. title end
    emit(head, "title")
    if trail and #trail > 0 then
      local names = {}
      for _, name in ipairs(trail) do names[#names + 1] = name == current and ("[" .. name .. "]") or name end
      local line = table.concat(names, "  ")
      if #line > self.width() - 1 then line = table.concat(names, " ") end
      emit(line, "dim")
    end
    emit(string.rep("-", self.width() - 1), "dim")
  end

  function self.page(title, trail, current)
    current_page = { title = title, trail = trail, current = current, lines = {} }
    draw_header(title, trail, current)
  end

  -- a page that does not become the one restore() brings back (help screens)
  function self.aside(title)
    local keep = current_page
    current_page = nil
    draw_header(title)
    return function() current_page = keep end
  end

  -- draws the current page again as it was (after a help screen)
  function self.restore()
    if not current_page then return end
    draw_header(current_page.title, current_page.trail, current_page.current)
    for _, line in ipairs(current_page.lines) do emit(line[1], line[2]) end
  end

  function self.ask(prompt)
    colored("lightBlue")
    env.write(prompt)
    colored("white")
    local line = env.read()
    if line == nil then return nil end
    return (tostring(line):gsub("^%s+", ""):gsub("%s+$", ""))
  end

  return self
end

return terminal
