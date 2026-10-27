--[[
Purpose: Startprogramm von CRN in Stufe 0: zeigt Version, Rolle, Dateiverzeichnis und freien Platz. Fahrbetrieb gibt es noch nicht; dieses Programm beweist nur, dass die Installation vollstaendig und startbar ist.
API: main.run(env) mit env = { fs, print, root } (Tests geben Fakes mit); beim Start auf dem Computer laeuft run() mit der echten Umgebung.
]]

local M = {}

local function load_table(env, path)
  if not env.fs.exists(path) then return nil end
  local fh = env.fs.open(path, "r")
  if not fh then return nil end
  local text = fh.readAll()
  fh.close()
  local chunk
  if setfenv then
    chunk = loadstring(text, "=" .. path)
    if chunk then setfenv(chunk, {}) end
  else
    chunk = load(text, "=" .. path, "t", {})
  end
  if not chunk then return nil end
  local ok, value = pcall(chunk)
  if ok and type(value) == "table" then return value end
  return nil
end

function M.run(env)
  local root = env.root or "/crn"
  local say = env.print
  local manifest = load_table(env, root .. "/manifest.lua")
  local install = load_table(env, root .. "/install.lua")
  say("CRN - Create Rail Net")
  if not manifest then
    say("Kein Dateiverzeichnis gefunden (" .. root .. "/manifest.lua). Bitte neu installieren.")
    return false
  end
  say("Version: " .. tostring(manifest.version) .. "  Stand: " .. tostring(manifest.id))
  say("Rolle: " .. tostring(install and install.role or "unbekannt"))
  local role = install and install.role
  local paths = manifest.roles and manifest.roles[role] or {}
  local bytes = 0
  local count = 0
  for _, path in ipairs(paths) do
    local entry = manifest.files and manifest.files[path]
    if entry then
      bytes = bytes + math.max(entry.size, 500)
      count = count + 1
    end
  end
  say("Programm: " .. count .. " Dateien, " .. bytes .. " Byte belegt (jede Datei zaehlt mindestens 500)")
  say("Frei auf dem Computer: " .. env.fs.getFreeSpace("/") .. " Byte")
  say("Stufe 0: noch kein Fahrbetrieb.")
  return true
end

if rawget(_G, "__CRN_TEST") then return M end
M.run({ fs = fs, print = print })
