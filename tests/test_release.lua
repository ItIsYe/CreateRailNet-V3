--[[
Purpose: The release of the operation (config require_release): until the operator releases it no train starts a journey, and the release
  needs a network that is as it should be. Arrivals, sensors and repairs go on; a restart takes the release back.
Public API: returns table of tests.
]]

pcall(dofile, "tests/harness/cc_bootstrap.lua")

local runtime_factory = require("src.master.runtime")
local registry_factory = require("src.shared.registry")
local alerts_module = require("src.domain.alerts")
local validate = require("src.shared.validate")
local setup_panel = require("src.master.ui.panels.setup")
local pairing_module = require("src.master.pairing")
local memfs = require("tests.harness.memfs")
local netplan = require("src.setup.netplan")

local NODES = {
  { id = "M", role = "master" }, { id = "SIG-1", role = "signal" }, { id = "SEN-1", role = "sensor" }, { id = "ST-1", role = "station" },
  { id = "DEP-1", role = "depot" }, { id = "TRAIN-1", role = "train" }, { id = "PANEL-1", role = "panel", permission = "admin" }, { id = "FLEET-1", role = "fleet" },
}

local function master(opts)
  local o = opts or {}
  local env = { calls = {}, sent = {}, audits = {}, now = 1000, overview = {} }
  local function count(name) env.calls[name] = (env.calls[name] or 0) + 1 end
  env.registry = registry_factory.new()
  env.alerts = alerts_module.new()
  local cfg = { v = 1, channel = 1, master_id = "M", blocks = {}, routes = {}, nodes = NODES }
  if o.require_release ~= nil then cfg.require_release = o.require_release end
  env.runtime = runtime_factory.new({
    config = cfg, registry = env.registry,
    dispatcher = {
      get_overview = function() return env.overview end, timeout_node = function() end,
      on_sensor_event_by_sensor = function() count("sensor"); return true end,
      snapshot = function() return {} end,
    },
    network = {
      receive = function() return "ok" end, ack_for = function() count("ack") end, tick = function() end,
      send = function(kind, dst, payload) env.sent[#env.sent + 1] = { kind = kind, dst = dst, payload = payload } end,
      send_reliable = function(kind, dst, payload) env.sent[#env.sent + 1] = { kind = kind, dst = dst, payload = payload, reliable = true } end,
    },
    ui = { mark_dirty = function() end, draw = function() end, handle_touch = function() end },
    audit_log = { record = function(kind, data) env.audits[#env.audits + 1] = { kind = kind, data = data } end },
    alerts = env.alerts,
    manual_control = { handle = function() count("manual"); return true end },
    route_integration = {
      handle_train_request = function() count("train_request"); return true end,
      handle_train_arrival = function() count("train_arrival"); return true end,
      handle_station_ready = function() count("station_ready"); return true end,
      handle_depot_request = function() count("depot_request"); return true end,
      send_service_plan = function() count("service_plan") end,
      process_queue = function() count("queue") end,
      process_due = function() count("due") end,
    },
    train_registry = { update_status = function() end, register = function() end, list = function() return {} end },
    station_registry = { update_status = function() end, register = function() end, update_platform = function() end, list = function() return {} end },
    depot_registry = { update_status = function() end, register = function() end, update_track = function() end, list = function() return {} end },
    service_plan_registry = { list = function() return {} end },
    clock = function() return env.now end, start_timer = function() return 1 end,
    auto_restore_state = false, auto_save_state = false,
    update_control = o.update_control, maintenance = o.maintenance,
  })
  local counter = 0
  local function deliver(src, kind, payload)
    counter = counter + 1
    env.runtime.handle_event({ "modem_message", nil, nil, nil, { v = 1, pv = 4, id = src .. "." .. kind .. counter, type = kind, src = src, dst = "M", payload = payload } })
  end
  function env.event(src, payload) deliver(src, "event", payload) end
  function env.heartbeat(src, role, extra)
    local payload = { role = role }
    for k, v in pairs(extra or {}) do payload[k] = v end
    deliver(src, "heartbeat", payload)
  end
  function env.everything_up()
    for _, node in ipairs(NODES) do if node.role ~= "master" then env.heartbeat(node.id, node.role) end end
  end
  function env.audited(kind) for _, a in ipairs(env.audits) do if a.kind == kind then return a end end return nil end
  return env
end

local function ask_everything(m)
  m.event("TRAIN-1", { type = "request_departure", train_id = "TRAIN-1", route_id = "R1" })
  m.event("ST-1", { type = "station_ready_departure", station_id = "ST-1" })
  m.event("DEP-1", { type = "depot_request_dispatch", depot_id = "DEP-1" })
end

return {
  test_a_network_that_asks_for_nothing_runs_as_before = function()
    local m = master()
    ask_everything(m)
    assert(m.calls.train_request == 1 and m.calls.station_ready == 1 and m.calls.depot_request == 1)
    local ok, message = m.runtime.release_operation("PANEL-1")
    assert(ok and message:find("keine Freigabe verlangt", 1, true), message)
    assert(m.runtime.release.required == false)
  end,

  test_until_the_release_no_journey_starts_and_the_train_is_told_to_hold = function()
    local m = master({ require_release = true })
    m.everything_up()
    ask_everything(m)
    assert(m.calls.train_request == nil and m.calls.station_ready == nil and m.calls.depot_request == nil, "nothing was started")
    local hold
    for _, item in ipairs(m.sent) do if item.payload.cmd == "hold_position" then hold = item end end
    assert(hold and hold.dst == "TRAIN-1" and hold.payload.reason == "Betrieb nicht freigegeben")
    assert(m.audited("release_blocked"))
  end,

  test_arrivals_sensors_and_status_go_on = function()
    local m = master({ require_release = true })
    m.everything_up()
    m.event("TRAIN-1", { type = "arrived", train_id = "TRAIN-1" })
    m.event("TRAIN-1", { type = "train_status", train_id = "TRAIN-1" })
    m.event("SEN-1", { type = "sensor", sensor_id = "SEN-1", action = "enter" })
    assert(m.calls.train_arrival == 1 and m.calls.sensor == 1, "a train that is already on its way is not stopped by a missing release")
  end,

  test_nothing_is_dispatched_by_the_clock_and_no_service_plan_is_sent = function()
    local m = master({ require_release = true })
    m.runtime.ticker.start()
    m.now = m.now + 5
    m.runtime.ticker.poll()
    assert(m.calls.due == nil, "dwell departures wait for the release")
    m.heartbeat("TRAIN-1", "train")
    m.runtime.handle_event({ "modem_message", nil, nil, nil, { v = 1, pv = 4, id = "r.1", type = "register", src = "TRAIN-1", dst = "M", payload = { role = "train", train_id = "TRAIN-1" } } })
    assert(m.calls.service_plan == nil)
    -- released: both run
    m.everything_up()
    assert(m.runtime.release_operation("PANEL-1"))
    m.now = m.now + 5
    m.runtime.ticker.poll()
    assert(m.calls.due and m.calls.due >= 1)
  end,

  test_the_release_needs_every_computer_of_the_track_and_no_faulted_block = function()
    local m = master({ require_release = true })
    local ok, message = m.runtime.release_operation("PANEL-1")
    assert(ok == false and message:find("Computer offline", 1, true) and message:find("DEP-1", 1, true), message)
    m.heartbeat("SIG-1", "signal"); m.heartbeat("SEN-1", "sensor"); m.heartbeat("ST-1", "station")
    local ok2, message2 = m.runtime.release_operation("PANEL-1")
    assert(ok2 == false and message2:find("1 Computer offline", 1, true) and message2:find("DEP-1", 1, true))
    -- trains and panels do not have to be online: they come and go
    m.heartbeat("DEP-1", "depot")
    m.overview = { B1 = { state = "FAULT" }, B2 = { state = "FREE" } }
    local ok3, message3 = m.runtime.release_operation("PANEL-1")
    assert(ok3 == false and message3:find("1 Bloecke gestoert", 1, true), message3)
    m.overview = { B1 = { state = "FREE" } }
    local ok4, message4 = m.runtime.release_operation("PANEL-1")
    assert(ok4 and message4 == "Betrieb freigegeben.")
    assert(m.runtime.release.released and m.runtime.release.by == "PANEL-1")
    assert(m.audited("operation_released"))
  end,

  test_after_the_release_the_requests_are_handled = function()
    local m = master({ require_release = true })
    m.everything_up()
    ask_everything(m)
    assert(m.calls.train_request == nil)
    assert(m.runtime.release_operation("PANEL-1"))
    ask_everything(m)
    assert(m.calls.train_request == 1 and m.calls.station_ready == 1 and m.calls.depot_request == 1)
    local again, message = m.runtime.release_operation("PANEL-1")
    assert(again and message:find("schon freigegeben", 1, true))
  end,

  test_the_release_waits_for_the_recovery_to_be_confirmed = function()
    local m = master({ require_release = true })
    m.everything_up()
    m.runtime.recovery.required, m.runtime.recovery.confirmed = true, false
    local ok, message = m.runtime.release_operation("PANEL-1")
    assert(ok == false and message:find("Wiederanlauf", 1, true))
    assert(not m.runtime.release.released)
  end,

  test_a_panel_releases_with_a_manual_action_and_a_stranger_cannot = function()
    local m = master({ require_release = true })
    m.everything_up()
    m.event("PANEL-1", { type = "manual_control", action = "release_operation", confirm = true })
    assert(m.runtime.release.released, "the panel of the plan released it")
    local n = master({ require_release = true })
    n.everything_up()
    n.event("EVIL-1", { type = "manual_control", action = "release_operation" })
    n.event("TRAIN-1", { type = "manual_control", action = "release_operation" })
    assert(not n.runtime.release.released, "neither a stranger nor another role")
  end,

  test_the_operator_is_reminded_until_the_release_and_the_panel_shows_it = function()
    local m = master({ require_release = true })
    m.runtime.start_alert_for_test = nil
    pcall(m.runtime.start)
    assert(m.alerts.get("release:required"), "a yellow message while the operation is not released")
    m.everything_up()
    local snapshot = m.runtime.release
    assert(snapshot.required and not snapshot.released)
    assert(m.runtime.release_operation("PANEL-1"))
    assert(m.alerts.get("release:required").state == "CLEARED", "the message is gone")
    local plain = master()
    pcall(plain.runtime.start)
    assert(plain.alerts.get("release:required") == nil)
  end,

  test_the_panels_are_told_that_the_operation_is_not_released = function()
    local m = master({ require_release = true })
    m.everything_up()
    local function state_of_last_snapshot()
      m.sent = {}
      m.event("PANEL-1", { type = "panel_request_snapshot" })
      for _, item in ipairs(m.sent) do if item.payload.cmd == "panel_update" then return item.payload.master_state end end
    end
    assert(state_of_last_snapshot() == "NICHT_FREIGEGEBEN")
    assert(m.runtime.release_operation("PANEL-1"))
    assert(state_of_last_snapshot() == "ONLINE")
  end,

  test_the_panels_get_the_operating_state_and_the_update_locks = function()
    local locks = {}
    local m = master({ update_control = { locks = function() return locks end }, maintenance = { is_locked = function() return false end } })
    m.everything_up()
    local function snapshot()
      m.sent = {}
      m.event("PANEL-1", { type = "panel_request_snapshot" })
      for _, item in ipairs(m.sent) do if item.payload.cmd == "panel_update" then return item.payload end end
    end
    local normal = snapshot()
    assert(normal.op_state == "NORMAL" and normal.op_text == "Normalbetrieb", tostring(normal.op_state))
    locks[1] = { node_id = "SIG-1", reason = "Rollback" }
    local degraded = snapshot()
    assert(degraded.op_state == "DEGRADED_LOCAL" and degraded.op_reason:find("SIG-1", 1, true))
    assert(degraded.diagnostics.update_locks[1].node_id == "SIG-1")
  end,

  test_the_master_keeps_what_a_signal_node_reports_about_its_signals_for_the_replacement = function()
    local m = master()
    m.everything_up()
    assert(m.runtime.signal_report("SIG-1") == nil)
    m.heartbeat("SIG-1", "signal", { signals = { ["S-A"] = "OK", ["S-B"] = "MISSING" } })
    local report = m.runtime.signal_report("SIG-1")
    assert(report and report.signals["S-A"] == "OK" and report.signals["S-B"] == "MISSING" and report.at)
    m.heartbeat("SIG-1", "signal", { signals = { ["S-A"] = "OK", ["S-B"] = "OK" } })
    assert(m.runtime.signal_report("SIG-1").signals["S-B"] == "OK", "the last report counts")
    m.heartbeat("SEN-1", "sensor", { signals = { ["S-Z"] = "OK" } })
    assert(m.runtime.signal_report("SEN-1") == nil, "only a signal node reports signals")
  end,

  test_the_report_of_a_fleet_pair_reaches_the_panels_and_the_answer_to_an_operator_command_is_kept = function()
    local m = master()
    m.everything_up()
    m.event("FLEET-1", { type = "fleet_status", pair_id = "P1", healthy = true, report = {
      lines = { L1 = { version = 3, kind = "PASSENGER", departures = { "08:00" } } },
      trips = { ["P1-T1"] = { state = "EN_ROUTE", train_id = "TRAIN-1", to = "SUED" } },
      cargo = { O1 = { state = "OFFEN", delivered = 650, open = 350, unresolved = 50 } } } })
    m.event("FLEET-1", { type = "fleet_admin_result", request_id = "REQ-1-P1", pair_id = "P1", ok = false, conflict = true, reason = "conflict: the line is at version 3" })
    m.sent = {}
    m.event("PANEL-1", { type = "panel_request_snapshot" })
    local snapshot
    for _, item in ipairs(m.sent) do if item.payload.cmd == "panel_update" then snapshot = item.payload end end
    assert(snapshot.fleet.lines.L1.version == 3 and snapshot.fleet.lines.L1.pair_id == "P1")
    assert(snapshot.fleet.trips["P1-T1"].state == "EN_ROUTE" and snapshot.fleet.pairs.P1.healthy == true)
    assert(snapshot.cargo.O1.delivered == 650 and snapshot.cargo.O1.unresolved == 50, "only what was proven")
    local result = snapshot.fleet.results["REQ-1-P1"]
    assert(result and result.ok == false and result.conflict == true)
    assert(m.audited("fleet_admin_result"))
    -- a report without a pair id or with junk changes nothing
    m.event("FLEET-1", { type = "fleet_status", report = "junk" })
    m.event("FLEET-1", { type = "fleet_admin_result", ok = true })
  end,

  test_a_new_master_starts_not_released = function()
    local first = master({ require_release = true })
    first.everything_up()
    assert(first.runtime.release_operation("PANEL-1"))
    local second = master({ require_release = true })
    assert(second.runtime.release.released == false, "a restart takes the release back")
  end,

  -- the setup page -----------------------------------------------------------------------------------------------------------

  test_the_page_shows_the_release_as_a_line_and_a_button_with_two_touches = function()
    local fs = memfs.new()
    local cfg = { v = 1, channel = 1, master_id = "M", nodes = { { id = "M", role = "master" } }, blocks = { { id = "B" } }, routes = { { id = "R" } } }
    fs.set("configs/network.json", netplan.encode(cfg))
    local state = { required = true, released = false }
    local released_by = {}
    local clock = { t = 1000 }
    local panel = setup_panel.new({
      config = cfg, registry = { all = function() return {} end }, pairing = pairing_module.new({ config = cfg, plan_path = "configs/network.json", fs = fs }),
      now_s = function() return clock.t end,
      release = function() return state end,
      release_now = function(operator) released_by[#released_by + 1] = operator; state.released = true; return true, "Betrieb freigegeben." end,
    })
    local function screen()
      local m = { writes = {} }
      m.getSize = function() return 51, 19 end
      m.isColor = function() return true end
      m.setCursorPos = function(x, y) m.x, m.y = x, y end
      m.setBackgroundColor = function() end
      m.setTextColor = function() end
      m.write = function(text) m.writes[#m.writes + 1] = { x = m.x, y = m.y, text = text } end
      m.clear = function() m.writes = {} end
      m.text = function() local parts = {}; for _, item in ipairs(m.writes) do parts[#parts + 1] = item.text end return table.concat(parts, "\n") end
      m.at = function(needle) for _, item in ipairs(m.writes) do if item.text:find(needle, 1, true) then return item.y, item.x end end end
      return m
    end
    local m = screen()
    panel.draw(m)
    assert(m.text():find("Betrieb: nicht freigegeben (verlangt)", 1, true), m.text())
    local row, column = m.at("[BETRIEB FREIGEBEN]")
    assert(row == 14 and column == 1)
    panel.touch(4, row)
    assert(#released_by == 0, "the first touch asks")
    m = screen()
    panel.draw(m)
    assert(m.text():find("[SICHER? FREIGEBEN]", 1, true) and m.text():find("Fahrten", 1, true) and m.text():find("Nochmal tippen zum Bestaetigen", 1, true), m.text())
    panel.touch(4, row)
    assert(#released_by == 1 and released_by[1] == "MASTER-UI")
    m = screen()
    panel.draw(m)
    assert(m.text():find("Betrieb: freigegeben", 1, true) and not m.text():find("[BETRIEB FREIGEBEN]", 1, true), "released: no button any more")
    -- a plan that asks for nothing shows neither
    state.required, state.released = false, false
    m = screen()
    panel.draw(m)
    assert(not m.text():find("Betrieb:", 1, true) and not m.text():find("FREIGEBEN", 1, true))
  end,

  test_a_sixth_line_leaves_three_places_in_the_list_and_the_rest_on_the_next_page = function()
    local fs = memfs.new()
    local cfg = { v = 1, channel = 1, master_id = "M", nodes = { { id = "M", role = "master" } }, blocks = {}, routes = {} }
    fs.set("configs/network.json", netplan.encode(cfg))
    local pairing = pairing_module.new({ config = cfg, plan_path = "configs/network.json", fs = fs })
    for _, id in ipairs({ "A-1", "A-2", "A-3", "A-4" }) do pairing.announce(id, { role = "signal" }) end
    local required = true
    local panel = setup_panel.new({ config = cfg, registry = { all = function() return {} end }, pairing = pairing,
      release = function() return { required = required, released = false } end, release_now = function() return true end })
    local function draw()
      local m = { writes = {} }
      m.getSize = function() return 51, 19 end
      m.isColor = function() return true end
      m.setCursorPos = function(x, y) m.x, m.y = x, y end
      m.setBackgroundColor = function() end
      m.setTextColor = function() end
      m.write = function(text) m.writes[#m.writes + 1] = { x = m.x, y = m.y, text = text } end
      m.clear = function() m.writes = {} end
      panel.draw(m)
      local rows = {}
      for _, item in ipairs(m.writes) do if item.text:find("A-", 1, true) and item.x == 1 then rows[#rows + 1] = item.y end end
      return rows, m
    end
    local rows = draw()
    assert(#rows == 3 and rows[3] <= 13, "three places above the buttons: " .. table.concat(rows, ","))
    required = false
    rows = draw()
    assert(#rows == 4, "four places without the sixth line")
  end,

  test_require_release_must_be_true_or_false = function()
    local cfg = { v = 1, channel = 1, master_id = "M", blocks = {}, routes = {}, nodes = { { id = "M", role = "master" } } }
    assert(validate.validate_config(cfg))
    cfg.require_release = true
    assert(validate.validate_config(cfg))
    cfg.require_release = "yes"
    local ok, errors = validate.validate_config(cfg)
    assert(ok == false and errors[1]:find("require_release", 1, true))
  end,
}
