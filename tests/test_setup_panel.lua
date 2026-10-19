--[[
Purpose: The setup page of the master: the four lines about how far the setup is, the list of waiting computers, selecting, accepting with a
  second touch, rejecting, paging, and what a monochrome or small monitor shows.
Public API: returns table of tests.
]]

pcall(dofile, "tests/harness/cc_bootstrap.lua")

local setup_panel = require("src.master.ui.panels.setup")
local pairing_module = require("src.master.pairing")
local netplan = require("src.setup.netplan")
local memfs = require("tests.harness.memfs")

local PLAN = "configs/network.json"

local function recording_monitor(w, h, color)
  local m = { writes = {}, size = { w, h } }
  local x, y = 1, 1
  m.getSize = function() return m.size[1], m.size[2] end
  m.isColor = function() return color ~= false end
  m.setCursorPos = function(cx, cy) x, y = cx, cy end
  m.setBackgroundColor = function() end
  m.setTextColor = function(c) m.color = c end
  m.write = function(text) m.writes[#m.writes + 1] = { x = x, y = y, text = text, color = m.color } end
  m.clear = function() m.writes = {} end
  -- what stands on one row of the screen: later writes cover earlier ones, like on a real monitor
  m.row = function(row)
    local cells = {}
    for _, item in ipairs(m.writes) do
      if item.y == row then
        for i = 1, #item.text do cells[item.x + i - 1] = item.text:sub(i, i) end
      end
    end
    local last = 0
    for x in pairs(cells) do if x > last then last = x end end
    local out = {}
    for x = 1, last do out[x] = cells[x] or " " end
    return (table.concat(out):gsub("%s+$", ""))
  end
  m.text = function()
    local lines = {}
    for row = 1, h do local line = m.row(row); if line ~= "" then lines[#lines + 1] = line end end
    return table.concat(lines, "\n")
  end
  return m
end

local function world(opts)
  local o = opts or {}
  local fs = memfs.new()
  local cfg = {
    v = 1, channel = 777, master_id = "M",
    nodes = { { id = "M", role = "master" }, { id = "SIG-1", role = "signal" }, { id = "SIG-2", role = "signal" } },
    blocks = o.empty and {} or { { id = "B1" } }, routes = o.empty and {} or { { id = "R1" } },
  }
  fs.set(PLAN, netplan.encode({ v = 1, channel = 777, master_id = "M", nodes = cfg.nodes, blocks = {}, routes = {} }))
  local clock = { t = 1000 }
  local pairing = pairing_module.new({ config = cfg, plan_path = PLAN, fs = fs, now_s = function() return clock.t end })
  local registry = { all = function() return o.registry or { ["SIG-1"] = { status = "UP" }, ["SIG-2"] = { status = "UP" } } end }
  local decisions = {}
  local w = { cfg = cfg, fs = fs, clock = clock, pairing = pairing, decisions = decisions }
  w.panel = setup_panel.new({
    config = cfg, registry = registry, pairing = pairing, now_s = function() return clock.t end,
    decide = function(action, id, operator)
      decisions[#decisions + 1] = action .. ":" .. id .. ":" .. operator
      if action == "accept" then return pairing.accept(id, operator) end
      return pairing.reject(id, operator)
    end,
  })
  return w
end

local function find_row(m, text)
  for row = 1, 19 do if m.row(row):find(text, 1, true) then return row end end
  return nil
end

return {
  test_a_finished_network_shows_four_ok_lines_and_no_waiting_computers = function()
    local w = world()
    w.pairing.announce("SIG-1", { role = "signal", setup = { state = "GEPRUEFT", fail = 0, warn = 0 } })
    w.pairing.announce("SIG-2", { role = "signal", setup = { state = "GEPRUEFT", fail = 0, warn = 0 } })
    local m = recording_monitor(51, 19)
    w.panel.draw(m)
    local text = m.text()
    assert(text:find("EINRICHTUNG", 1, true) and text:find("Kanal 777", 1, true))
    assert(text:find("OK     Netzplan: 1 Block/Bloecke, 1 Route(n)", 1, true), text)
    assert(text:find("Computer online: 2 von 2", 1, true) and text:find("alle 2 Computer geprueft", 1, true) and text:find("keiner wartet", 1, true))
    assert(not text:find("OFFEN", 1, true) and not text:find("FEHLER", 1, true))
    assert(text:find("Keine. Neue Computer melden sich", 1, true))
  end,

  test_open_steps_are_named_with_a_word_and_a_colour = function()
    local w = world({ empty = true, registry = { ["SIG-1"] = { status = "UP" }, ["SIG-2"] = { status = "DOWN" } } })
    w.pairing.announce("SIG-1", { role = "signal", setup = { state = "PRUEFUNG_OFFEN", fail = 1, warn = 0 } })
    w.pairing.announce("NEW-1", { role = "sensor" })
    local m = recording_monitor(51, 19)
    w.panel.draw(m)
    local text = m.text()
    assert(text:find("OFFEN  Netzplan: noch keine Bloecke oder Routen", 1, true), text)
    assert(text:find("FEHLER Computer offline: 1 von 2 (SIG-2)", 1, true))
    assert(text:find("FEHLER Pruefung: 1 Computer mit offener Pruefung", 1, true))
    assert(text:find("OFFEN  Neue Computer: 1 warten auf Freigabe", 1, true))
    -- the same words on a monochrome monitor
    local mono = recording_monitor(51, 19, false)
    w.panel.draw(mono)
    assert(mono.text():find("FEHLER Computer offline", 1, true))
    local model = w.panel.model()
    assert(model.nodes == 2 and model.offline == 1 and #model.lines == 4)
  end,

  test_waiting_computers_are_listed_and_touching_a_row_selects_it = function()
    local w = world()
    w.pairing.announce("SIG-7", { role = "signal", entry = { id = "SIG-7", role = "signal", adapter = "peripheral", peripheral = "Create_Signal_3" }, setup = { state = "GEPRUEFT" } })
    w.pairing.announce("SEN-4", { role = "sensor" })
    local m = recording_monitor(51, 19)
    w.panel.draw(m)
    assert(m.text():find("WARTENDE COMPUTER (2)", 1, true))
    local row = find_row(m, "SEN-4")
    local row7 = find_row(m, "SIG-7")
    assert(row and row7 and row < row7, "sorted by id")
    assert(m.row(row7):find("Signal, Create_Signal_3, geprueft", 1, true), m.row(row7))
    assert(m.row(row):find("Melder", 1, true))
    assert(find_row(m, "Zeile antippen"))
    w.panel.touch(5, row7)
    m = recording_monitor(51, 19)
    w.panel.draw(m)
    assert(m.row(row7):sub(1, 1) == ">", "the selected row is marked")
    assert(find_row(m, "[ANNEHMEN]") and find_row(m, "[ABLEHNEN]"))
  end,

  test_accepting_needs_a_second_touch_and_writes_the_plan = function()
    local w = world()
    w.pairing.announce("SIG-7", { role = "signal", entry = { id = "SIG-7", role = "signal", adapter = "redstone", side = "left" } })
    local m = recording_monitor(51, 19)
    w.panel.draw(m)
    w.panel.touch(5, find_row(m, "SIG-7"))
    m = recording_monitor(51, 19)
    w.panel.draw(m)
    local button_row = find_row(m, "[ANNEHMEN]")
    w.panel.touch(3, button_row)
    assert(#w.decisions == 0, "the first touch only asks")
    m = recording_monitor(51, 19)
    w.panel.draw(m)
    assert(find_row(m, "[SICHER?]"))
    w.panel.touch(3, button_row)
    assert(#w.decisions == 1 and w.decisions[1] == "accept:SIG-7:MASTER-UI")
    assert(netplan.find_node(assert(netplan.parse(w.fs.files[PLAN])), "SIG-7"))
    m = recording_monitor(51, 19)
    w.panel.draw(m)
    assert(m.text():find("SIG-7 ist im Netzplan eingetragen", 1, true) and m.text():find("WARTENDE COMPUTER (0)", 1, true), m.text())
    w.clock.t = w.clock.t + 20
    m = recording_monitor(51, 19)
    w.panel.draw(m)
    assert(not m.text():find("eingetragen", 1, true), "the message goes away by itself")
  end,

  test_the_confirmation_runs_out = function()
    local w = world()
    w.pairing.announce("SIG-7", { role = "signal" })
    local m = recording_monitor(51, 19)
    w.panel.draw(m)
    w.panel.touch(5, find_row(m, "SIG-7"))
    m = recording_monitor(51, 19)
    w.panel.draw(m)
    local button_row = find_row(m, "[ANNEHMEN]")
    w.panel.touch(3, button_row)
    w.clock.t = w.clock.t + 30
    w.panel.touch(3, button_row)
    assert(#w.decisions == 0, "an old first touch does not count as a confirmation")
  end,

  test_rejecting_is_one_touch_and_a_conflict_cannot_be_accepted = function()
    local w = world()
    w.pairing.announce("SIG-7", { role = "signal" })
    w.pairing.announce("SIG-1", { role = "sensor" })
    local m = recording_monitor(51, 19)
    w.panel.draw(m)
    local conflict_row = find_row(m, "SIG-1")
    assert(m.row(conflict_row):find("Rolle passt nicht zum Netzplan", 1, true))
    w.panel.touch(5, conflict_row)
    m = recording_monitor(51, 19)
    w.panel.draw(m)
    assert(not find_row(m, "[ANNEHMEN]") and find_row(m, "[ABLEHNEN]"), "a conflict has no accept button")
    w.panel.touch(3, find_row(m, "[ABLEHNEN]") or 15)
    w.panel.touch(15, find_row(m, "[ABLEHNEN]"))
    assert(w.decisions[#w.decisions] == "reject:SIG-1:MASTER-UI")
    -- an ordinary candidate
    w.panel.touch(5, conflict_row + 1)
    m = recording_monitor(51, 19)
    w.panel.draw(m)
    w.panel.touch(15, find_row(m, "[ABLEHNEN]"))
    assert(w.decisions[#w.decisions] == "reject:SIG-7:MASTER-UI")
    assert(w.pairing.count() == 0)
  end,

  test_more_than_five_computers_page_and_the_bottom_row_turns_the_page = function()
    local w = world()
    for i = 1, 12 do w.pairing.announce(string.format("N-%02d", i), { role = "signal" }) end
    local m = recording_monitor(51, 19)
    w.panel.draw(m)
    assert(m.text():find("Seite 1/3", 1, true) and m.text():find("N-01", 1, true) and not m.text():find("N-06", 1, true))
    w.panel.touch(40, 19)
    m = recording_monitor(51, 19)
    w.panel.draw(m)
    assert(m.text():find("Seite 2/3", 1, true) and m.text():find("N-06", 1, true))
    w.panel.touch(40, 19)
    w.panel.touch(40, 19)
    w.panel.touch(5, 19)
    m = recording_monitor(51, 19)
    w.panel.draw(m)
    assert(m.text():find("Seite 2/3", 1, true), "back one page, and not beyond the last")
  end,

  test_a_small_monitor_and_missing_sources_do_not_break_the_page = function()
    local m = recording_monitor(26, 12)
    local bare = setup_panel.new({})
    bare.draw(m)
    assert(m.text():find("EINRICHTUNG", 1, true))
    for row = 1, 12 do assert(#m.row(row) <= 26, "row " .. row .. ": " .. m.row(row)) end
    bare.touch(3, 3)
    bare.touch(40, 12)
    assert(setup_panel.new({}).draw(nil) == nil)
    local w = world()
    local ok = pcall(w.panel.draw, recording_monitor(51, 19))
    assert(ok)
  end,
}
