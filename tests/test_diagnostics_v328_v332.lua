--[[
Purpose: Tests for V3.28-V3.32 diagnostics and health report.
Public API: returns table of tests.
]]

local log = require("src.shared.log")
local diagnostics = require("src.domain.diagnostics")
local health_report = require("src.tools.health_report")
local panel_renderer = require("src.nodes.panel_renderer")

local function fake_monitor()
  local m = { lines = {}, cursor = {1, 1} }
  function m.clear() m.lines = {} end
  function m.setCursorPos(x, y) m.cursor = {x, y} end
  function m.write(text) m.lines[m.cursor[2]] = text end
  return m
end

local function contains_line(lines, text)
  for _, line in pairs(lines or {}) do
    if string.find(tostring(line), text, 1, true) then return true end
  end
  return false
end

return {
  test_diagnostics_builds_summary = function()
    local logger = log.new("INFO", 20)
    logger.warn("test warning", { code = "T" })
    local diag = diagnostics.build({
      config = { channel = 1, master_id = "M", nodes = {}, blocks = {}, routes = {}, service_plans = {} },
      logger = logger,
      registry = { all = function() return { A = { role = "master", status = "up" }, B = { role = "train", status = "down" } } end },
      dispatcher = { get_queue = function() return { { train_id = "T" } } end, get_switch_locks = function() return {} end, get_deadlocks = function() return {} end }
    })
    assert(diag.node_health.total == 2)
    assert(diag.node_health.down == 1)
    assert(#diag.recent_logs == 1)
    assert(#diag.queue == 1)
  end,

  test_health_report_full_example = function()
    local ok, report = health_report.run({ config = "configs/templates/network.full.example.json" })
    assert(ok)
    assert(report.counts.nodes > 0)
    assert(report.counts.routes > 0)
  end,

  test_panel_renders_diagnostics_summary = function()
    local monitor = fake_monitor()
    panel_renderer.render(monitor, {
      display_name = "Panel",
      page = "diagnostics",
      master_state = "ONLINE",
      diagnostics = {
        node_health = { up = 2, down = 1, total = 3 },
        config = { nodes = 3, blocks = 2, routes = 1, service_plans = 1, channel = 777, master_id = "MASTER-1" },
        queue = {},
        deadlocks = {},
        switch_locks = {},
        pending_departures = {},
        recent_logs = { { level = "WARN", msg = "warning" } }
      }
    })
    assert(contains_line(monitor.lines, "2/1"))
    assert(contains_line(monitor.lines, "3/2/1/1"))
    assert(contains_line(monitor.lines, "WARN"))
  end
}
