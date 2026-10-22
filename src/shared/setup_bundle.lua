--[[
Purpose: The setup tools (wizard, doctor, key tool, function test, planner ...) are not on a running computer: a computer holds a fixed 1 000 000 bytes. They are fetched when needed and removed again when the tool is done.
Public API:
  run(main, args, env) -> true | nil, err   env: fs, shell, say, ref (optional). Makes sure the bundle is there (installer --setup), runs main (scripts/<tool>_main.lua) with args, removes the bundle (installer --slim)
  present(fs) -> bool                        is the bundle on this computer
  recorded_ref(fs) -> text | nil             the ref the installation record names (the bundle must come from exactly that state)
  slim(env) -> true | nil, err               remove the bundle (also what the wizard calls before it restarts the computer)
Notes: the stubs scripts/setup.lua, keys.lua and auth_bench.lua call run(). The bundle always comes from the installed state (same ref, same manifest id): the installer refuses a bundle of another state, an update is a separate step.
  Without the installer on the computer (or without http) nothing is fetched and the message says what to do.
]]

local setup_bundle = {}

local unpack_fn = table.unpack or unpack

setup_bundle.MARKER = "src/setup/wizard.lua"
setup_bundle.RECORD = "crn_install.lua"

local function read(fsys, path)
  if not (fsys and fsys.exists and fsys.exists(path)) then return nil end
  local fh = fsys.open(path, "r")
  if not fh then return nil end
  local body = fh.readAll()
  fh.close()
  return body
end

function setup_bundle.present(fsys)
  return fsys ~= nil and fsys.exists ~= nil and fsys.exists(setup_bundle.MARKER) == true
end

function setup_bundle.recorded_ref(fsys)
  local body = read(fsys, setup_bundle.RECORD)
  return body and body:match('ref%s*=%s*"([^"\n]+)"') or nil
end

local function installer_args(env, flag)
  local list = { "installer", flag, "--yes" }
  local ref = env.ref or setup_bundle.recorded_ref(env.fs)
  if ref then list[#list + 1] = "--ref"; list[#list + 1] = ref end
  return list
end

local function call_installer(env, flag)
  if not (env.shell and env.shell.run) then return nil, "keine Shell" end
  if not (env.fs and env.fs.exists and env.fs.exists("installer")) then
    return nil, "Der Installer liegt nicht auf diesem Computer. Neu laden: wget run https://raw.githubusercontent.com/ItIsYe/CreateRailNet-V3/<ref>/installer " .. flag
  end
  local list = installer_args(env, flag)
  local ok = env.shell.run(unpack_fn(list))
  if not ok then return nil, "installer " .. flag .. " ist fehlgeschlagen" end
  return true
end

function setup_bundle.slim(env)
  if not setup_bundle.present(env.fs) then return true end
  return call_installer(env, "--slim")
end

function setup_bundle.run(main, args, env)
  local say = env.say or print
  if not setup_bundle.present(env.fs) then
    say("Die Einrichtungs-Dateien sind auf diesem Computer nicht abgelegt (Platz). Sie werden geladen ...")
    local fetched, err = call_installer(env, "--setup")
    if not fetched or not setup_bundle.present(env.fs) then
      return nil, "Die Einrichtungs-Dateien konnten nicht geladen werden: " .. tostring(err or "Dateien fehlen nach dem Laden")
    end
  end
  local list = { main }
  for _, arg in ipairs(args or {}) do list[#list + 1] = arg end
  local ok = env.shell.run(unpack_fn(list))
  local slimmed, slim_err = setup_bundle.slim(env)
  if not slimmed then say("Hinweis: die Einrichtungs-Dateien konnten nicht wieder entfernt werden (" .. tostring(slim_err) .. "): installer --slim") end
  if not ok then return nil, "failed" end
  return true
end

return setup_bundle
