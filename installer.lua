--[[
Purpose: Installiert CRN per Download auf einen CC:Tweaked Computer: holt das Dateiverzeichnis einer festen Version, laedt nur die Dateien der gewaehlten Rolle, prueft Groesse und Pruefsumme jeder Datei und tauscht erst dann die Installation aus. Die Vorversion bleibt fuer die Rueckkehr erhalten.
Usage: installer ROLLE [REF]        installieren oder aktualisieren (REF = Tag, Commit oder Zweig, Standard: main)
       installer --rollback        zur Vorversion zurueckkehren
       installer --status          installierte Version zeigen
       installer --check           installierte Dateien gegen das Verzeichnis pruefen
       Zusatz: --yes (keine Rueckfrage), --drop-prev (Vorversion loeschen, wenn der Platz knapp ist)
Notes: Eine einzelne Datei ohne Abhaengigkeit zur Anwendung. Daten liegen getrennt in /crn_data und werden nie angefasst; Rolle und Herkunft stehen in /crn/install.lua, damit sie mit der Installation zusammen ausgetauscht werden. Bei jedem Abbruch bleibt entweder die alte oder die neue Installation vollstaendig; der naechste Start raeumt auf (recover).
]]

local M = {}

local BASE = "https://raw.githubusercontent.com/ItIsYe/CreateRailNet-V3/"
local APP, NEW, PREV, TMP, DATA = "/crn", "/crn_new", "/crn_prev", "/crn_tmp", "/crn_data"
local MIN_FILE = 500
local MARGIN = 10000
local MARK = "-- CRN-STARTUP"

-- Adler-32 wie in src/core/adler.lua (hier eingebettet, weil der Installer allein laufen muss)
local function adler_hex(text)
  local a, b = 1, 0
  local n = #text
  local i = 1
  while i <= n do
    local j = math.min(i + 255, n)
    local bytes = { string.byte(text, i, j) }
    for k = 1, #bytes do
      a = a + bytes[k]
      b = b + a
    end
    a = a % 65521
    b = b % 65521
    i = j + 1
  end
  return string.format("%08x", b * 65536 + a)
end
M.adler_hex = adler_hex

local function parse_table(text, name)
  local chunk, err
  if setfenv then
    chunk, err = loadstring(text, "=" .. name)
    if chunk then setfenv(chunk, {}) end
  else
    chunk, err = load(text, "=" .. name, "t", {})
  end
  if not chunk then return nil, err end
  local ok, value = pcall(chunk)
  if not ok then return nil, tostring(value) end
  if type(value) ~= "table" then return nil, "keine Tabelle" end
  return value
end

local function read_all(env, path)
  local fh = env.fs.open(path, "rb")
  if not fh then return nil end
  local text = fh.readAll()
  fh.close()
  return text
end

local function write_all(env, path, text)
  local fh = env.fs.open(path, "wb")
  if not fh then return false end
  fh.write(text)
  fh.close()
  return true
end

local function ensure_dir(env, path)
  local dir = env.fs.getDir(path)
  if dir ~= "" and dir ~= ".." and not env.fs.exists(dir) then
    ensure_dir(env, dir)
    env.fs.makeDir(dir)
  end
end

local function drop(env, path)
  if env.fs.exists(path) then env.fs.delete(path) end
end

-- raeumt nach einem Abbruch auf (siehe Notes oben); aendert nichts, wenn alles in Ordnung ist
function M.recover(env)
  local fs = env.fs
  if not fs.exists(APP) then
    if fs.exists(NEW) and fs.exists(NEW .. "/.complete") then
      fs.move(NEW, APP)
    elseif fs.exists(TMP) and fs.exists(PREV) then
      fs.move(PREV, APP)
    end
  end
  if fs.exists(APP) and fs.exists(TMP) and not fs.exists(PREV) then fs.move(TMP, PREV) end
  if fs.exists(APP) then
    drop(env, NEW)
    drop(env, TMP)
  elseif fs.exists(NEW) then
    drop(env, NEW)
  end
end

local function fetch(env, url)
  local ok, handle = pcall(env.http.get, url, nil, true)
  if not ok or not handle then return nil end
  local text = handle.readAll()
  handle.close()
  return text
