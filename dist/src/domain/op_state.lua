









local op_state={}

op_state.STATES={"INITIAL_SETUP","TEST_MODE","NORMAL","DEGRADED_GLOBAL","DEGRADED_LOCAL","RECOVERY","MAINTENANCE","FAULT_LOCKED"}

local TEXT={
INITIAL_SETUP="Einrichtung: keine Abnahme",
TEST_MODE="Testbetrieb: nur kontrollierte Testfahrten",
NORMAL="Normalbetrieb",
DEGRADED_GLOBAL="Eingeschraenkt (global): zweiter Master fehlt oder Commit unklar, keine neuen Fahrten",
DEGRADED_LOCAL="Eingeschraenkt (lokal): betroffene Bereiche gesperrt",
RECOVERY="Wiederherstellung: betroffene Bereiche ohne neue Fahrten",
MAINTENANCE="Wartung: betroffene Abhaengigkeiten ohne neue Fahrten",
FAULT_LOCKED="Gesperrt: Sicherheitsinvariante verletzt oder keine Evidenz"
}

function op_state.describe(state)return TEXT[state] or tostring(state)end

function op_state.derive(inputs)
local i=inputs or{}
if i.fault_locked then return "FAULT_LOCKED",type(i.fault_locked)=="string" and i.fault_locked or "Sicherheitsinvariante verletzt" end
if i.setup_done==false then return "INITIAL_SETUP","keine Abnahme" end
if i.recovery then return "RECOVERY","Neustart oder Zustandsunklarheit" end
if i.maintenance then return "MAINTENANCE","Wartungsfreigabe" end
if i.test_mode then return "TEST_MODE","isolierter Testbereich" end
if i.both_masters==false then return "DEGRADED_GLOBAL","zweiter Master fehlt" end
if i.commit_clear==false then return "DEGRADED_GLOBAL","Commit unklar" end
if type(i.local_faults)=="table" and#i.local_faults>0 then return "DEGRADED_LOCAL","lokaler Defekt: " .. table.concat(i.local_faults,", ")end
return "NORMAL","alle Voraussetzungen geprueft"
end


function op_state.allows_new_departure(state,area_independent,global_ready)
if state=="NORMAL" then return true end
if state=="DEGRADED_LOCAL" then
if area_independent==true and global_ready~=false then return true end
return false,"Bereich nicht nachweislich unabhaengig von der Stoerung"
end
return false,op_state.describe(state)
end

return op_state
