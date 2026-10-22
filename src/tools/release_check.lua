--[[
Purpose: The check before a version tag: runs the same checks as the CI (syntax, configs, test registry, manifest, CC parse guard, the test suite
  on Lua 5.4 and 5.1), looks at the state of git (clean working tree, the tag does not exist yet), and only when everything is green prints the
  commands that set the tag and the installer command for the computers. It never sets a tag and never pushes: a tag says "this state was
  checked and is meant to be installed", and that is a person's decision.
Public API:
  run(opts) -> report { ok, lines (text for the operator), steps = list of { id, title, ok, detail } }
    opts: version ("vX.Y.Z", optionally "-suffix"), lua (default "lua5.4"), lua51 (default "lua5.1"),
          run(cmd) -> ok, detail, missing   runs one command in the repository root (missing: the program was not found)
          git(args) -> text | nil           asks git (only status / rev-parse / tag --list)
Notes: used by scripts/release_check.lua (dev tool, outside the game). All texts German, ASCII.
]]

local release_check = {}

local REPO_RAW = "https://raw.githubusercontent.com/ItIsYe/CreateRailNet-V3/"

-- vX.Y.Z, optionally with a suffix (v1.0.0-rc1): nothing that a shell would read as more than one word
function release_check.valid_version(version)
  if type(version) ~= "string" or #version > 40 then return false end
  return version:match("^v%d+%.%d+%.%d+$") ~= nil or version:match("^v%d+%.%d+%.%d+%-[%w%.]+$") ~= nil
end

function release_check.run(o)
  local opts = o or {}
  local lua, lua51 = opts.lua or "lua5.4", opts.lua51 or "lua5.1"
  local report = { ok = true, lines = {}, steps = {} }
  local function line(text) report.lines[#report.lines + 1] = text end
  local function step(id, title, ok, detail)
    report.steps[#report.steps + 1] = { id = id, title = title, ok = ok, detail = detail }
    if not ok then report.ok = false end
    line((ok and "[ OK ] " or "[FEHL] ") .. title .. (detail and detail ~= "" and (": " .. detail) or ""))
  end

  line("Release-Pruefung (setzt keinen Tag und schiebt nichts)")
  local version = opts.version
  if version ~= nil and not release_check.valid_version(version) then
    local shown = tostring(version):sub(1, 40):gsub("[^\32-\126]", "?")
    step("version", "Version", false, "'" .. shown .. "' ist keine Version der Form vX.Y.Z (z. B. v1.0.0)")
    line("Noch kein Tag: erst die Angabe berichtigen.")
    return report
  end

  local commands = {
    { "syntax", "Syntax (Lua 5.4)", lua .. " scripts/check_syntax.lua", lua },
    { "syntax51", "Syntax (Lua 5.1)", lua51 .. " scripts/check_syntax.lua", lua51 },
    { "configs", "Konfigurationen", lua .. " scripts/check_configs.lua", lua },
    { "registry", "Testregister", lua .. " scripts/check_test_registry.lua", lua },
    { "dist", "Verkleinerte Dateien (dist/)", lua .. " scripts/build_dist.lua --check", lua },
    { "manifest", "Manifest des Installers", lua .. " scripts/manifest_sync.lua --check", lua },
    { "parse", "CC-Parser-Wache (Lua 5.1)", lua51 .. " scripts/cc_parse_guard.lua", lua51 },
    { "tests", "Tests (Lua 5.4)", lua .. " scripts/run_tests.lua", lua },
    { "tests51", "Tests (Lua 5.1)", lua51 .. " scripts/run_tests.lua", lua51 },
  }
  for _, item in ipairs(commands) do
    local ok, detail, missing = opts.run(item[3])
    if ok then step(item[1], item[2], true)
    elseif missing then step(item[1], item[2], false, item[4] .. " nicht gefunden (Pfad angeben: " .. (item[4] == lua51 and "--lua51" or "--lua") .. " <Programm>)")
    else step(item[1], item[2], false, "'" .. item[3] .. "' meldet einen Fehler" .. (detail and detail ~= "" and (" (" .. tostring(detail):sub(1, 80) .. ")") or "")) end
  end

  -- git is only asked
  local status = opts.git("status --porcelain")
  local head = opts.git("rev-parse HEAD")
  local branch = opts.git("rev-parse --abbrev-ref HEAD")
  if status == nil or head == nil then
    step("git", "Git", false, "git antwortet nicht (im Hauptordner des Repositorys ausfuehren)")
  else
    head = head:gsub("%s+$", "")
    status = status:gsub("%s+$", "")
    if status == "" then step("clean", "Arbeitsverzeichnis", true, "alles eingecheckt")
    else
      local count = select(2, status:gsub("\n", "\n")) + 1
      step("clean", "Arbeitsverzeichnis", false, count .. " Datei(en) nicht eingecheckt")
    end
    if branch then line("       Stand: " .. head:sub(1, 12) .. " auf '" .. branch:gsub("%s+$", "") .. "' (der Tag gehoert auf einen Stand, der im Hauptzweig ist)") end
    if version then
      local existing = opts.git("tag --list " .. version)
      if existing == nil then step("tag", "Tag " .. version, false, "git antwortet nicht")
      elseif existing:gsub("%s+$", "") ~= "" then step("tag", "Tag " .. version, false, "gibt es schon")
      else step("tag", "Tag " .. version, true, "gibt es noch nicht") end
    end
  end

  if not report.ok then
    line("Noch kein Tag: erst muss alles gruen sein.")
    return report
  end
  if not version then
    line("Alles gruen. Fuer die Befehle zum Taggen: --version vX.Y.Z angeben.")
    return report
  end
  line("")
  line("Alles gruen. Wenn du diesen Stand als " .. version .. " festhalten willst (die Befehle fuehrt dieses Programm NICHT aus):")
  line('  git tag -a ' .. version .. ' -m "CreateRailNet ' .. version .. '" ' .. head)
  line("  git push origin " .. version)
  line("Auf den Computern danach installieren / aktualisieren mit:")
  line("  wget run " .. REPO_RAW .. version .. "/installer --ref " .. version)
  return report
end

return release_check
