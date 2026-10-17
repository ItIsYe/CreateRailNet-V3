--[[
Purpose: Network log page: lines, level filter, paging.
Public API: returns table of tests.
]]

pcall(dofile, "tests/harness/cc_bootstrap.lua")

local logs_panel = require("src.master.ui.panels.logs")
local log_collector = require("src.domain.log_collector")

local function recording_monitor(w, h)
  local m = { texts = {} }
  m.getSize = function() return w, h end
  m.isColor = function() return true end
  m.setCursorPos = function() end
  m.setBackgroundColor = function() end
  m.setTextColor = function() end
  m.write = function(text) m.texts[#m.texts + 1] = text end
  m.clear = function() m.texts = {} end
  m.text = function() return table.concat(m.texts, "\n") end
  return m
end

return {
  test_lines_are_shown_with_node_and_repeat_count = function()
    local c = log_collector.new()
    c.ingest("SIG-1", { entries = { { lvl = "WARN", msg = "slow", n = 4 } } })
    local panel = logs_panel.new(c)
    local m = recording_monitor(51, 19)
    panel.draw(m)
    assert(m.text():find("SIG-1", 1, true) and m.text():find("slow x4", 1, true) and m.text():find("1 Zeilen", 1, true))
  end,

  test_level_filter_toggles_with_touch = function()
    local c = log_collector.new()
    c.ingest("A", { entries = { { lvl = "WARN", msg = "only a warning" }, { lvl = "ERROR", msg = "a real error" } } })
    local panel = logs_panel.new(c)
    local m = recording_monitor(51, 19); panel.draw(m)
    assert(m.text():find("only a warning", 1, true))
    panel.touch(3, 19)
    m = recording_monitor(51, 19); panel.draw(m)
    assert(not m.text():find("only a warning", 1, true) and m.text():find("a real error", 1, true))
  end,

  test_paging = function()
    local c = log_collector.new({ rate_per_min = 1000 })
    for i = 1, 40 do c.ingest("N1", { entries = { { lvl = "WARN", msg = string.format("line %02d", i) } } }) end
    local panel = logs_panel.new(c)
    local m = recording_monitor(51, 19); panel.draw(m)
    assert(m.text():find("line 40", 1, true) and not m.text():find("line 01", 1, true))
    panel.touch(45, 19)
    m = recording_monitor(51, 19); panel.draw(m)
    assert(not m.text():find("line 40", 1, true) and m.text():find("Seite 2", 1, true))
    panel.touch(25, 19)
    m = recording_monitor(51, 19); panel.draw(m)
    assert(m.text():find("line 40", 1, true))
  end,

  test_panel_without_collector_does_not_fail = function()
    local m = recording_monitor(51, 19)
    logs_panel.new(nil).draw(m)
    assert(m.text():find("Keine Eintraege", 1, true))
  end
}
