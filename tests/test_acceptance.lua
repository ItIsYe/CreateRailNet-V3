--[[
Purpose: The acceptance matrix is whole and honest: all 112 cases of the concept and the 8 end-to-end checks are there, every listed test exists, nothing is PASS without its evidence, and the release stage follows from the cases (Kap. 20, 20.2).
Public API: returns table of tests.
]]

local matrix = dofile("tests/acceptance/matrix.lua")
local lib = dofile("tests/acceptance/lib.lua")

local function read(path)
  local fh = io.open(path, "r")
  if not fh then return nil end
  local body = fh:read("*a")
  fh:close()
  return body
end

local function copy_matrix(passed)
  local out = { cases = {}, risks = matrix.risks, signoff = {} }
  local evidence = {}
  for _, field in ipairs(lib.EVIDENCE_FIELDS) do evidence[field] = "x" end
  for index, c in ipairs(matrix.cases) do
    out.cases[index] = { id = c.id, group = c.group, title = c.title, criterion = c.criterion, coverage = c.coverage, refs = c.refs, status = passed[c.id] and "PASS" or c.status, evidence = passed[c.id] and evidence or nil }
  end
  return out
end

local function all_pass_except(skip)
  local passed = {}
  for _, c in ipairs(matrix.cases) do if not (skip and skip[c.id]) then passed[c.id] = true end end
  return passed
end

return {
  test_the_matrix_has_every_case_of_the_concept_and_every_listed_test_exists = function()
    local problems = lib.validate(matrix, read)
    assert(#problems == 0, table.concat(problems, "\n"))
    assert(#matrix.cases == 120 and #matrix.risks == 12)
  end,

  test_the_report_in_docs_is_current = function()
    local fresh = lib.report(matrix)
    assert(read("docs/ABNAHME.md") == fresh, "docs/ABNAHME.md is out of date: run lua scripts/acceptance_report.lua --write")
  end,

  test_nothing_has_run_in_the_game_so_nothing_is_pass_and_no_stage_is_reached = function()
    local s = lib.summary(matrix)
    assert(s.PASS == 0 and s.FAIL == 0 and s.BLOCKED == 0 and s.NOT_RUN == 120)
    local stage = lib.stage(matrix)
    assert(stage == "NONE")
  end,

  test_a_pass_without_evidence_is_a_problem_and_blocked_is_not_a_pass = function()
    local copy = copy_matrix({})
    copy.cases[1].status = "PASS"
    local problems = lib.validate(copy, read)
    assert(table.concat(problems, "\n"):find("A-01: PASS without evidence", 1, true))
    copy.cases[1].evidence = { test_id = "A-01" }
    assert(table.concat(lib.validate(copy, read), "\n"):find("PASS without evidence field environment", 1, true))
    copy.cases[1].status, copy.cases[1].evidence = "BLOCKED", nil
    assert(lib.stage(copy) == "NONE" and lib.summary(copy).PASS == 0)
  end,

  test_a_stage_needs_all_of_its_cases_and_all_stages_below = function()
    local lab = copy_matrix((function() local p = {} for n = 1, 10 do p[string.format("A-%02d", n)] = true end return p end)())
    assert(lib.stage(lab) == "G1")
    local missing = copy_matrix((function() local p = {} for n = 1, 9 do p[string.format("A-%02d", n)] = true end return p end)())
    assert(lib.stage(missing) == "NONE", "one lab case missing: no stage")
    local no_lab = all_pass_except({ ["A-08"] = true })
    assert(lib.stage(copy_matrix(no_lab)) == "NONE", "later cases do not make up for a lab case")
  end,

  test_g5_needs_the_signoff_and_a_failed_master_or_trust_case_forbids_it = function()
    local everything = copy_matrix(all_pass_except())
    local stage, why = lib.stage(everything)
    assert(stage == "G4" and why:find("load reserve", 1, true), stage .. " " .. why)
    everything.signoff = { load_reserve = "30 % TPS-Reserve gemessen", release_decision = "Freigabe 2026-11-01", responsible = "ED" }
    assert(lib.stage(everything) == "G5")
    for _, c in ipairs(everything.cases) do if c.id == "E-05" then c.status, c.evidence = "FAIL", nil end end
    local failed, reason = lib.stage(everything)
    assert(failed ~= "G5" and failed ~= "G4" or reason:find("E-05", 1, true), failed .. " " .. reason)
  end,

  test_a_failed_or_blocked_case_of_a_stage_is_not_a_pass_for_the_stage = function()
    for _, status in ipairs({ "FAIL", "BLOCKED" }) do
      local copy = copy_matrix((function() local p = {} for n = 1, 10 do p[string.format("A-%02d", n)] = true end return p end)())
      assert(lib.stage(copy) == "G1")
      copy.cases[3].status, copy.cases[3].evidence = status, nil
      local stage, why = lib.stage(copy)
      assert(stage == "NONE" and why:find("A-03=" .. status, 1, true), why)
    end
  end,

  test_the_stage_sets_match_the_concept_counts = function()
    local sizes = {}
    for _, stage in ipairs(lib.STAGES) do sizes[stage.name] = #stage.cases end
    assert(sizes.G1 == 10 and sizes.G5 == 8)
    local covered = {}
    for _, stage in ipairs(lib.STAGES) do for _, id in ipairs(stage.cases) do assert(not covered[id], id .. " in two stages"); covered[id] = true end end
    for _, c in ipairs(matrix.cases) do assert(covered[c.id], c.id .. " belongs to no stage") end
  end,

  test_a_case_that_only_the_game_can_show_lists_no_test_and_every_other_lists_one = function()
    for _, c in ipairs(matrix.cases) do
      assert((c.coverage == "GAME") == (#c.refs == 0), c.id)
    end
  end
}
