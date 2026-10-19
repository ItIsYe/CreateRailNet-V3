--[[
Purpose: What the installer shows: lines that fit a 51 column screen, one progress line that is rewritten in place (or a line per 10 %
  where the screen cannot do that), colours, and the role menu in the words of the wizard.
Public API: returns table of tests.
]]

pcall(dofile, "tests/harness/cc_bootstrap.lua")

local ui_module = dofile("install/ui.lua")
local plan = dofile("install/plan.lua")

-- a recording environment; with_term gives it the cursor and colour calls of a CC:Tweaked terminal
local function fake(with_term, width)
  local events = {}
  local env = {
    print = function(text) events[#events + 1] = { "print", tostring(text) } end,
    write = function(text) events[#events + 1] = { "write", tostring(text) } end,
    read = function() return "" end,
    width = width,
  }
  if with_term then
    local row = 5
    env.term = {
      getSize = function() return width or 51, 19 end,
      getCursorPos = function() return 1, row end,
      setCursorPos = function(x, y) events[#events + 1] = { "pos", x, y } end,
      clearLine = function() events[#events + 1] = { "clear" } end,
      isColor = function() return true end,
      setTextColor = function(color) events[#events + 1] = { "color", color } end,
    }
    env.colors = { white = 1, yellow = 16, orange = 2, lime = 32, red = 16384, lightBlue = 8 }
  end
  return env, events
end

local function printed(events)
  local lines = {}
  for _, event in ipairs(events) do if event[1] == "print" then lines[#lines + 1] = event[2] end end
  return lines
end

return {
  test_wrap_breaks_at_words_keeps_short_lines_and_cuts_long_words = function()
    assert(ui_module.wrap("kurz", 50)[1] == "kurz")
    local text = "Der Speicher dieses Computers reicht nicht: gebraucht 546 KB, frei 195 KB (es fehlen 351 KB). Nichts wurde veraendert."
    local lines = ui_module.wrap(text, 50, 7)
    assert(#lines >= 2)
    for index, line in ipairs(lines) do
      assert(#line <= 50, line)
      if index > 1 then assert(line:sub(1, 7) == "       ", "hanging indent: " .. line) end
    end
    local joined = {}
    for _, line in ipairs(lines) do joined[#joined + 1] = (line:gsub("^%s+", "")) end
    assert(table.concat(joined, " ") == text, "no word lost or split")
    local path = ui_module.wrap("configs/templates/network.service_plan.example.json", 20, 2)
    for _, line in ipairs(path) do assert(#line <= 20, line) end
    assert((table.concat(path):gsub("%s", "")) == "configs/templates/network.service_plan.example.json")
    assert(ui_module.wrap("a\nb", 10)[2] == "b", "explicit line breaks stay")
  end,

  test_messages_are_wrapped_to_the_screen_with_the_hanging_indent_of_their_tag = function()
    local env, events = fake(false)
    local ui = ui_module.new(env)
    ui.error("Der Speicher dieses Computers reicht nicht: gebraucht 546 KB, frei 195 KB (es fehlen 351 KB). Nichts wurde veraendert.")
    local lines = printed(events)
    assert(#lines >= 2 and lines[1]:sub(1, 6) == "[ERR ]" and lines[2]:sub(1, 7) == "       ")
    for _, line in ipairs(lines) do assert(#line <= 50, line) end
  end,

  test_progress_is_one_line_rewritten_in_place_and_closed_before_anything_else = function()
    local env, events = fake(true)
    local ui = ui_module.new(env)
    ui.progress(1, 87, "src/shared/net.lua")
    ui.progress(2, 87, "src/shared/log.lua")
    ui.progress(3, 87, "configs/templates/network.service_plan.example.json")
    local before = #printed(events)
    assert(before == 0, "no line of its own for the steps")
    local writes, positions, clears = {}, 0, 0
    for _, event in ipairs(events) do
      if event[1] == "write" then writes[#writes + 1] = event[2] end
      if event[1] == "pos" then positions = positions + 1; assert(event[2] == 1 and event[3] == 5, "always the same row") end
      if event[1] == "clear" then clears = clears + 1 end
    end
    assert(#writes == 3 and positions == 3 and clears == 3)
    for _, line in ipairs(writes) do assert(#line <= 50, line) end
    assert(writes[3]:find("...", 1, true) and writes[3]:sub(-12) == "example.json", "a long path keeps its end: " .. writes[3])
    -- the next message ends the progress line first
    ui.info("weiter")
    local lines = printed(events)
    assert(lines[1] == "" and lines[2] == "[INFO] weiter", "the open line is closed by a newline")
    -- closing twice prints nothing more
    ui.progress_done()
    assert(#printed(events) == 2)
    ui.progress(4, 87, "x")
    ui.progress_done()
    assert(#printed(events) == 3)
  end,

  test_a_screen_without_cursor_control_gets_a_line_per_ten_percent_and_the_last = function()
    local env, events = fake(false)
    local ui = ui_module.new(env)
    for i = 1, 87 do ui.progress(i, 87, "datei" .. i) end
    local lines = printed(events)
    assert(#lines >= 10 and #lines <= 12, #lines)
    assert(lines[#lines]:find("87/87", 1, true), "the last step is always shown")
    for _, line in ipairs(lines) do assert(#line <= 50, line) end
  end,

  test_the_role_menu_fits_the_screen_and_uses_the_words_of_the_wizard = function()
    local env, events = fake(false)
    local ui = ui_module.new(env)
    env.read = function() return "3" end
    local key = ui.select_role(plan.ROLES)
    assert(key == "sensor")
    local lines = printed(events)
    for _, line in ipairs(lines) do assert(#line <= 50, line) end
    local text = table.concat(lines, "\n")
    assert(text:find("1) Master", 1, true) and text:find("3) Melder", 1, true) and text:find("8) Monitor", 1, true))
    assert(not text:find("MASTER", 1, true))
    env.read = function() return "x" end
    assert(ui.select_role(plan.ROLES) == nil)
  end,

  test_colours_are_used_where_the_screen_has_them_and_reset_after_each_line = function()
    local env, events = fake(true)
    local ui = ui_module.new(env)
    ui.ok("fertig")
    ui.error("kaputt")
    local colors = {}
    for _, event in ipairs(events) do if event[1] == "color" then colors[#colors + 1] = event[2] end end
    assert(colors[1] == 32 and colors[2] == 1 and colors[3] == 16384 and colors[4] == 1, table.concat(colors, ","))
    -- a screen without colours works the same
    local plain, plain_events = fake(false)
    ui_module.new(plain).ok("fertig")
    assert(printed(plain_events)[1] == "[ OK ] fertig")
  end,

  test_confirm_closes_an_open_progress_line_and_asks_again_on_nonsense = function()
    local env, events = fake(true)
    local answers = { "vielleicht", "j" }
    env.read = function() return table.remove(answers, 1) end
    local ui = ui_module.new(env)
    ui.progress(1, 2, "datei")
    assert(ui.confirm("Weiter?", false) == true)
    local lines = printed(events)
    assert(lines[1] == "" and lines[2] == "Bitte j oder n eingeben.", table.concat(lines, "|"))
  end,
}
