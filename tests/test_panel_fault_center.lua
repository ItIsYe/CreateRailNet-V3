--[[
Purpose: Fault center and page table: an acknowledgement never clears a cause, pages respect the level and old values are labelled (Gesamtkonzept Kap. 11.2, S-11).
Public API: returns table of tests.
]]

local fault_center = require("src.panel.fault_center")
local pages = require("src.panel.pages")
local monitor_registry = require("src.panel.monitor_registry")

local t = 0
local function new() t = 0; return fault_center.new({ now = function() return t end }) end

return {
  test_an_acknowledged_fault_stays_in_the_list_and_is_not_cleared = function()
    local c = new()
    c.raise("block:B1", { severity = "RED", message = "Block B1 unklar" })
    assert(c.counts().unseen == 1)
    assert(c.ack("block:B1", "PANEL-1"))
    assert(c.is_open("block:B1") and #c.list() == 1, "the entry must stay")
    assert(c.get("block:B1").state == "ACTIVE_SEEN" and c.counts().unseen == 0 and c.counts().red == 1)
  end,

  test_the_first_acknowledgement_stays_the_record = function()
    local c = new()
    c.raise("x", {})
    t = 3; c.ack("x", "PANEL-1")
    t = 9; c.ack("x", "PANEL-2")
    assert(c.get("x").acked_by == "PANEL-1" and c.get("x").acked_at == 3)
  end,

  test_only_a_proof_clears_a_cause = function()
    local c = new()
    c.raise("block:B1", { severity = "RED" })
    c.ack("block:B1", "PANEL-1")
    assert(not c.resolve("block:B1"))
    assert(not c.resolve("block:B1", { kind = "click" }))
    assert(c.is_open("block:B1"))
    assert(c.resolve("block:B1", { kind = "free_proven", source = "tail_sensor" }))
    assert(not c.is_open("block:B1") and #c.list() == 0)
    assert(#c.list({ include_resolved = true }) == 1)
  end,

  test_a_repeated_raise_keeps_the_acknowledgement_and_a_resolved_one_opens_again_as_new = function()
    local c = new()
    c.raise("x", { severity = "YELLOW" }); c.ack("x", "P")
    t = 5; c.raise("x", {})
    assert(c.get("x").state == "ACTIVE_SEEN" and c.get("x").count == 2)
    c.resolve("x", { kind = "k", source = "s" })
    c.raise("x", {})
    assert(c.get("x").state == "ACTIVE" and c.get("x").count == 1)
  end,

  test_the_list_is_sorted_by_severity_and_unseen_first = function()
    local c = new()
    c.raise("c", { severity = "INFO" }); c.raise("b", { severity = "RED" }); c.raise("a", { severity = "RED" })
    c.ack("a", "P")
    local l = c.list()
    assert(l[1].key == "b" and l[2].key == "a" and l[3].key == "c", l[1].key .. l[2].key .. l[3].key)
    assert(not c.raise("") and not c.ack("nope"))
  end,

  test_the_list_of_the_master_is_followed_and_only_the_master_closes_a_cause = function()
    local c = new()
    c.sync({ { key = "a", severity = "RED", text = "Block B1 unklar" }, { key = "b", severity = "YELLOW", text = "Knoten weg", acked = true, acked_by = "P1" } })
    assert(c.get("a").state == "ACTIVE" and c.get("b").state == "ACTIVE_SEEN" and c.get("b").acked_by == "P1" and c.get("a").message == "Block B1 unklar")
    c.sync({ { key = "a", severity = "RED", text = "Block B1 unklar", acked = true, acked_by = "P2" } })
    assert(c.get("a").state == "ACTIVE_SEEN" and not c.is_open("b") and c.get("b").proof.source == "master")
    c.sync({})
    assert(#c.list() == 0)
    c.sync({ { key = "a", severity = "RED", text = "wieder" } })
    assert(c.get("a").state == "ACTIVE" and c.get("a").count == 1, "a returning cause opens as new")
  end,

  test_pages_are_a_subset_of_the_registry_views_and_follow_the_level = function()
    for _, page in ipairs(pages.list()) do assert(monitor_registry.VIEWS[page.id], page.id) end
    for id in pairs(monitor_registry.VIEWS) do assert(pages.get(id), "no page for " .. id) end
    assert(not pages.allowed("maintenance", "operate") and pages.allowed("maintenance", "admin"))
    assert(pages.allowed("fault_center", "view") and not pages.allowed("cargo", "view"))
    assert(#pages.visible("view") < #pages.visible("operate") and #pages.visible("operate") < #pages.visible("admin"))
    assert(not pages.allowed("nonsense", "admin"))
  end,

  test_old_values_are_labelled_and_never_shown_as_current = function()
    assert(pages.freshness(2) == "fresh" and pages.freshness(11) == "stale" and pages.freshness(nil) == "none")
    assert(pages.freshness(20, { stale_after_s = 30 }) == "fresh")
    assert(pages.label("stale") == "veraltet" and pages.label("none") == "keine Daten" and pages.label("fresh") == "aktuell")
  end
}
