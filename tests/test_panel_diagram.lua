--[[
Purpose: The track diagram: a proposal from the confirmed safety graph, an editor that moves, labels and cuts out but never touches a real connection, a draft that is validated, previewed and published only after confirmation, a rollback that does not bring back a stale plan, and a display that keeps occupancy, reservation, fault, signal and certainty apart (Gesamtkonzept Kap. 11.3).
Public API: returns table of tests.
]]

local diagram = require("src.panel.diagram")
local safety_graph = require("src.domain.safety_graph")
local memfs = require("tests.harness.memfs")

local function config(extra)
  local c = {
    blocks = {
      { id = "W1", entry_signal = "S-W1", exit_signal = "X-W1", sensors = { "SEN-W1" } },
      { id = "M1", entry_signal = "S-M1", exit_signal = "X-M1", sensors = { "SEN-M1" } },
      { id = "M2", entry_signal = "S-M2", exit_signal = "X-M2", sensors = { "SEN-M2" } },
      { id = "E1", entry_signal = "S-E1", exit_signal = "X-E1", sensors = { "SEN-E1" } }
    },
    routes = { { id = "R1", blocks = { "W1", "M1", "E1" } }, { id = "R2", blocks = { "W1", "M2", "E1" } } }
  }
  for k, v in pairs(extra or {}) do c[k] = v end
  return c
end

local function graph(extra) return safety_graph.build(config(extra)) end

