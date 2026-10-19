--[[
Purpose: Terminal output and questions of the installer: lines that fit the screen, colours where the screen has them, one progress line.
Public API: new(env) -> ui
  env: print(text), write(text), read() -> line; term (optional CC term api), colors (optional CC colors api), width (optional override)
  ui.header(title), ui.info(text), ui.warn(text), ui.error(text), ui.ok(text)
  ui.progress(done, total, label)       one line that is rewritten in place (a line per 10 % where the screen cannot do that)
  ui.progress_done()                    ends that line; every other line does it by itself
  ui.select_role(roles) -> key | nil    numbered menu
  ui.confirm(question, default_yes) -> boolean
Notes: ASCII only. Long messages are wrapped at word borders with a hanging indent, so nothing breaks in the middle of a word at the
  edge of the screen. This module cannot use src/ (the installer loads it before anything else is there), hence its own small helpers.
]]

local ui_module = {}

local DEFAULT_WIDTH = 51

-- text wrapped to `width`; the continuation lines are indented by `indent` blanks; a word longer than the line is cut
function ui_module.wrap(text, width, indent)
  text = tostring(text)
  local pad = string.rep(" ", indent or 0)
  local lines = {}
  for raw in (text .. "\n"):gmatch("([^\n]*)\n") do
    if #raw <= width then
      lines[#lines + 1] = raw
    else
      local line = ""
      local first = true
      local function flush()
        lines[#lines + 1] = (first and "" or pad) .. line
        first = false
        line = ""
      end
      for word in raw:gmatch("%S+") do
        local room = width - (first and 0 or #pad)
        while #word > room do
          if line ~= "" then flush() end
          line = word:sub(1, room)
          word = word:sub(room + 1)
          flush()
          room = width - #pad
        end
        if line == "" then line = word
        elseif #line + 1 + #word <= room then line = line .. " " .. word
        else flush(); line = word end
      end
      if line ~= "" then flush() end
    end
  end
  return lines
end

function ui_module.new(env)
  local self = {}
  local term_api = env.term
  local colors_api = env.colors
  local open_row = nil       -- the row of a progress line that is still open
  local last_step = -1       -- progress without cursor control: the last 10 % step that was printed

  local function width()
    if env.width then return env.width end
    if term_api and term_api.getSize then
      local ok, w = pcall(term_api.getSize)
      if ok and type(w) == "number" then return w end
    end
    return DEFAULT_WIDTH
  end

  local function colored(name)
    if not (term_api and term_api.isColor and term_api.setTextColor and colors_api) then return end
    local ok, color = pcall(term_api.isColor)
    if ok and color and colors_api[name] then pcall(term_api.setTextColor, colors_api[name]) end
  end

  local live = term_api and term_api.getCursorPos and term_api.setCursorPos and term_api.clearLine

  function self.progress_done()
    if open_row then
      pcall(env.print, "")
      open_row = nil
    end
  end

  local function say(text, kind, indent)
    self.progress_done()
    colored(kind or "white")
    for _, line in ipairs(ui_module.wrap(text, width() - 1, indent)) do pcall(env.print, line) end
    colored("white")
  end

  function self.header(title) say(""); say(tostring(title), "yellow"); say("") end
  function self.info(text) say("[INFO] " .. tostring(text), "white", 7) end
  function self.warn(text) say("[WARN] " .. tostring(text), "orange", 7) end
  function self.error(text) say("[ERR ] " .. tostring(text), "red", 7) end
  function self.ok(text) say("[ OK ] " .. tostring(text), "lime", 7) end

  function self.progress(done, total, label)
    local percent = total > 0 and math.floor(done / total * 100) or 100
    local head = string.format("  [%3d%%] %d/%d ", percent, done, total)
    local room = width() - 1 - #head
    label = tostring(label or "")
    if #label > room then label = "..." .. label:sub(-math.max(1, room - 3)) end
    local line = head .. label
    if live then
      if not open_row then
        local _, row = term_api.getCursorPos()
        open_row = row
      end
      pcall(term_api.setCursorPos, 1, open_row)
      pcall(term_api.clearLine)
      pcall(env.write, line)
    else
      local step = math.floor(percent / 10)
      if step ~= last_step or done == total then
        pcall(env.print, line)
        last_step = step
      end
    end
  end

  function self.select_role(roles)
    say("")
    for i, role in ipairs(roles) do say(string.format("  %d) %-8s %s", i, role.label, role.text), "white", 5) end
    say("")
    colored("lightBlue")
    pcall(env.write, "Rolle dieses Computers [1-" .. #roles .. "]: ")
    colored("white")
    local choice = tonumber(env.read() or "")
    if choice and roles[choice] then return roles[choice].key end
    return nil
  end

  function self.confirm(question, default_yes)
    local hint = default_yes and "[J/n]" or "[j/N]"
    self.progress_done()
    while true do
      colored("lightBlue")
      pcall(env.write, question .. " " .. hint .. ": ")
      colored("white")
      local answer = tostring(env.read() or ""):lower()
      if answer == "" then return default_yes == true end
      if answer == "j" or answer == "ja" or answer == "y" or answer == "yes" then return true end
      if answer == "n" or answer == "nein" or answer == "no" then return false end
      say("Bitte j oder n eingeben.")
    end
  end

  return self
end

return ui_module
