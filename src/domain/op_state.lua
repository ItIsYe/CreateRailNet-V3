--[[
Purpose: The operating state of the whole network and what it allows (Gesamtkonzept Kap. 18).
Public API: derive(inputs) -> state, reason; allows_new_departure(state, area_independent) -> boolean, why; STATES; describe(state) -> German text.
  inputs = { setup_done, test_mode, fault_locked (reason text or true), recovery, maintenance, both_masters (bool, nil = single master plan), commit_clear, local_faults (list of area ids), area_independent }
States: INITIAL_SETUP, TEST_MODE, NORMAL, DEGRADED_GLOBAL, DEGRADED_LOCAL, RECOVERY, MAINTENANCE, FAULT_LOCKED.
Notes: the strictest applicable state wins, in this order: FAULT_LOCKED, INITIAL_SETUP, RECOVERY, MAINTENANCE, TEST_MODE, DEGRADED_GLOBAL, DEGRADED_LOCAL, NORMAL. A missing second master or an unclear commit is global
  (no new safety critical journey anywhere); a local defect only closes its areas, and journeys in fully independent, checked areas go on only while the global conditions hold (NORMAL for the rest).
  A test mode allows only explicitly controlled test procedures: no new departure for production traffic.
]]

local op_state = {}

op_state.STATES = { "INITIAL_SETUP", "TEST_MODE", "NORMAL", "DEGRADED_GLOBAL", "DEGRADED_LOCAL", "RECOVERY", "MAINTENANCE", "FAULT_LOCKED" }

local TEXT = {
  INITIAL_SETUP = "Einrichtung: keine Abnahme",
  TEST_MODE = "Testbetrieb: nur kontrollierte Testfahrten",
  NORMAL = "Normalbetrieb",
  DEGRADED_GLOBAL = "Eingeschraenkt (global): zweiter Master fehlt oder Commit unklar, keine neuen Fahrten",
  DEGRADED_LOCAL = "Eingeschraenkt (lokal): betroffene Bereiche gesperrt",
  RECOVERY = "Wiederherstellung: betroffene Bereiche ohne neue Fahrten",
  MAINTENANCE = "Wartung: betroffene Abhaengigkeiten ohne neue Fahrten",
  FAULT_LOCKED = "Gesperrt: Sicherheitsinvariante verletzt oder keine Evidenz"
}

function op_state.describe(state) return TEXT[state] or tostring(state) end

function op_state.derive(inputs)
  local i = inputs or {}
  if i.fault_locked then return "FAULT_LOCKED", type(i.fault_locked) == "string" and i.fault_locked or "Sicherheitsinvariante verletzt" end
  if i.setup_done == false then return "INITIAL_SETUP", "keine Abnahme" end
  if i.recovery then return "RECOVERY", "Neustart oder Zustandsunklarheit" end
  if i.maintenance then return "MAINTENANCE", "Wartungsfreigabe" end
  if i.test_mode then return "TEST_MODE", "isolierter Testbereich" end
  if i.both_masters == false then return "DEGRADED_GLOBAL", "zweiter Master fehlt" end
  if i.commit_clear == false then return "DEGRADED_GLOBAL", "Commit unklar" end
  if type(i.local_faults) == "table" and #i.local_faults > 0 then return "DEGRADED_LOCAL", "lokaler Defekt: " .. table.concat(i.local_faults, ", ") end
  return "NORMAL", "alle Voraussetzungen geprueft"
end

-- area_independent: the area of the journey does not depend on anything that is faulty (checked, fully independent)
function op_state.allows_new_departure(state, area_independent, global_ready)
  if state == "NORMAL" then return true end
  if state == "DEGRADED_LOCAL" then
    if area_independent == true and global_ready ~= false then return true end
    return false, "Bereich nicht nachweislich unabhaengig von der Stoerung"
  end
  return false, op_state.describe(state)
end

return op_state
