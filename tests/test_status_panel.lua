--[[
Purpose: status panel tests: lamp word and colour, reasons, problem paging, monochrome monitor, app wiring.
Public API: returns table of tests.
]]

pcall(dofile, "tests/harness/cc_bootstrap.lua")

local status_panel = require("src.master.ui.panels.status")

local function recording_monitor(w, h, color)
  local m = { texts = {}, backgrounds = {}, size = { w, h } }
  local x, y, bg = 1, 1, 32768
  m.getSize = function() return m.size[1], m.size[2] end
  m.isColor = function() return color ~= false end
  m.setCursorPos = function(cx, cy) x, y = cx, cy end
  m.setBackgroundColor = function(c) bg = c end
  m.setTextColor = function() end
  m.write = function(text)
    m.texts[#m.texts + 1] = text
    m.backgrounds[#m.backgrounds + 1] = { y = y, bg = bg, text = text }
  end
  m.clear = function() m.texts = {}; m.backgrounds = {} end
  m.text = function() return table.concat(m.texts, "\n") end
  return m
end

local function sources(nodes, blocks, extra)
  local s = {
    registry = { all = function() return nodes end },
    dispatcher = { get_overview = function() return blocks or {} end, get_deadlocks = function() return {} end }
  }
  for k, v in pairs(extra or {}) do s[k] = v end
  return s
end

return {
  test_healthy_network_shows_the_green_word = function()
    local panel = status_panel.new(sources({ SIG1 = { role = "signal", status = "up" } }))
    local m = recording_monitor(51, 19)
    panel.draw(m)
    assert(m.text():find("BETRIEB OK", 1, true) and m.text():find("Keine Stoerungen", 1, true))
  end,

  test_a_lost_signal_node_turns_the_lamp_red_and_is_listed = function()
    local panel = status_panel.new(sources({ SIG1 = { role = "signal", status = "down" } }))
    local m = recording_monitor(51, 19)
    panel.draw(m)
    assert(m.text():find("STOERUNG", 1, true) and m.text():find("SIG1", 1, true))
    local red_row = false
    for _, entry in ipairs(m.backgrounds) do if entry.bg == 16384 and entry.y == 4 then red_row = true end end
    assert(red_row, "the lamp row is drawn on a red background")
  end,

  test_monochrome_monitor_still_shows_the_word = function()
    local panel = status_panel.new(sources({ T1 = { role = "train", status = "down" } }), nil)
    local m = recording_monitor(51, 19, false)
    panel.draw(m)
    assert(m.text():find("WARNUNG", 1, true))
  end,

  test_problem_list_pages_with_touch = function()
    local nodes = {}
    for i = 1, 60 do nodes[string.format("TRAIN-%02d", i)] = { role = "train", status = "down" } end
    local panel = status_panel.new(sources(nodes))
    local m = recording_monitor(51, 19)
    panel.draw(m)
    assert(m.text():find("TRAIN-01", 1, true) and not m.text():find("TRAIN-60", 1, true))
    panel.touch(40, 19)
    m = recording_monitor(51, 19); panel.draw(m)
    assert(not m.text():find("TRAIN-01", 1, true), "second page")
    assert(m.text():find("Seite 2/", 1, true))
    for _ = 1, 30 do panel.touch(40, 19) end
    m = recording_monitor(51, 19); panel.draw(m)
    assert(m.text():find("TRAIN-60", 1, true), "paging stops at the last page")
    for _ = 1, 20 do panel.touch(2, 19) end
    m = recording_monitor(51, 19); panel.draw(m)
    assert(m.text():find("Seite 1/", 1, true))
  end,

  test_recovery_and_maintenance_and_updates_are_reflected = function()
    local panel = status_panel.new(sources({}, {}, {
      recovery = function() return { required = true, confirmed = false } end,
      maintenance = { is_locked = function() return true end },
      ota = function() return { status = function() return { { node_id = "N1", state = "FAILED", error = "kein Platz" } } end } end
    }))
    local m = panel.model()
    assert(m.lamp == "RED")
    local joined = table.concat(m.reasons, "|")
    assert(joined:find("Wiederanlauf") and joined:find("Wartungsmodus") and joined:find("Update"))
  end,

  test_panel_without_any_source_does_not_fail = function()
    local panel = status_panel.new(nil)
    local m = recording_monitor(51, 19)
    panel.draw(m)
    assert(m.text():find("BETRIEB OK", 1, true))
  end
}