end

local function load_manifest(env, path)
  local text = read_all(env, path)
  if not text then return nil end
  return (parse_table(text, path))
end

local function installed_info(env)
  local manifest = load_manifest(env, APP .. "/manifest.lua")
  local info
  if env.fs.exists(APP .. "/install.lua") then info = parse_table(read_all(env, APP .. "/install.lua") or "", "install") end
  return manifest, info
end

local function parse_args(args)
  local opts = { positional = {} }
  for _, a in ipairs(args) do
    if a:sub(1, 2) == "--" then opts[a:sub(3)] = true else opts.positional[#opts.positional + 1] = a end
  end
  return opts
end

local function install_info_text(role, ref, manifest)
  return string.format("return { role = %q, version = %q, id = %q, ref = %q }\n", role, manifest.version, manifest.id, ref)
end

local function handle_startup(env)
  local say = env.print
  local fs = env.fs
  if not fs.exists("/startup.lua") then
    write_all(env, "/startup.lua", MARK .. "\nshell.run(\"/crn/app/main.lua\")\n")
    say("startup.lua angelegt: CRN startet beim Einschalten.")
    return
  end
  local text = read_all(env, "/startup.lua") or ""
  if text:sub(1, #MARK) == MARK then return end
  say("Hinweis: /startup.lua gehoert zu einem anderen Programm und bleibt unveraendert.")
  say("CRN starten Sie von Hand mit: crn/app/main")
end

function M.status(env)
  local say = env.print
  local manifest, info = installed_info(env)
  if not manifest then
    say("CRN ist nicht installiert.")
    return false
  end
  say("Installiert: Version " .. tostring(manifest.version) .. ", Stand " .. tostring(manifest.id) .. ", Rolle " .. tostring(info and info.role or "unbekannt"))
  if info and info.ref then say("Herkunft: " .. info.ref) end
  local prev = load_manifest(env, PREV .. "/manifest.lua")
  if prev then say("Vorversion: " .. tostring(prev.version) .. " (Stand " .. tostring(prev.id) .. ")") end
  say("Frei: " .. env.fs.getFreeSpace("/") .. " Byte")
  return true
end

function M.check(env)
  local say = env.print
  local manifest, info = installed_info(env)
  if not manifest then
    say("CRN ist nicht installiert.")
    return false
  end
  local bad = 0
  for _, path in ipairs((info and manifest.roles[info.role]) or {}) do
    local want = manifest.files[path]
    local text = read_all(env, APP .. "/" .. path)
    if not text then
      say("fehlt: " .. path)
      bad = bad + 1
    elseif #text ~= want.size or adler_hex(text) ~= want.sum then
      say("beschaedigt: " .. path)
      bad = bad + 1
    end
  end
  if bad == 0 then say("Alle Dateien stimmen mit dem Verzeichnis ueberein.") else say(bad .. " Datei(en) fehlerhaft: bitte neu installieren.") end
  return bad == 0
end

function M.rollback(env)
  local say = env.print
  local fs = env.fs
  if not fs.exists(PREV) then
    say("Keine Vorversion vorhanden.")
    return false
  end
  fs.move(APP, TMP)
  fs.move(PREV, APP)
  fs.move(TMP, PREV)
  local manifest = load_manifest(env, APP .. "/manifest.lua")
  say("Zurueck bei Version " .. tostring(manifest and manifest.version) .. ".")
  return true
end

function M.install(env, opts)
  local say, fs = env.print, env.fs
  local role = opts.positional[1]
  local ref = opts.positional[2] or "main"
  local moving = not ref:match("^v?%d+%.%d+") and not ref:match("^%x%x%x%x%x%x%x+$")
  if moving and not opts.yes then
    say("Achtung: '" .. ref .. "' ist ein beweglicher Zweig. Besser eine feste Version angeben:")
    say("  installer " .. role .. " v0.1.0")
    say("Weiter mit der Eingabetaste, Abbruch mit Strg+T.")
    env.read()
  end
  if not env.http then
    say("HTTP ist auf diesem Computer nicht verfuegbar (Servereinstellung oder Modpack). Der Installer braucht es.")
    return false
  end
  local url = BASE .. ref .. "/dist/"
  local text = fetch(env, url .. "manifest.lua")
  if not text then
    say("Verzeichnis nicht erreichbar: " .. url .. "manifest.lua")
    say("Pruefen: Ist HTTP erlaubt? Gibt es die Version '" .. ref .. "'?")
    return false
  end
  local manifest, err = parse_table(text, "manifest")
  if not manifest or not manifest.files or not manifest.roles then
    say("Das Verzeichnis ist unbrauchbar: " .. tostring(err))
    return false
  end
  local paths = manifest.roles[role]
  if not paths then
    local names = {}
    for name in pairs(manifest.roles) do names[#names + 1] = name end
    table.sort(names)
    say("Unbekannte Rolle '" .. tostring(role) .. "'. Moeglich: " .. table.concat(names, ", "))
    return false
  end
  local need = MIN_FILE + math.max(#text, MIN_FILE) + MIN_FILE
  for _, path in ipairs(paths) do need = need + math.max(manifest.files[path].size, MIN_FILE) end
  if opts["drop-prev"] then drop(env, PREV) end
  local free = fs.getFreeSpace("/")
  if free < need + MARGIN then
    say("Zu wenig Platz: benoetigt " .. (need + MARGIN) .. " Byte, frei " .. free .. " Byte.")
    if fs.exists(PREV) then say("Mit 'installer --drop-prev " .. role .. "' wird die Vorversion geloescht.") end
    return false
  end
  say("Version " .. manifest.version .. " (Stand " .. manifest.id .. "), Rolle " .. role .. ", " .. #paths .. " Dateien, " .. need .. " Byte")
  drop(env, NEW)
  fs.makeDir(NEW)
  local function fail(message)
    drop(env, NEW)
    say(message)
    say("Es wurde nichts veraendert.")
    return false
  end
  local all = { "manifest.lua" }
  for _, path in ipairs(paths) do all[#all + 1] = path end
  for index, path in ipairs(all) do
    local body
    if path == "manifest.lua" then
      body = text
    else
      body = fetch(env, url .. path)
      if not body then return fail("Download fehlgeschlagen: " .. path) end
      local want = manifest.files[path]
      if #body ~= want.size or adler_hex(body) ~= want.sum then
        return fail("Datei passt nicht zum Verzeichnis: " .. path .. " (frisch veroeffentlichte Staende brauchen einige Minuten; spaeter wiederholen)")
      end
    end
    ensure_dir(env, NEW .. "/" .. path)
    if not write_all(env, NEW .. "/" .. path, body) then return fail("Schreiben fehlgeschlagen: " .. path) end
    if path ~= "manifest.lua" and read_all(env, NEW .. "/" .. path) ~= body then return fail("Pruefung nach dem Schreiben fehlgeschlagen: " .. path) end
    if index % 10 == 0 then say(index .. "/" .. #all) end
  end
  write_all(env, NEW .. "/install.lua", install_info_text(role, ref, manifest))
  write_all(env, NEW .. "/.complete", "ok\n")
  if not fs.exists(DATA) then fs.makeDir(DATA) end
  drop(env, PREV)
  if fs.exists(APP) then fs.move(APP, PREV) end
  fs.move(NEW, APP)
  handle_startup(env)
  say("Installiert: Version " .. manifest.version .. ". Start: crn/app/main")
  if fs.exists(PREV) then say("Die Vorversion bleibt erhalten (installer --rollback).") end
  return true
end

function M.run(args, env)
  local opts = parse_args(args)
  M.recover(env)
  if opts.rollback then return M.rollback(env) end
  if opts.status then return M.status(env) end
  if opts.check then return M.check(env) end
  if not opts.positional[1] then
    env.print("Aufruf: installer ROLLE [VERSION]   Rollen: zentrale, passagierbahnhof, gueterbahnhof, depot, signal, knoten, anmeldung")
    env.print("        installer --status | --check | --rollback")
    return false
  end
  return M.install(env, opts)
end

function M.real_env()
  return { fs = fs, http = http, print = print, read = read }
end

if rawget(_G, "__CRN_TEST") then return M end
M.run({ ... }, M.real_env())
