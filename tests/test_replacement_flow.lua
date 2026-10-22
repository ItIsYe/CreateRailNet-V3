--[[
Purpose: The replacement of a computer from the panel to the disk: the buttons of the maintenance view, the actions of the master, the key that never travels in a message, the signals read back from the heartbeat (Pruefplan I-11, F-08).
Public API: returns table of tests.
]]

local manual_control = require("src.master.manual_control")
local replacement_setup = require("src.master.replacement_setup")
local keystore = require("src.shared.keystore")
local keyring = require("src.shared.keyring")
local views = require("src.panel.views")
local permissions = require("src.panel.permissions")
local memfs = require("tests.harness.memfs")
local multi_display = require("src.panel.multi_display")
local monitor_registry = require("src.panel.monitor_registry")

local MASTER_KEY = string.rep("5e", 32)
local PLAN = { nodes = { { id = "MASTER-1", role = "master" }, { id = "SIG-1", role = "signal", signals = { "S-A", "S-B" } }, { id = "PANEL-1", role = "panel", permission = "admin" } } }

local function world(drive)
  local w = { fs = memfs.new(), audits = {}, held = {}, reports = {} }
  keystore.save_master({ key = MASTER_KEY }, nil, { fs = w.fs })
  local trust = { rev = 0, nodes = {} }
  keystore.issue(trust, MASTER_KEY, "SIG-1", "signal", 1)
  keystore.save_trust(trust, nil, { fs = w.fs })
  local peripheral = { getNames = function() return drive and { "drive_0" } or {} end, getType = function() return "drive" end, call = function() return "disk" end }
  w.setup = replacement_setup.build({ config = PLAN, fs = w.fs, peripheral = peripheral, now = function() return 1 end, on_hold = function(id) w.held[#w.held + 1] = id end })
  w.mc = manual_control.new({ network = { send = function() end }, replacement = w.setup, audit_log = { record = function(kind, data) w.audits[#w.audits + 1] = { kind = kind, data = data } end },
    signal_report = function(id) return w.reports[id] end })
  function w.act(action, extra)
    local cmd = { action = action, node_id = "SIG-1", operator = "ED" }
    for k, v in pairs(extra or {}) do cmd[k] = v end
    return w.mc.handle(cmd, "PANEL-1")
  end
  return w
end

return {
  test_the_whole_replacement_goes_through_the_actions_and_ends_with_a_released_hold = function()
    local w = world(true)
    assert(w.act("replace_begin") == true and w.held[1] == "SIG-1")
    local ok, message = w.act("replace_adopt")
    assert(ok == true and message:find("Diskette", 1, true) and message:find("Pruefsumme", 1, true), tostring(message))
    local file = w.fs.files["disk/crn_key_SIG-1.json"]
    assert(file, "the key is on the disk")
    local key = file:match('"key"%s*:%s*"(%x+)"')
    assert(key and not message:find(key, 1, true), "the message does not carry the key")
    assert(message:find(keyring.fingerprint(key), 1, true), "it names the fingerprint")
    assert(w.act("replace_key", { matches = true }) == true)
    -- the new computer has not reported its signals yet
    local ok2, why = w.act("replace_bindings")
    assert(ok2 == false and why:find("S-A", 1, true))
    w.reports["SIG-1"] = { signals = { ["S-A"] = "OK", ["S-B"] = "MISSING" } }
    local ok3, why3 = w.act("replace_bindings")
    assert(ok3 == false and why3:find("S-B", 1, true) and not why3:find("S-A", 1, true))
    w.reports["SIG-1"] = { signals = { ["S-A"] = "OK", ["S-B"] = "OK" } }
    assert(w.act("replace_bindings") == true)
    assert(w.act("replace_finish", { test_ok = false }) == false)
    assert(w.act("replace_finish", { test_ok = true }) == true)
    assert(w.setup.wizard.state_of("SIG-1").state == "DONE")
    local kinds = {}
    for _, a in ipairs(w.audits) do kinds[a.kind] = true end
    assert(kinds.replace_begin and kinds.replace_adopt and kinds.replace_key and kinds.replace_bindings and kinds.replace_finish)
  end,

  test_no_disk_means_no_key_and_the_start_is_taken_back = function()
    local w = world(false)
    assert(w.act("replace_begin") == true)
    local ok, message = w.act("replace_adopt")
    assert(ok == false and message:find("zurueckgenommen", 1, true), tostring(message))
    assert(w.setup.wizard.state_of("SIG-1").state == "WAIT_NEW_COMPUTER")
    assert(keystore.load_trust(nil, { fs = w.fs }).nodes["SIG-1"].status == "revoked", "no key is out")
  end,

  test_a_wrong_fingerprint_withdraws_the_key = function()
    local w = world(true)
    w.act("replace_begin"); w.act("replace_adopt")
    local ok = w.act("replace_key", { matches = false })
    assert(ok == false and w.setup.wizard.state_of("SIG-1").state == "WAIT_NEW_COMPUTER")
  end,

  test_without_a_wizard_the_actions_say_why = function()
    local mc = manual_control.new({ network = { send = function() end } })
    local ok, why = mc.handle({ action = "replace_begin", node_id = "SIG-1" }, "PANEL-1")
    assert(ok == false and why:find("unavailable", 1, true))
  end,

  test_the_actions_need_the_admin_level_and_the_confirmation = function()
    local cfg = { nodes = { { id = "OP", role = "panel", permission = "operate" }, { id = "AD", role = "panel", permission = "admin" } } }
    for _, action in ipairs({ "replace_begin", "replace_adopt", "replace_key", "replace_bindings", "replace_finish" }) do
      assert(not permissions.check(cfg, "OP", action, { confirm = true }), action .. " is not for operate")
      assert(not permissions.check(cfg, "AD", action, {}), action .. " asks for the confirmation")
      assert(permissions.check(cfg, "AD", action, { confirm = true }))
    end
  end,

  test_the_maintenance_view_shows_the_button_of_the_step_and_a_touch_gives_the_action = function()
    local devices = {}
    local m = { rows = {}, w = 60, h = 19, x = 1, y = 1 }
    function m.getSize() return m.w, m.h end
    function m.clear() m.rows = {} end
    function m.setCursorPos(x, y) m.x, m.y = x, y end
    function m.write(t) local row = m.rows[m.y] or ""; row = row .. string.rep(" ", math.max(0, m.x - 1 - #row)); m.rows[m.y] = row:sub(1, m.x - 1) .. t .. row:sub(m.x + #t) end
    function m.setTextScale() end
    local function screen() local out = {} for y = 1, m.h do out[#out + 1] = m.rows[y] or "" end return table.concat(out, "\n") end
    devices.monitor_0 = m
    local api = { getNames = function() return { "monitor_0" } end, getType = function() return "monitor" end, wrap = function(n) return devices[n] end }
    local registry = monitor_registry.new({ fs = memfs.new(), peripheral = api, node_id = "PANEL-1" })
    registry.load(); assert(registry.bind("W", "monitor_0", { confirmed = true, start_view = "maintenance" }))
    local state = { master_state = "ONLINE", last_update = 1, diagnostics = { maintenance = { enabled = false }, update_locks = { { node_id = "SIG-2", reason = "Rollback" } } },
      nodes = { ["MASTER-1"] = { role = "master" }, ["SIG-1"] = { role = "signal", status = "UP" } }, replacements = {} }
    local display = multi_display.new({ registry = registry, model = function() return state end, level = "admin", now = function() return 2 end })
    display.refresh()
    local text = screen()
    assert(text:find("Sperre SIG-2: Rollback", 1, true) and text:find("[SIG-1 UP]", 1, true) and not text:find("MASTER-1", 1, true), text)
    local begin
    for y, row in pairs(m.rows) do if row:find("[SIG-1 UP]", 1, true) then begin = display.touch("monitor_0", 3, y) end end
    assert(begin.action.action == "replace_begin" and begin.action.node_id == "SIG-1")
    state.replacements = { ["SIG-1"] = { state = "WAIT_KEY_CHECK", fingerprint = "aaaa-bbbb-cccc" } }
    display.refresh()
    text = screen()
    assert(text:find("Pruefsumme aaaa-bbbb-cccc", 1, true) and text:find("[Pruefsumme stimmt]", 1, true) and text:find("[stimmt NICHT]", 1, true))
    local yes, no
    for y, row in pairs(m.rows) do
      local a = row:find("[Pruefsumme stimmt]", 1, true)
      local b = row:find("[stimmt NICHT]", 1, true)
      if a then yes = display.touch("monitor_0", a + 2, y) end
      if b then no = display.touch("monitor_0", b + 2, y) end
    end
    assert(yes.action.action == "replace_key" and yes.action.matches == true and yes.action.node_id == "SIG-1")
    assert(no.action.matches == false)
    -- a lower level sees the page refused
    local low = multi_display.new({ registry = registry, model = function() return state end, level = "operate", now = function() return 2 end })
    low.refresh()
    assert(not screen():find("[Pruefsumme stimmt]", 1, true))
  end
}