return {
  test_the_proposal_puts_every_block_of_the_graph_in_reading_order_and_is_the_same_every_time = function()
    local layout = diagram.propose(graph())
    assert(layout.topology_version == graph().version)
    local w1, m1, m2, e1 = layout.objects.W1, layout.objects.M1, layout.objects.M2, layout.objects.E1
    assert(w1.x < m1.x and w1.x < m2.x and m1.x < e1.x and m1.x == m2.x and m1.y ~= m2.y, "layers left to right, branches below each other")
    assert(w1.label == "W1" and w1.kind == "block")
    local again = diagram.propose(graph())
    for id, object in pairs(layout.objects) do assert(object.x == again.objects[id].x and object.y == again.objects[id].y) end
    assert(layout.links[1] ~= nil and layout.links[1].from and layout.links[1].to, "the links come from the graph")
  end,

  test_the_editor_moves_labels_and_cuts_out_but_never_touches_a_connection = function()
    local g = graph()
    local ed = diagram.editor(diagram.propose(g), g)
    assert(ed.move("M1", 30, 5) and ed.draft().objects.M1.x == 30 and ed.draft().objects.M1.y == 5)
    assert(ed.label("M1", "Mitte 1") and ed.draft().objects.M1.label == "Mitte 1")
    assert(ed.set_layer("M1", "detail") and ed.draft().objects.M1.layer == "detail")
    assert(ed.define_viewport("Nord", { x = 0, y = 0, w = 40, h = 10 }, "M1") and ed.draft().viewports.Nord.monitor == "M1")
    for _, forbidden in ipairs({ "add_link", "remove_link", "add_object", "remove_object", "rename_object", "set_signal_binding", "set_route" }) do
      assert(ed[forbidden] == nil, forbidden .. " does not exist: the diagram is a picture of the graph")
    end
    local ok, err = ed.move("GHOST", 1, 1)
    assert(not ok and err:find("not in the graph", 1, true))
    assert(not ed.move("W1", -3, 0) and not ed.move("W1", "a", 0))
    assert(not ed.define_viewport("Bad", { x = 0, y = 0, w = 0, h = 4 }))
    local before = ed.draft().links
    assert(#before == #diagram.propose(g).links, "the links are those of the graph")
  end,

  test_a_draft_is_validated_against_the_graph_and_the_active_layout_stays_until_it_is_confirmed = function()
    local g = graph()
    local active = diagram.propose(g)
    local ed = diagram.editor(active, g)
    ed.move("M1", 12, 3)
    local report = ed.validate()
    assert(report.ok == true)
    local ok, err = ed.publish({ confirmed = true })
    assert(not ok and err:find("preview", 1, true), "the preview has to have been shown first: " .. tostring(err))
    local preview = ed.preview()
    assert(preview.moved == 1 and preview.added == 0 and preview.removed == 0 and preview.changed_objects[1] == "M1")
    ok, err = ed.publish(nil)
    assert(not ok and err:find("confirm", 1, true), tostring(err))
    ed.move("M1", 12, 4)
    ok, err = ed.publish({ confirmed = true })
    assert(not ok and err:find("preview", 1, true), "a change after the preview needs a new preview: " .. tostring(err))
    ed.preview()
    assert(ed.active().objects.M1.x == active.objects.M1.x, "until then the old layout is visible")
    assert(ed.publish({ confirmed = true }))
    assert(ed.active().objects.M1.x == 12 and ed.previous().objects.M1.x == active.objects.M1.x)
  end,

  test_a_draft_that_disagrees_with_the_graph_cannot_be_published = function()
    local g = graph()
    local ed = diagram.editor(diagram.propose(g), g)
    ed.draft().objects.GHOST = { id = "GHOST", x = 1, y = 1, kind = "block", label = "x" }
    ed.draft().objects.W1 = nil
    local report = ed.validate()
    assert(report.ok == false and #report.problems == 2)
    local text = table.concat(report.problems, ";")
    assert(text:find("GHOST", 1, true) and text:find("W1", 1, true))
    ed.preview()
    assert(not ed.publish({ confirmed = true }))
    assert(ed.active().objects.W1 ~= nil)
  end,

  test_a_viewport_that_points_to_an_unknown_monitor_is_a_problem_when_the_monitors_are_known = function()
    local g = graph()
    local ed = diagram.editor(diagram.propose(g), g, { monitors = { M1 = true } })
    ed.define_viewport("A", { x = 0, y = 0, w = 10, h = 5 }, "M1")
    ed.define_viewport("B", { x = 0, y = 0, w = 10, h = 5 }, "M9")
    local report = ed.validate()
    assert(report.ok == false and report.problems[1]:find("M9", 1, true))
  end,

  test_rollback_returns_the_previous_layout_only_for_the_same_topology = function()
    local g = graph()
    local ed = diagram.editor(diagram.propose(g), g)
    ed.move("M1", 12, 3); ed.preview(); assert(ed.publish({ confirmed = true }))
    assert(ed.rollback(g) and ed.active().objects.M1.x ~= 12)
    -- publish again, then the topology changes: the old layout does not come back silently
    ed.move("M1", 13, 3); ed.preview(); assert(ed.publish({ confirmed = true }))
    local changed = graph({ routes = { { id = "R1", blocks = { "W1", "M1", "E1" } } } })
    local ok, err = ed.rollback(changed)
    assert(not ok and err:find("topology", 1, true), tostring(err))
    assert(ed.active().objects.M1.x == 13, "nothing changed")
    assert(not diagram.editor(diagram.propose(g), g).rollback(g), "nothing to go back to")
  end,

  test_a_new_topology_keeps_what_is_unchanged_marks_what_changed_and_adds_what_is_new = function()
    local g = graph()
    local layout = diagram.propose(g)
    layout.objects.W1.x, layout.objects.W1.y = 7, 7           -- the operator placed it
    local new_config = config()
    new_config.blocks[2].switches = { { id = "SW-9", position = "STRAIGHT" } }   -- M1 changed
    new_config.blocks[#new_config.blocks + 1] = { id = "N1", entry_signal = "S-N1", exit_signal = "X-N1", sensors = { "SEN-N1" } }
    new_config.routes[#new_config.routes + 1] = { id = "R3", blocks = { "E1", "N1" } }
    local g2 = safety_graph.build(new_config)
    local result = diagram.carry_over(layout, g, g2)
    assert(result.layout.topology_version == g2.version)
    assert(result.layout.objects.W1.x == 7 and result.layout.objects.W1.y == 7, "unchanged: where the operator put it")
    assert(result.layout.objects.M1.changed == true and result.layout.objects.M1.x == layout.objects.M1.x, "changed: kept in place and marked")
    assert(result.layout.objects.N1 and result.layout.objects.N1.new == true, "new: added")
    assert(result.added[1] == "N1" and table.concat(result.changed, ",") == "E1,M1", "the block whose neighbourhood changed is marked too: " .. table.concat(result.changed, ","))
    local gone = safety_graph.build({ blocks = { new_config.blocks[1] }, routes = {} })
    local result2 = diagram.carry_over(layout, g, gone)
    assert(result2.removed[1] ~= nil and result2.layout.objects.M2 == nil)
  end,

  test_the_display_keeps_occupancy_reservation_fault_signals_and_certainty_apart_and_invents_no_train_position = function()
    local g = graph()
    local layout = diagram.propose(g)
    local state = {
      now = 1000, stale_after = 30,
      blocks = {
        W1 = { state = "OCCUPIED", occupied_by = "T1", proof = { state = "OCCUPIED_PROVEN", source = "enter_sensor", at = 990 } },
        M1 = { state = "RESERVED", reserved_by = "T1", proof = { state = "FREE_PROVEN", source = "tail_sensor", at = 900 } },
        M2 = { state = "FAULT", proof = { state = "UNKNOWN" } },
        E1 = { state = "FREE" }
      },
      signals = { ["S-W1"] = "RED", ["S-M1"] = "GREEN" }
    }
    local items = diagram.render_model(layout, state)
    local by = {}
    for _, item in ipairs(items) do by[item.id] = item end
    assert(by.W1.occupancy == "OCCUPIED_PROVEN" and by.W1.train == "T1" and by.W1.certainty == "fresh")
    assert(by.M1.occupancy == "FREE_PROVEN" and by.M1.reserved_by == "T1" and by.M1.train == nil, "reserved and free are separate layers: no train is drawn in a block it only holds")
    assert(by.M1.certainty == "stale", "evidence older than the limit is shown as stale")
    assert(by.M2.fault == true and by.M2.occupancy == "UNKNOWN")
    assert(by.E1.occupancy == "UNKNOWN" and by.E1.certainty == "none", "no proof: unknown, not free")
    assert(by.W1.signals.entry == "RED" and by.M1.signals.entry == "GREEN" and by.M1.signals.exit == "UNKNOWN", "a signal nobody reported is unknown")
  end,

  test_the_layouts_are_stored_and_a_damaged_file_does_not_replace_the_active_one = function()
    local fs = memfs.new()
    local g = graph()
    local store = diagram.store({ fs = fs })
    assert(store.load() == "empty")
    local ed = diagram.editor(diagram.propose(g), g)
    ed.move("M1", 20, 2)
    assert(store.save({ active = ed.active(), previous = nil, draft = ed.draft() }))
    local again = diagram.store({ fs = fs })
    assert(again.load() == "ready")
    local data = again.data()
    assert(data.draft.objects.M1.x == 20 and data.active.objects.M1.x ~= 20, "the draft survives, the active layout is what it was")
    fs.set("state/panel_layout.json", "{ broken"); fs.set("state/panel_layout.json.prev", "x")
    local broken = diagram.store({ fs = fs })
    local state, err = broken.load()
    assert(state == "corrupt" and err and broken.data() == nil)
  end
}
