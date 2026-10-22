--[[
Purpose: The permission levels of a panel and the check at the receiving node (Gesamtkonzept Kap. 11.4).
Public API: level_of(config, panel_id) -> "view" | "operate" | "admin"; check(config, panel_id, action, payload) -> true | false, reason; actions_for(level) -> sorted list; is_critical(action).
Levels: view = read only; operate = requests for routes, trains, depots and faults and precautionary locks; admin = timetable changes, profiles, monitors, maintenance, onboarding, updates.
Notes: the level of a panel is the `permission` of its node entry in the plan; a plan without one gives "operate" (what a panel could do before), an unknown word gives "view". Only a node with role panel has a level.
  The master runs check() on every manual control message: a button that the UI hides is no protection. A critical action needs `confirm = true` in the message, set by the panel after it showed the context;
  an emergency stop is not critical in that sense (it must not wait for a second click). An action that is not in the table is denied for everybody.
]]

local permissions = {}

local RANK = { view = 1, operate = 2, admin = 3 }

local ACTION_LEVEL = {
  trace_dump = "view",
  request_route = "operate", hold_train = "operate", emergency_stop = "operate", authorize_train = "operate", ack_alert = "operate",
  cargo_order = "operate", cargo_assign = "operate", cargo_loaded = "operate", cargo_delivered = "operate", cargo_cancel = "operate",
  enter_maintenance = "admin", exit_maintenance = "admin", clear_fault = "admin", set_signal = "admin", set_switch = "admin", ota_push = "admin", update_release = "admin", update_unlock = "admin",
  timetable_draft = "admin", cargo_report = "admin", timetable_publish = "admin", trip_cancel = "operate", depot_run = "operate",
  replace_begin = "admin", replace_adopt = "admin", replace_key = "admin", replace_bindings = "admin", replace_finish = "admin",
  release_train = "admin", confirm_recovery = "admin", release_operation = "admin"
}

local CRITICAL = {
  release_train = true, clear_fault = true, enter_maintenance = true, exit_maintenance = true, set_signal = true, set_switch = true,
  ota_push = true, update_release = true, update_unlock = true, timetable_publish = true, replace_begin = true, replace_adopt = true, replace_key = true, replace_bindings = true, replace_finish = true, confirm_recovery = true, release_operation = true
}

function permissions.level_of(config, panel_id)
  for _, node in ipairs((config and config.nodes) or {}) do
    if node.id == panel_id then
      if node.role ~= "panel" then return "view" end
      if node.permission == nil then return "operate" end
      return RANK[node.permission] and node.permission or "view"
    end
  end
  return "view"
end

function permissions.is_critical(action) return CRITICAL[action] == true end

function permissions.check(config, panel_id, action, payload)
  local needed = ACTION_LEVEL[action]
  if not needed then return false, "unknown action " .. tostring(action) end
  local level = permissions.level_of(config, panel_id)
  if RANK[level] < RANK[needed] then
    return false, "action " .. action .. " needs the level " .. needed .. ", the panel " .. tostring(panel_id) .. " has " .. level
  end
  if CRITICAL[action] and not (type(payload) == "table" and payload.confirm == true) then
    return false, "action " .. action .. " needs the confirmation (confirm = true) after the context was shown"
  end
  return true
end

function permissions.actions_for(level)
  local out = {}
  for action, needed in pairs(ACTION_LEVEL) do
    if RANK[needed] <= (RANK[level] or 1) then out[#out + 1] = action end
  end
  table.sort(out)
  return out
end

return permissions
