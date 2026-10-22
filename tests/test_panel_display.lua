--[[
Purpose: Several monitors on one panel computer: each its own view, groups share only the selection, a monitor that is removed does not stop the others, and the views respect the level and say how old the data is (Pruefplan H-01 bis H-04, H-14, H-11).
Public API: returns table of tests.
]]

local multi_display = require("src.panel.multi_display")
local monitor_registry = require("src.panel.monitor_registry")
local views = require("src.panel.views")
local diagram = require("src.panel.diagram")
local safety_graph = require("src.domain.safety_graph")
local memfs = require("tests.harness.memfs")

-- a monitor of any size that keeps what is written
local function monitor(w, h)
  local m = { w = w, h = h, rows = {}, x = 1, y = 1, scale = 1, broken = false }
  function m.getSize() return m.w, m.h end
  function m.clear() m.rows = {} end
  function m.setCursorPos(x, y) m.x, m.y = x, y end
  function m.write(text)
    if m.broken then error("monitor gone") end
    -- like a real monitor: the text overwrites what stands there and what runs past the right edge is lost
    local row = m.rows[m.y] or ""
    row = row .. string.rep(" ", math.max(0, m.x - 1 - #row))
    local text_s = tostring(text)
    row = row:sub(1, m.x - 1) .. text_s .. row:sub(m.x + #text_s)
    m.rows[m.y] = row:sub(1, m.w)
  end
  function m.setTextScale(scale) m.scale = scale end
  function m.text() local out = {} for y = 1, m.h do out[#out + 1] = m.rows[y] or "" end return table.concat(out, "\n") end
  return m
end

local function world(sizes)
  local devices = {}
  for name, size in pairs(sizes) do devices[name] = monitor(size[1], size[2]) end
  local api = {
    getNames = function() local out = {} for name in pairs(devices) do out[#out + 1] = name end table.sort(out) return out end,
    getType = function(name) return devices[name] and "monitor" or nil end,
    wrap = function(name) return devices[name] end,
    isPresent = function(name) return devices[name] ~= nil end
  }
  local fs = memfs.new()
  local registry = monitor_registry.new({ fs = fs, path = "state/panel_monitors.json", peripheral = api, node_id = "PANEL-1" })
  registry.load()
  return { devices = devices, api = api, registry = registry }
end

local STATE = {
  master_state = "ONLINE", last_update = 100,
  overview = { B1 = { state = "FREE" }, B2 = { state = "RESERVED", reserved_by = "T1" } },
  trains = { T1 = { state = "RUNNING", route_id = "R1", destination = "Sued" }, T2 = { state = "IDLE" } },
  stations = { ST1 = { state = "OK", platforms = {} } }, depots = {}, service_plans = {}, diagnostics = {}
}

local function display(w, extra)
  local d = multi_display.new({ registry = w.registry, model = function() return STATE end, level = (extra and extra.level) or "operate", now = function() return (extra and extra.now) or 105 end, layout = extra and extra.layout, faults = extra and extra.faults })
  return d
end

local function bind(w, id, name, view)
  assert(w.registry.bind(id, name, { confirmed = true, start_view = view }))
end

return {
  test_two_monitors_show_two_different_views_at_the_same_time = function()
    local w = world({ monitor_0 = { 51, 19 }, monitor_1 = { 29, 19 } })
    bind(w, "M-OVER", "monitor_0", "overview"); bind(w, "M-TRAIN", "monitor_1", "trains")
    local d = display(w)
    local report = d.refresh()
    assert(#report.drawn == 2 and #report.missing == 0)
    assert(w.devices.monitor_0.text():find("Overview", 1, true) and not w.devices.monitor_0.text():find("T1", 1, true))
    assert(w.devices.monitor_1.text():find("T1", 1, true) and w.devices.monitor_1.text():find("T2", 1, true))
  end,

  test_each_size_draws_inside_its_own_width = function()
    local w = world({ monitor_0 = { 18, 12 }, monitor_1 = { 80, 40 } })
    bind(w, "SMALL", "monitor_0", "trains"); bind(w, "BIG", "monitor_1", "trains")
    display(w).refresh()
    -- nothing is lost at the right edge: the lines are cut by the views, not by the monitor
    local lost = false
    local raw = w.devices.monitor_0
    local original = raw.write
    raw.write = function(text) if raw.x - 1 + #tostring(text) > raw.w then lost = true end return original(text) end
    display(w).refresh()
    assert(not lost, "a view wrote past the right edge of the small monitor")
    assert(w.devices.monitor_1.text():find("Daten: aktuell", 1, true))
  end,

  test_a_touch_on_the_top_rows_changes_only_the_view_of_that_monitor = function()
    local w = world({ monitor_0 = { 51, 19 }, monitor_1 = { 51, 19 } })
    bind(w, "A", "monitor_0", "overview"); bind(w, "B", "monitor_1", "overview")
    local d = display(w)
    d.refresh()
    local result = d.touch("monitor_0", 30, 1)
    assert(result.view and d.view_of("A") ~= "overview" and d.view_of("B") ~= d.view_of("A"), tostring(d.view_of("A")))
    assert(d.touch("nowhere", 1, 1) == nil)
  end,

  test_a_group_shares_the_selection_and_an_independent_monitor_does_not = function()
    local w = world({ monitor_0 = { 51, 19 }, monitor_1 = { 51, 19 }, monitor_2 = { 51, 19 } })
    bind(w, "A", "monitor_0", "trains"); bind(w, "B", "monitor_1", "train_detail"); bind(w, "C", "monitor_2", "train_detail")
    assert(w.registry.define_group("G1", { "A", "B" }))
    local d = display(w)
    d.refresh()
    local touched = d.touch("monitor_0", 3, 7)
    assert(touched.selected and touched.selected.key == "train" and touched.selected.value == "T1", tostring(touched.selected and touched.selected.value))
    d.refresh()
    assert(d.selection_of("B", "train") == "T1" and d.selection_of("C", "train") == nil, "the group shares it, the loner does not")
    assert(w.devices.monitor_1.text():find("Zug T1", 1, true) and w.devices.monitor_2.text():find("antippen", 1, true))
    -- a touch on the loner selects for the loner only
    local own = display(w)
    own.refresh()
    own.touch("monitor_2", 1, 1)
  end,

  test_the_train_detail_offers_the_buttons_of_the_level_and_a_touch_gives_the_action = function()
    local w = world({ monitor_0 = { 51, 19 } })
    bind(w, "A", "monitor_0", "train_detail")
    local d = multi_display.new({ registry = w.registry, model = function() return STATE end, level = "operate", now = function() return 105 end })
    local own = multi_display.new({ registry = w.registry, model = function() return STATE end, level = "operate", now = function() return 105 end })
    -- select a train first through the trains view of an ungrouped monitor
    own.set_view("A", "trains"); own.refresh()
    assert(own.touch("monitor_0", 3, 7).selected.value == "T1")
    own.set_view("A", "train_detail"); own.refresh()
    local text = w.devices.monitor_0.text()
    assert(text:find("[Halten]", 1, true) and text:find("[NOTHALT]", 1, true) and not text:find("Freigeben", 1, true), "operate gets no release button")
    local hold = own.touch("monitor_0", 2, 13)
    assert(hold.action and hold.action.action == "hold_train" and hold.action.train_id == "T1")
    local admin = multi_display.new({ registry = w.registry, model = function() return STATE end, level = "admin", now = function() return 105 end })
    admin.set_view("A", "trains"); admin.refresh(); admin.touch("monitor_0", 3, 7); admin.set_view("A", "train_detail"); admin.refresh()
    assert(w.devices.monitor_0.text():find("Freigeben", 1, true))
    assert(admin.touch("monitor_0", 2, 15).action.action == "release_train")
    local viewer = multi_display.new({ registry = w.registry, model = function() return STATE end, level = "view", now = function() return 105 end })
    viewer.refresh()
    assert(not w.devices.monitor_0.text():find("[Halten]", 1, true))
  end,

  test_a_train_of_a_pair_can_be_sent_to_a_depot_of_that_pair_from_the_train_detail = function()
    local w = world({ monitor_0 = { 51, 19 } })
    bind(w, "A", "monitor_0", "trains")
    local state = {}
    for k, v in pairs(STATE) do state[k] = v end
    state.fleet = { train_pair = { T1 = "P1" }, depots = { DEP1 = "P1", DEP9 = "P2" }, lines = {}, trips = {}, pairs = {}, results = {} }
    local d = multi_display.new({ registry = w.registry, model = function() return state end, level = "operate", now = function() return 105 end })
    d.refresh(); d.touch("monitor_0", 3, 7)
    d.set_view("A", "train_detail"); d.refresh()
    local text = w.devices.monitor_0.text()
    assert(text:find("[In Depot DEP1]", 1, true) and not text:find("DEP9", 1, true), (text:gsub("\n", "|")))
    local x, y
    for row = 1, 19 do local found = (w.devices.monitor_0.rows[row] or ""):find("[In Depot DEP1]", 1, true); if found then x, y = found, row end end
    local result = d.touch("monitor_0", x + 2, y)
    assert(result.action.action == "depot_run" and result.action.pair_id == "P1" and result.action.train_id == "T1" and result.action.depot == "DEP1")
    local viewer = multi_display.new({ registry = w.registry, model = function() return state end, level = "view", now = function() return 105 end })
    viewer.set_view("A", "trains"); viewer.refresh(); viewer.touch("monitor_0", 3, 7)
    viewer.set_view("A", "train_detail"); viewer.refresh()
    assert(w.devices.monitor_0.text():find("Zug T1", 1, true), "the viewer has the train selected")
    assert(not w.devices.monitor_0.text():find("In Depot", 1, true))
  end,

  test_a_monitor_that_is_removed_or_breaks_does_not_stop_the_others = function()
    local w = world({ monitor_0 = { 51, 19 }, monitor_1 = { 51, 19 } })
    bind(w, "A", "monitor_0", "overview"); bind(w, "B", "monitor_1", "overview")
    local d = display(w)
    w.devices.monitor_0 = nil
    local report = d.refresh()
    assert(#report.drawn == 1 and report.drawn[1] == "B" and report.missing[1] == "A")
    w.devices.monitor_1.broken = true
    local again = d.refresh()
    assert(#again.drawn == 0 and #again.missing == 2, "a monitor that fails while drawing is reported, not thrown")
    assert(again.errors.B:find("monitor gone", 1, true), "and the reason is kept")
  end,

  test_views_above_the_level_are_refused_and_not_drawn = function()
    local w = world({ monitor_0 = { 51, 19 } })
    bind(w, "A", "monitor_0", "overview")
    local d = display(w, { level = "view" })
    d.refresh()
    assert(d.set_view("A", "maintenance") == false and d.set_view("A", "nonsense") == false and d.set_view("A", "fault_center") == true)
    local m = monitor(51, 19)
    views.render("maintenance", m, { state = STATE, level = "view", age_s = 1 })
    assert(m.text():find("fehlt das Recht", 1, true) and not m.text():find("Reason", 1, true))
  end,

  test_a_monitor_falls_back_to_the_overview_when_the_level_drops_and_audit_is_for_admin_only = function()
    local w = world({ monitor_0 = { 51, 19 } })
    bind(w, "A", "monitor_0", "audit")
    local level = "admin"
    local d = multi_display.new({ registry = w.registry, model = function() return STATE end, level = function() return level end, now = function() return 105 end })
    d.refresh()
    assert(d.view_of("A") == "audit" and w.devices.monitor_0.text():find("AUDIT", 1, true))
    level = "operate"
    d.refresh()
    assert(d.view_of("A") == "overview", "the level dropped: the monitor shows what the level allows")
    local m = monitor(51, 19)
    views.render("audit", m, { state = STATE, level = "operate", age_s = 1 })
    assert(m.text():find("fehlt das Recht (admin)", 1, true), "the page table decides for the views that have no check of their own")
  end,

  test_a_monitor_in_a_group_keeps_the_line_of_the_timetable_to_itself = function()
    local w = world({ monitor_0 = { 51, 19 }, monitor_1 = { 51, 19 } })
    bind(w, "A", "monitor_0", "timetable"); bind(w, "B", "monitor_1", "timetable")
    assert(w.registry.define_group("G", { "A", "B" }))
    local state = {}
    for k, v in pairs(STATE) do state[k] = v end
    state.fleet = { lines = { L1 = { version = 1, kind = "PASSENGER", headway_min = 10, window = { from = "06:00", to = "22:00" }, pair_id = "P1" } }, trips = {}, pairs = {}, results = {} }
    local d = multi_display.new({ registry = w.registry, model = function() return state end, level = "view", now = function() return 105 end })
    d.refresh()
    local result = d.touch("monitor_0", 3, 4)
    assert(result.selected and result.selected.key == "line")
    assert(d.selection_of("A", "line") == "L1" and d.selection_of("B", "line") == nil, "a group shares train, station and section, not the line")
  end,

  test_old_data_is_labelled_and_never_drawn_as_current = function()
    local w = world({ monitor_0 = { 51, 19 } })
    bind(w, "A", "monitor_0", "overview")
    display(w, { now = 150 }).refresh()
    assert(w.devices.monitor_0.text():find("veraltet", 1, true))
    local fresh_state = { master_state = "UNBEKANNT", last_update = 0, overview = {}, trains = {}, stations = {}, depots = {}, diagnostics = {} }
    local m = monitor(51, 19)
    views.render("overview", m, { state = fresh_state, level = "view", age_s = nil })
    assert(m.text():find("keine Daten", 1, true))
  end,

  test_the_track_diagram_draws_the_letter_of_what_is_proven_and_selects_a_section = function()
    local cfg = {
      blocks = { { id = "W1", entry_signal = "S1", exit_signal = "X1", sensors = { "SEN-1" } }, { id = "M1", entry_signal = "S2", exit_signal = "X2", sensors = { "SEN-2" } } },
      routes = { { id = "R1", blocks = { "W1", "M1" } } }
    }
    local layout = diagram.propose(safety_graph.build(cfg))
    local state = { master_state = "ONLINE", last_update = 1, overview = { W1 = { proof = { state = "FREE_PROVEN", at = 100 } }, M1 = { state = "FAULT", reserved_by = "T1" } } }
    local m = monitor(60, 19)
    local hits = views.render("gleisbild", m, { state = state, level = "view", age_s = 1, layout = layout, now = 101 })
    local text = m.text()
    assert(text:find(".W1", 1, true), "proven free")
    assert(text:find("XM1", 1, true), "a fault is X even when it is reserved")
    local selectable = {}
    for _, hit in ipairs(hits) do selectable[hit.value] = hit.key end
    assert(selectable.W1 == "section" and selectable.M1 == "section")
    local none = monitor(60, 19)
    views.render("gleisbild", none, { state = state, level = "view", age_s = 1 })
    assert(none.text():find("Kein bestaetigtes Gleisbild", 1, true))
  end,

  test_the_fault_view_shows_a_seen_fault_as_still_open = function()
    local m = monitor(60, 19)
    views.render("fault_center", m, { state = STATE, level = "view", age_s = 1, faults = {
      { key = "a", severity = "RED", message = "Block B1 unklar", state = "ACTIVE" },
      { key = "b", severity = "YELLOW", message = "Knoten SIG-1 weg", state = "ACTIVE_SEEN", acked_by = "PANEL-1" } } })
    local text = m.text()
    assert(text:find("! RED Block B1 unklar", 1, true) and text:find("~ YELLOW Knoten SIG-1 weg", 1, true) and text:find("Ursache besteht", 1, true))
    assert(text:find("Quittieren = gelesen", 1, true))
  end
}
