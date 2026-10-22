--[[
Purpose: Master-AUX: the reduced error view on its own monitor, which goes on when parts of the system fail and never stops the master (Gesamtkonzept Kap. 15).
Public API: returns table of tests.
]]

pcall(dofile, "tests/harness/cc_bootstrap.lua")

local aux_display = require("src.master.aux_display")
local validate = require("src.shared.validate")

local function monitor(w, h)
  local m = { w = w, h = h, rows = {}, x = 1, y = 1, broken = false }
  function m.getSize() return m.w, m.h end
  function m.clear() m.rows = {} end
  function m.setCursorPos(x, y) m.x, m.y = x, y end
  function m.write(text) if m.broken then error("gone") end m.rows[m.y] = (m.rows[m.y] or "") .. text end
  function m.text() local out = {} for y = 1, m.h do out[#out + 1] = m.rows[y] or "" end return table.concat(out, "\n") end
  return m
end

local function sources(extra)
  local s = {
    role = function() return "leader" end,
    op = function() return "NORMAL", "alle Voraussetzungen geprueft" end,
    blocks = function() return { free = 40, unknown = 3, fault = 1, reserved = 6 } end,
    nodes = function() return { up = 12, down = 2, down_ids = { "SIG-4", "SEN-9" } } end,
    locks = function() return { { node_id = "SIG-2", reason = "Rollback" } } end,
    alerts = function() return { { severity = "RED", text = "Block B7 unklar", acked = false }, { severity = "RED", text = "Knoten weg", acked = true }, { severity = "YELLOW", text = "gelb", acked = false } } end,
    journal = function() return true end,
    space = function() return 123456 end
  }
  for k, v in pairs(extra or {}) do s[k] = v end
  return s
end

return {
  test_the_view_shows_state_blocks_nodes_locks_journal_space_and_the_unseen_red_messages_only = function()
    local m = monitor(51, 19)
    local aux = aux_display.new({ monitor = m, id = "MASTER-A", sources = sources(), now = function() return 77.9 end })
    assert(aux.draw() == true)
    local text = m.text()
    assert(text:find("MASTER-AUX  MASTER-A  leader", 1, true) and text:find("Zustand: NORMAL", 1, true))
    assert(text:find("frei 40  unklar 3  Stoerung 1  belegt 6", 1, true))
    assert(text:find("Knoten: 12 da, 2 weg: SIG-4,SEN-9", 1, true) and text:find("Sperren: 1", 1, true) and text:find("SIG-2: Rollback", 1, true))
    assert(text:find("Journal: ok", 1, true) and text:find("Platz: 123456 Byte frei", 1, true))
    assert(text:find("Block B7 unklar", 1, true) and not text:find("Knoten weg\n", 1, true) and not text:find("gelb", 1, true), "red and not seen only")
    assert(text:find("Stand 77 s", 1, true))
  end,

  test_a_source_that_fails_shows_a_question_mark_and_the_other_lines_go_on = function()
    local m = monitor(51, 19)
    local aux = aux_display.new({ monitor = m, id = "M", sources = sources({
      blocks = function() error("dispatcher broken") end, nodes = function() return "nonsense" end, alerts = function() error("x") end, journal = function() error("y") end, space = function() error("z") end }) })
    assert(aux.draw() == true)
    local text = m.text()
    assert(text:find("Bloecke: ?", 1, true) and text:find("Knoten: ?", 1, true) and text:find("Journal: ?", 1, true) and text:find("Platz: ?", 1, true) and text:find("Meldungen: ?", 1, true))
    assert(text:find("Zustand: NORMAL", 1, true) and text:find("Sperren: 1", 1, true), "what works is still shown")
  end,

  test_the_text_of_a_failing_source_is_never_shown_as_if_it_were_its_answer = function()
    local m = monitor(51, 19)
    local aux = aux_display.new({ monitor = m, id = "M", sources = sources({ role = function() error("boom-role") end, op = function() error("boom-op") end }) })
    aux.draw()
    local text = m.text()
    assert(not text:find("boom", 1, true) and text:find("MASTER-AUX  M  ?", 1, true) and text:find("Zustand: ?", 1, true), text)
  end,

  test_a_journal_that_cannot_be_written_is_shown_as_an_error_with_its_reason = function()
    local m = monitor(51, 19)
    local aux = aux_display.new({ monitor = m, sources = sources({ journal = function() return false, "nicht beschreibbar" end }) })
    aux.draw()
    assert(m.text():find("Journal: FEHLER nicht beschreibbar", 1, true))
  end,

  test_nothing_is_drawn_wider_than_the_monitor_and_a_monitor_that_raises_does_not_raise_further = function()
    local small = monitor(20, 8)
    local aux = aux_display.new({ monitor = small, id = "MASTER-A", sources = sources() })
    aux.draw()
    for y = 1, 8 do assert(#(small.rows[y] or "") <= 20, "row " .. y) end
    local broken = monitor(51, 19)
    broken.broken = true
    local ok = aux_display.new({ monitor = broken, sources = sources() }).draw()
    assert(ok == false, "the failure is the answer, not an error")
    assert(aux_display.new({ sources = sources() }).draw() == false, "no monitor: nothing to draw")
  end,

  test_without_any_source_the_view_still_says_what_it_does_not_know = function()
    local m = monitor(51, 19)
    local aux = aux_display.new({ monitor = m })
    assert(aux.draw() == true)
    assert(m.text():find("Zustand: ?", 1, true) and m.text():find("Bloecke: ?", 1, true))
  end,

  test_the_config_check_knows_the_aux_monitor = function()
    local function text(extra)
      local c = { v = 1, channel = 1, master_id = "M", nodes = { { id = "M", role = "master" } } }
      for k, v in pairs(extra) do c[k] = v end
      local _, errs = validate.validate_config(c)
      return table.concat(errs or {}, "\n")
    end
    assert(not text({ aux_monitor = "monitor_3", aux_monitor_scale = 0.5 }):find("aux_monitor", 1, true))
    assert(text({ aux_monitor = "" }):find("aux_monitor", 1, true))
    assert(text({ aux_monitor_scale = 7 }):find("aux_monitor_scale", 1, true))
  end
}
