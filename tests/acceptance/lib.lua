--[[
Purpose: Checks of the acceptance matrix and the release stages G1 to G5 (Gesamtkonzept Kap. 20, 20.2).
Public API: validate(matrix, read_file) -> problems (list of text); stage(matrix) -> "NONE" | "G1" .. "G5", why; summary(matrix) -> counts; report(matrix) -> text (German, ASCII); EVIDENCE_FIELDS; STAGES.
  read_file(path) -> text | nil is how the refs are checked (the caller opens the files).
Notes: PASS needs every evidence field of Kap. 20 and a decision; BLOCKED is never PASS. A stage is reached only when every case of its set (and of every lower stage) is PASS. G5 also needs the signoff
  (load reserve documented, explicit release decision, a responsible person) and no FAIL or BLOCKED anywhere in the safety set. Critical mandatory cases are not replaced by high pass rates of other tests:
  stage() looks at the named sets only.
]]

local lib = {}

lib.EVIDENCE_FIELDS = { "test_id", "environment", "mod_versions", "commit", "topology_version", "setup_sketch", "preconditions", "actions", "expected", "observed", "ids", "journal_excerpts", "physical_proof", "responsible", "decision" }

local function range(prefix, from, to)
  local out = {}
  for n = from, to do out[#out + 1] = string.format("%s-%02d", prefix, n) end
  return out
end
local function join(...)
  local out = {}
  for _, list in ipairs({ ... }) do for _, id in ipairs(list) do out[#out + 1] = id end end
  return out
end

-- Kap. 20.2: G1 Lab, G2 Safety, G3 Pilot, G4 Integration, G5 Production
lib.STAGES = {
  { name = "G1", title = "Lab", cases = range("A", 1, 10) },
  { name = "G2", title = "Safety", cases = join(range("B", 6, 8), { "C-03", "C-04" }, range("E", 1, 12), range("F", 1, 10), { "I-07", "I-08" }) },
  { name = "G3", title = "Pilot", cases = join(range("B", 1, 5), { "B-09", "B-10" }, { "C-01", "C-02" }, range("C", 5, 12), { "E2E-01", "E2E-02", "E2E-04", "E2E-08" }) },
  { name = "G4", title = "Integration", cases = join(range("D", 1, 10), range("G", 1, 12), range("H", 1, 14), range("I", 1, 6), range("I", 9, 12), { "J-01", "J-03", "E2E-03", "E2E-05", "E2E-06", "E2E-07" }) },
  { name = "G5", title = "Production", cases = join({ "J-02" }, range("J", 4, 10)) }
}

local function index(matrix)
  local by_id = {}
  for _, c in ipairs(matrix.cases) do by_id[c.id] = c end
  return by_id
end

function lib.validate(matrix, read_file)
  local problems = {}
  local by_id, seen = index(matrix), {}
  local expected = { A = 10, B = 10, C = 12, D = 10, E = 12, F = 10, G = 12, H = 14, I = 12, J = 10, E2E = 8 }
  local counts = {}
  for _, c in ipairs(matrix.cases) do
    if seen[c.id] then problems[#problems + 1] = "duplicate case " .. c.id end
    seen[c.id] = true
    counts[c.group] = (counts[c.group] or 0) + 1
    if c.status ~= "NOT_RUN" and c.status ~= "PASS" and c.status ~= "FAIL" and c.status ~= "BLOCKED" then problems[#problems + 1] = c.id .. ": unknown status " .. tostring(c.status) end
    if c.coverage ~= "OFFLINE" and c.coverage ~= "PARTIAL" and c.coverage ~= "GAME" then problems[#problems + 1] = c.id .. ": unknown coverage " .. tostring(c.coverage) end
    if c.coverage ~= "GAME" and #c.refs == 0 then problems[#problems + 1] = c.id .. ": coverage " .. c.coverage .. " without a test" end
    if c.coverage == "GAME" and #c.refs > 0 then problems[#problems + 1] = c.id .. ": a game-only case lists tests" end
    if c.status == "PASS" then
      local ev = c.evidence
      if type(ev) ~= "table" then problems[#problems + 1] = c.id .. ": PASS without evidence"
      else
        for _, field in ipairs(lib.EVIDENCE_FIELDS) do
          if ev[field] == nil or ev[field] == "" then problems[#problems + 1] = c.id .. ": PASS without evidence field " .. field end
        end
      end
    end
    for _, ref in ipairs(c.refs) do
      local file, fragment = ref:match("^([^#]+)#(.*)$")
      local body = file and read_file(file)
      if not body then problems[#problems + 1] = c.id .. ": test file missing: " .. tostring(ref)
      elseif fragment ~= "" and not body:find(fragment, 1, true) then problems[#problems + 1] = c.id .. ": no test named like '" .. fragment .. "' in " .. file end
    end
  end
  for group, want in pairs(expected) do
    if counts[group] ~= want then problems[#problems + 1] = "group " .. group .. " has " .. tostring(counts[group]) .. " cases, the concept lists " .. want end
  end
  for _, stage in ipairs(lib.STAGES) do
    for _, id in ipairs(stage.cases) do if not by_id[id] then problems[#problems + 1] = "stage " .. stage.name .. " names unknown case " .. id end end
  end
  for _, risk in ipairs(matrix.risks or {}) do
    for _, id in ipairs(risk.cases) do if not by_id[id] then problems[#problems + 1] = risk.id .. " names unknown case " .. id end end
  end
  if #(matrix.risks or {}) ~= 12 then problems[#problems + 1] = "the risk register has 12 entries in the concept" end
  return problems
end

local SAFETY_GROUPS = { E = true, F = true }
function lib.stage(matrix)
  local by_id = index(matrix)
  local reached, why = "NONE", "no case ran"
  for _, stage in ipairs(lib.STAGES) do
    local open = {}
    for _, id in ipairs(stage.cases) do
      local c = by_id[id]
      if not c or c.status ~= "PASS" then open[#open + 1] = id .. "=" .. (c and c.status or "missing") end
    end
    if #open > 0 then return reached, stage.name .. " not reached: " .. #open .. " case(s) not PASS (" .. table.concat(open, ", ", 1, math.min(#open, 5)) .. (#open > 5 and ", ..." or "") .. ")" end
    reached, why = stage.name, "all cases of " .. stage.name .. " are PASS"
    if stage.name == "G5" then
      local sign = matrix.signoff or {}
      if not (sign.load_reserve and sign.release_decision and sign.responsible) then return "G4", "G5 needs the documented load reserve, the explicit release decision and a responsible person" end
      for _, c in ipairs(matrix.cases) do
        if SAFETY_GROUPS[c.group] and (c.status == "FAIL" or c.status == "BLOCKED") then return "G4", "G5 is forbidden: " .. c.id .. " is " .. c.status end
      end
    end
  end
  return reached, why
end

function lib.summary(matrix)
  local counts = { NOT_RUN = 0, PASS = 0, FAIL = 0, BLOCKED = 0, OFFLINE = 0, PARTIAL = 0, GAME = 0, total = #matrix.cases }
  for _, c in ipairs(matrix.cases) do
    counts[c.status] = counts[c.status] + 1
    counts[c.coverage] = counts[c.coverage] + 1
  end
  return counts
end

function lib.report(matrix)
  local lines = {}
  local function add(text) lines[#lines + 1] = text end
  local s = lib.summary(matrix)
  local stage, why = lib.stage(matrix)
  add("# Abnahme-Matrix (Kap. 20, 21)")
  add("")
  add("Erzeugt von `lua5.4 scripts/acceptance_report.lua --write` aus `tests/acceptance/matrix.lua`; nicht von Hand bearbeiten.")
  add("")
  add("Stand: " .. s.total .. " Faelle, davon NOT_RUN " .. s.NOT_RUN .. ", PASS " .. s.PASS .. ", FAIL " .. s.FAIL .. ", BLOCKED " .. s.BLOCKED .. ".")
  add("Offline belegt (Logik): " .. s.OFFLINE .. ", teilweise: " .. s.PARTIAL .. ", nur im Spiel: " .. s.GAME .. ". **Offline belegt heisst nicht bestanden:** jeder Fall braucht den Lauf im Spiel mit Nachweis.")
  add("Erreichte Freigabestufe: **" .. stage .. "** (" .. why .. ").")
  add("")
  add("## Freigabestufen")
  add("")
  for _, st in ipairs(lib.STAGES) do add("- " .. st.name .. " " .. st.title .. ": " .. #st.cases .. " Faelle (" .. table.concat(st.cases, ", ", 1, math.min(#st.cases, 6)) .. (#st.cases > 6 and ", ..." or "") .. ")") end
  add("- G5 verlangt zusaetzlich: dokumentierte Lastreserve, ausdrueckliche Freigabe, eine verantwortliche Person; kein FAIL/BLOCKED in den Master-/Vertrauensfaellen (E, F).")
  add("")
  add("## Faelle")
  add("")
  add("| ID | Pruefschritt | Bestehenskriterium | Offline | Tests | Spiel |")
  add("|---|---|---|---|---|---|")
  for _, c in ipairs(matrix.cases) do
    local tests = {}
    for _, ref in ipairs(c.refs) do tests[#tests + 1] = (ref:gsub("#.*$", ""):gsub("^tests/", "")) end
    add("| " .. c.id .. " | " .. c.title .. " | " .. c.criterion .. " | " .. c.coverage .. " | " .. (#tests > 0 and table.concat(tests, ", ") or "-") .. " | " .. c.status .. " |")
  end
  add("")
  add("## Risiko-Register")
  add("")
  add("| ID | Risiko | Faelle | Freigabebedingung |")
  add("|---|---|---|---|")
  for _, r in ipairs(matrix.risks) do add("| " .. r.id .. " | " .. r.title .. " | " .. (#r.cases > 0 and table.concat(r.cases, ", ") or "-") .. " | " .. r.release .. " |") end
  add("")
  return table.concat(lines, "\n")
end

return lib
