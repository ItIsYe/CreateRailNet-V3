--[[
Purpose: Installiert CRN per Download auf einen CC:Tweaked Computer: holt das Dateiverzeichnis der Version seines Kanals (main oder beta), laedt nur die Dateien der gewaehlten Rolle, prueft Groesse und Pruefsumme jeder Datei und tauscht erst dann die Installation aus. Die Vorversion bleibt fuer die Rueckkehr erhalten.
Usage: installer                   Dialog: Schritt fuer Schritt auswaehlen (Menue, Rolle, Zusammenfassung); die Version ist der Kanal dieser Datei
       installer ROLLE [REF]        ohne Dialog installieren oder aktualisieren (REF = Tag, Commit oder Zweig, Standard: der Kanal dieser Datei)
       installer --rollback        zur Vorversion zurueckkehren
       installer --status          installierte Version zeigen
       installer --check           installierte Dateien gegen das Verzeichnis pruefen
       Zusatz: --yes (keine Rueckfrage), --drop-prev (Vorversion loeschen, wenn der Platz knapp ist)
Notes: Der Kanal (main oder beta) steht in dieser Datei: wer sie von main laedt, installiert main, wer installer_beta.lua von beta laedt, installiert beta. installer_beta.lua wird von tools/build.lua aus dieser Datei erzeugt. Eine einzelne Datei ohne Abhaengigkeit zur Anwendung. Daten liegen getrennt in /crn_data und werden nie angefasst; Rolle und Herkunft stehen in /crn/install.lua, damit sie mit der Installation zusammen ausgetauscht werden. Bei jedem Abbruch bleibt entweder die alte oder die neue Installation vollstaendig; der naechste Start raeumt auf (recover).
]]

local M = {}

local CHANNEL = "beta"    -- KANAL: tools/build.lua erzeugt daraus installer_beta.lua (nur diese Zeile unterscheidet sich)
local CHANNEL_TEXT = { main = "stabil", beta = "Test" }
M.CHANNEL = CHANNEL

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

-- Groessen lesbar: 332605 -> "325 KB"
local function size_text(n)
  if n >= 10240 then return string.format("%d KB", math.floor(n / 1024 + 0.5)) end
  if n >= 1024 then return string.format("%.1f KB", n / 1024) end
  return n .. " Byte"
end
M.size_text = size_text

-- farbige Zeile, wenn der Computer Farben kann (env.paint(art, text)); sonst schlicht
local function show(env, kind, text)
  if env.paint then env.paint(kind, text) else env.print(text) end
end

-- mehrfarbige Zeile aus Teilen { art, text }; ohne Farbfaehigkeit schlicht zusammengesetzt
local WIDTH = 51
local function line(env, parts)
  if env.paintline then return env.paintline(parts) end
  local text = {}
  for _, part in ipairs(parts) do text[#text + 1] = part[2] end
  env.print(table.concat(text))
end

-- Kopf: farbiger Balken mit Name und Schritt, darunter die Frage
local function header(env, title, step, total)
  if env.set_stage then env.set_stage(step or 1) end
  local right = step and ("Schritt " .. step .. " von " .. total) or ""
  local left = " CRN Installer"
  local gap = WIDTH - #left - #right - (right ~= "" and 1 or 0)
  line(env, { { "balken", left .. string.rep(" ", math.max(1, gap)) .. right .. (right ~= "" and " " or "") } })
  if title then line(env, { { "titel", " " .. title } }) end
end

local function kv(env, label, value, kind)
  line(env, { { "dim", "  " .. label }, { kind or "text", value } })
end

local function rule(env) line(env, { { "dim", " " .. string.rep("-", WIDTH - 2) } }) end

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

local ROLE_ORDER = { "zentrale", "passagierbahnhof", "gueterbahnhof", "depot", "signal", "knoten", "anmeldung" }
local ROLE_TEXT = {
  zentrale = "Leitstelle fuer das ganze Netz",
  passagierbahnhof = "Bahnhof fuer Fahrgaeste",
  gueterbahnhof = "Bahnhof fuer Fracht",
  depot = "Abstellen und Uebergabe von Zuegen",
  signal = "Signale und Strecken",
  knoten = "Abzweige und Kreuzungen",
  anmeldung = "Zuganmeldung und Bedarfstasten",
}

local function valid_ref(ref)
  return type(ref) == "string" and #ref > 0 and #ref <= 100 and ref:match("^[%w%._/%-]+$") ~= nil and not ref:find("..", 1, true)
end

local function is_moving(ref)
  return not ref:match("^v?%d+%.%d+") and not ref:match("^%x%x%x%x%x%x%x+$")
end

-- holt das Dateiverzeichnis einer Version; liefert { manifest, text, url, ref } oder nil und den Fehlertext
function M.get_manifest(env, ref)
  if not env.http then
    return nil, "HTTP ist auf diesem Computer nicht verfuegbar (Servereinstellung oder Modpack). Der Installer braucht es."
  end
  local url = BASE .. ref .. "/dist/"
  local text = fetch(env, url .. "manifest.lua")
  if not text then
    return nil, "Verzeichnis nicht erreichbar: " .. url .. "manifest.lua\nPruefen: Ist HTTP erlaubt? Gibt es die Version '" .. ref .. "'?"
  end
  local manifest, err = parse_table(text, "manifest")
  if not manifest or type(manifest.files) ~= "table" or type(manifest.roles) ~= "table" then
    return nil, "Das Verzeichnis ist unbrauchbar: " .. tostring(err)
  end
  return { manifest = manifest, text = text, url = url, ref = ref }
end

-- berechnet, was eine Installation der Rolle braucht; liefert den Plan oder nil und den Fehlertext
function M.plan(env, source, role)
  local manifest = source.manifest
  local paths = manifest.roles[role]
  if not paths then
    local names = {}
    for name in pairs(manifest.roles) do names[#names + 1] = name end
    table.sort(names)
    return nil, "Unbekannte Rolle '" .. tostring(role) .. "'. Moeglich: " .. table.concat(names, ", ")
  end
  local need = MIN_FILE + math.max(#source.text, MIN_FILE) + MIN_FILE
  for _, path in ipairs(paths) do need = need + math.max(manifest.files[path].size, MIN_FILE) end
  local free = env.fs.getFreeSpace("/")
  return { source = source, role = role, paths = paths, need = need, free = free, short = free < need + MARGIN }
end

-- laedt, prueft und tauscht aus; bei jedem Fehler bleibt alles wie es war
function M.apply(env, plan)
  local say, fs = env.print, env.fs
  local source, role, paths = plan.source, plan.role, plan.paths
  local manifest, url = source.manifest, source.url
  say("Version " .. manifest.version .. " (Stand " .. manifest.id .. "), Rolle " .. role .. ", " .. #paths .. " Dateien, " .. size_text(plan.need))
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
      body = source.text
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
    if env.progress then env.progress(index, #all) elseif index % 10 == 0 then say(index .. "/" .. #all) end
  end
  write_all(env, NEW .. "/install.lua", install_info_text(role, source.ref, manifest))
  write_all(env, NEW .. "/.complete", "ok\n")
  if not fs.exists(DATA) then fs.makeDir(DATA) end
  drop(env, PREV)
  if fs.exists(APP) then fs.move(APP, PREV) end
  fs.move(NEW, APP)
  handle_startup(env)
  if env.progress_done then env.progress_done() end
  show(env, "ok", "Installiert: Version " .. manifest.version .. ", Rolle " .. role .. ". Start: crn/app/main")
  if fs.exists(PREV) then say("Die Vorversion bleibt erhalten (installer --rollback).") end
  say("Naechste Schritte: starten, dann auf der Seite 'Einrichtung' den Assistenten durchlaufen.")
  return true
end

function M.install(env, opts)
  local say, fs = env.print, env.fs
  local role = opts.positional[1]
  local ref = opts.positional[2] or CHANNEL
  if not valid_ref(ref) then
    say("Ungueltige Version: '" .. tostring(ref) .. "' (erlaubt: Buchstaben, Ziffern, . _ - /)")
    return false
  end
  if is_moving(ref) and ref ~= CHANNEL and not opts.yes then
    say("Achtung: '" .. ref .. "' ist ein beweglicher Zweig. Besser eine feste Version angeben:")
    say("  installer " .. role .. " v0.1.0")
    say("Weiter mit der Eingabetaste, Abbruch mit Strg+T.")
    env.read()
  end
  local source, err = M.get_manifest(env, ref)
  if not source then
    say(err)
    return false
  end
  if opts["drop-prev"] then drop(env, PREV) end
  local plan, perr = M.plan(env, source, role)
  if not plan then
    say(perr)
    return false
  end
  if plan.short then
    say("Zu wenig Platz: benoetigt " .. (plan.need + MARGIN) .. " Byte, frei " .. plan.free .. " Byte.")
    if fs.exists(PREV) then say("Mit 'installer --drop-prev " .. role .. "' wird die Vorversion geloescht.") end
    return false
  end
  return M.apply(env, plan)
end

-- Dialog: Schritt fuer Schritt auswaehlen; z geht zurueck, q bricht ab, vor dem Installieren steht eine Zusammenfassung
local function clear_screen(env)
  if env.clear then env.clear() end
end

local function ask(env, keep_case)
  if env.write then env.write("> ") end
  local answer = env.read()
  if answer == nil then return nil end
  answer = tostring(answer):gsub("^%s+", ""):gsub("%s+$", "")
  if keep_case then return answer end
  return answer:lower()
end

-- zeigt Eintraege { key, text } und liefert den gewaehlten Schluessel; nil bei Eingabeende
local function choose(env, entries, default)
  if env.choose then return env.choose(entries, default) end
  local keys = {}
  for _, entry in ipairs(entries) do
    keys[entry.key] = true
    line(env, {
      { "text", " " }, { "taste", string.format("[%s]", entry.key) }, { "text", string.rep(" ", 4 - #entry.key - 2) .. entry.text },
      { "dim", (default == entry.key) and "  <- Enter" or "" },
    })
  end
  while true do
    local answer = ask(env)
    if answer == nil then return nil end
    if answer == "" and default then return default end
    if keys[answer] then return answer end
    env.print("Bitte eine der angegebenen Eingaben waehlen" .. (default and " (oder die Eingabetaste fuer die Vorgabe)." or "."))
  end
end

local function pause(env)
  env.print("Weiter mit der Eingabetaste.")
  return env.read() ~= nil
end

local function startup_text(env)
  if not env.fs.exists("/startup.lua") then return "wird angelegt (Start beim Einschalten)" end
  local text = read_all(env, "/startup.lua") or ""
  if text:sub(1, #MARK) == MARK then return "bleibt (gehoert zu CRN)" end
  return "bleibt unveraendert (anderes Programm)"
end

function M.wizard(env)
  local say, fs = env.print, env.fs
  local step = "menu"
  local state = {}
  local function stop()
    say("Beendet. Es wurde nichts veraendert.")
    return false
  end
  while true do
    local manifest, info = installed_info(env)
    local has_prev = fs.exists(PREV .. "/manifest.lua")
    if state.keep then state.keep = nil else clear_screen(env) end

    if step == "menu" then
      header(env, nil)
      if manifest then
        say("Installiert: Version " .. tostring(manifest.version) .. ", Rolle " .. tostring(info and info.role or "unbekannt"))
      else
        say("Noch nichts installiert.")
      end
      say("Kanal: " .. CHANNEL .. " (" .. (CHANNEL_TEXT[CHANNEL] or "eigener Zweig") .. ")")
      rule(env)
      line(env, { { "titel", " Was moechten Sie tun?" } })
      local entries, actions = {}, {}
      local function add(action, text)
        local key = tostring(#entries + 1)
        entries[#entries + 1] = { key = key, text = text }
        actions[key] = action
      end
      add("install", manifest and "Aktualisieren oder neu installieren" or "Installieren")
      if manifest then add("check", "Installation pruefen") end
      if has_prev then add("rollback", "Zur Vorversion zurueckkehren") end
      entries[#entries + 1] = { key = "q", text = "Beenden" }
      local key = choose(env, entries, "1")
      if key == nil or key == "q" then return stop() end
      local action = actions[key]
      if action == "install" then
        say("Verzeichnis wird geladen ...")
        local source, err = M.get_manifest(env, CHANNEL)
        if source then
          state.source = source
          step = "role"
        else
          say(err)
          state.keep = true
        end
      elseif action == "check" then
        M.check(env)
        if not pause(env) then return stop() end
      elseif action == "rollback" then
        say("Wirklich zur Vorversion zurueckkehren?")
        local yes = choose(env, { { key = "j", text = "Ja, zurueckkehren" }, { key = "n", text = "Nein" } })
        if yes == nil then return stop() end
        if yes == "j" then M.rollback(env) end
        if not pause(env) then return stop() end
      end

    elseif step == "role" then
      local source = state.source
      header(env, "Welche Rolle hat dieser Computer?", 1, 2)
      rule(env)
      local entries, roles = {}, {}
      local shown = {}
      local function add(role)
        local key = tostring(#entries + 1)
        local text = string.format("%-17s %s", role, ROLE_TEXT[role] or "")
        if info and info.role == role then text = text .. " (bisher)" end
        entries[#entries + 1] = { key = key, text = text }
        roles[key] = role
        shown[role] = true
      end
      for _, role in ipairs(ROLE_ORDER) do if source.manifest.roles[role] then add(role) end end
      local extra = {}
      for role in pairs(source.manifest.roles) do if not shown[role] then extra[#extra + 1] = role end end
      table.sort(extra)
      for _, role in ipairs(extra) do add(role) end
      entries[#entries + 1] = { key = "z", text = "Zurueck" }
      entries[#entries + 1] = { key = "q", text = "Abbrechen" }
      local default
      for key, role in pairs(roles) do if info and info.role == role then default = key end end
      local key = choose(env, entries, default)
      if key == nil or key == "q" then return stop() end
      if key == "z" then
        step = "menu"
      else
        state.role = roles[key]
        step = "summary"
      end

    elseif step == "summary" then
      local plan, perr = M.plan(env, state.source, state.role)
      if not plan then
        say(perr)
        step = "role"
        state.keep = true
      else
        local m = state.source.manifest
        header(env, "Zusammenfassung", 2, 2)
        rule(env)
        kv(env, "Rolle:    ", state.role)
        kv(env, "Kanal:    ", state.source.ref .. " (" .. (CHANNEL_TEXT[state.source.ref] or "eigener Zweig") .. ")")
        kv(env, "Version:  ", m.version .. " (Stand " .. m.id .. ")")
        kv(env, "Dateien:  ", #plan.paths .. ", " .. size_text(plan.need))
        kv(env, "Frei:     ", size_text(plan.free) .. (plan.short and "" or (", danach etwa " .. size_text(plan.free - plan.need))), plan.short and "fehler" or "text")
        if manifest then
          kv(env, "Bisher:   ", "Version " .. tostring(manifest.version) .. " wird zur Vorversion")
          if info and info.role and info.role ~= state.role then
            kv(env, "Achtung:  ", "die Rolle wechselt von " .. info.role .. " zu " .. state.role, "fehler")
          end
        else
          kv(env, "Bisher:   ", "neue Installation")
        end
        kv(env, "startup:  ", startup_text(env))
        kv(env, "Daten:    ", "/crn_data bleibt unberuehrt")
        local entries
        if plan.short then
          show(env, "fehler", "Zu wenig Platz: benoetigt " .. size_text(plan.need + MARGIN) .. ", frei " .. size_text(plan.free) .. ".")
          entries = {}
          if has_prev then entries[#entries + 1] = { key = "d", text = "Vorversion loeschen und Platz schaffen" } end
        else
          entries = { { key = "j", text = "Jetzt installieren" } }
        end
        entries[#entries + 1] = { key = "z", text = "Zurueck" }
        entries[#entries + 1] = { key = "q", text = "Abbrechen" }
        local key = choose(env, entries)
        if key == nil or key == "q" then return stop() end
        if key == "z" then
          step = "role"
        elseif key == "d" then
          drop(env, PREV)
          state.keep = true
        elseif key == "j" then
          local ok = M.apply(env, plan)
          if ok then
            say("Jetzt starten?")
            local go = choose(env, { { key = "j", text = "Ja" }, { key = "n", text = "Nein" } }, "j")
            if go == "j" and env.start then env.start() end
          else
            pause(env)
          end
          return ok
        end
      end
    end
  end
end

local USAGE = {
  "Aufruf:",
  "  installer                       Dialog: alles nach und nach auswaehlen",
  "  installer ROLLE [VERSION]       ohne Dialog (VERSION = Tag, Commit oder Zweig; Standard: Kanal dieser Datei)",
  "  installer --status | --check | --rollback",
  "  Zusatz: --yes (keine Rueckfrage), --drop-prev (Vorversion loeschen, wenn der Platz knapp ist)",
  "  Rollen: zentrale, passagierbahnhof, gueterbahnhof, depot, signal, knoten, anmeldung",
}

function M.run(args, env)
  local opts = parse_args(args)
  M.recover(env)
  if opts.help then
    for _, line in ipairs(USAGE) do env.print(line) end
    return true
  end
  if opts.rollback then return M.rollback(env) end
  if opts.status then return M.status(env) end
  if opts.check then return M.check(env) end
  if not opts.positional[1] then return M.wizard(env) end
  return M.install(env, opts)
end

-- Eigenstaendiger Renderer: der Installer darf keine noch nicht installierten Module laden.
-- Auswahl per Tastatur/Maus; lange Inhalte und Listen bleiben seitenweise erreichbar.
function M.dialog_env(env, target, pull)
  local out = {}
  for k,v in pairs(env) do out[k]=v end
  local lines, areas, selected, offset = {}, {}, 1, 0
  local stage = 1
  out.set_stage = function(value) stage=value end
  local width,height = target.getSize()
  local colour = (target.isColour or target.isColor or function() return false end)()
  local C={bg=32768,panel=128,text=1,dim=256,blue=2048,cyan=512,green=8192,amber=16}
  local saved_palette, restored = {}, false
  if colour and target.setPaletteColour then
    for c in pairs({[32768]=1,[128]=1,[1]=1,[256]=1,[2048]=1,[512]=1,[8192]=1,[16]=1}) do
      if target.getPaletteColour then local r,g,b=target.getPaletteColour(c); saved_palette[c]={r,g,b} end
    end
    for c,rgb in pairs({[32768]=0x101820,[128]=0x21313F,[1]=0xF2F6F8,[256]=0x8397A8,[2048]=0x397CC0,[512]=0x63C6CC,[8192]=0x8DD1A0,[16]=0xE7B66A}) do target.setPaletteColour(c,rgb) end
  end
  local function text(x,y,value,fg,bg,w)
    if y<1 or y>height then return end
    value=tostring(value):sub(1,w or width-x+1)
    target.setCursorPos(x,y)
    target.setTextColour(colour and (fg or C.text) or 1)
    target.setBackgroundColour(colour and (bg or C.bg) or 32768)
    target.write(value)
  end
  local function fill(x,y,w,h,bg)
    for row=y,y+h-1 do text(x,row,string.rep(' ',math.max(0,w)),C.text,bg,w) end
  end
  local function append(value,kind)
    lines[#lines+1]={text=tostring(value or ''),kind=kind}
  end
  local function render(entries)
    width,height=target.getSize()
    local large=width>=100 and height>=40
    local left=large and 23 or 2
    local content_w=width-left-1
    fill(1,1,width,height,C.bg)
    fill(1,1,width,large and 3 or 1,C.panel)
    text(2,large and 2 or 1,'CREATERAILNET / INSTALLATION',C.text,C.panel)
    if large then
      fill(1,5,20,height-5,C.panel)
      for i,label in ipairs({'Rolle waehlen','Pruefen','Installieren','Einrichten'}) do
        local y=5+(i-1)*4
        fill(1,y,20,3,i==stage and C.blue or C.panel)
        text(2,y+1,i..' '..label,i==stage and C.text or C.dim,i==stage and C.blue or C.panel,18)
      end
    end
    local top=large and 5 or 3
    local row_h=large and 3 or 1             -- kompakt: eine Zeile je Eintrag, damit der Text darueber Platz behaelt
    local entry_h=large and row_h-1 or 1
    local visible=math.min(#(entries or {}),large and 7 or 5)
    local choices_y=height-visible*row_h-1
    local bottom=entries and choices_y-2 or height-3
    local wrapped={}
    for _,line in ipairs(lines) do
      local value=line.text
      if not value:match('^%s*%-+$') and not value:find('CRN Installer',1,true) then
        repeat
          local cut=math.min(#value,content_w)
          if #value>content_w then
            local space=value:sub(1,content_w):match('^.*() ')
            if space and space>content_w/2 then cut=space end
          end
          wrapped[#wrapped+1]={text=value:sub(1,cut),kind=line.kind}
          value=value:sub(cut+1)
        until value==''
      end
    end
    local maxoff=math.max(0,#wrapped-(bottom-top+1))
    offset=math.max(0,math.min(offset,maxoff))
    for row=top,bottom do
      local line=wrapped[offset+row-top+1]
      if line then text(left,row,line.text,line.kind=='ok' and C.green or line.kind=='fehler' and C.amber or line.kind=='dim' and C.dim or C.text,C.bg,content_w) end
    end
    areas={}
    if entries then
      local first=math.max(1,selected-visible+1)
      for i=first,math.min(#entries,first+visible-1) do
        local y=choices_y+(i-first)*row_h
        local bg=i==selected and C.blue or C.panel
        fill(left,y,content_w,entry_h,bg)
        text(left+1,y,'['..entries[i].key..'] '..entries[i].text,C.text,bg,content_w-2)
        areas[#areas+1]={index=i,x=left,y=y,w=content_w,h=entry_h}
      end
    end
    text(2,height,'Pfeile: Auswahl | Enter: OK | Bild auf/ab: Text',C.dim,C.bg,width-2)
    if maxoff>0 then text(width-16,2,'Text '..(offset+1)..'/'..#wrapped,C.amber,C.bg,16) end
    out.ui_state={areas=areas,lines=wrapped,offset=offset,selected=selected}
  end
  out.clear=function() lines={}; offset=0; render() end
  out.print=function(value) append(value); render() end
  out.paint=function(kind,value) append(value,kind); render() end
  out.paintline=function(parts)
    local list={};for _,part in ipairs(parts) do list[#list+1]=part[2] end
    append(table.concat(list),parts[1] and parts[1][1]); render()
  end
  out.write=function() end
  out.read=function()
    render()
    fill(1,height-1,width,1,C.panel);text(2,height-1,'> ',C.text,C.panel)
    return env.read()
  end
  out.choose=function(entries,default)
    selected=1
    for i,e in ipairs(entries) do if e.key==default then selected=i end end
    while true do
      render(entries)
      local e={pull()}
      if e[1]=='char' then
        for _,entry in ipairs(entries) do if e[2]:lower()==entry.key then return entry.key end end
      elseif e[1]=='key' then
        if e[2]==265 then selected=math.max(1,selected-1)
        elseif e[2]==264 then selected=math.min(#entries,selected+1)
        elseif e[2]==257 then return entries[selected].key
        elseif e[2]==266 then offset=math.max(0,offset-5)
        elseif e[2]==267 then offset=offset+5 end
      elseif e[1]=='mouse_scroll' then selected=math.max(1,math.min(#entries,selected+e[2]))
      elseif e[1]=='mouse_click' then
        for _,a in ipairs(areas) do if e[3]>=a.x and e[3]<a.x+a.w and e[4]>=a.y and e[4]<a.y+a.h then return entries[a.index].key end end
      end
    end
  end
  out.progress=function(done,total)
    stage=3
    render()
    local w=math.max(1,width-4);local n=math.floor(w*done/math.max(1,total))
    fill(2,height-2,w,1,C.panel);fill(2,height-2,n,1,C.blue)
    text(2,height-1,'Dateien geprueft: '..done..' / '..total,C.text,C.bg)
  end
  out.progress_done=function() stage=4; append('Dateien vollstaendig geprueft.','ok');render() end
  -- Terminal zurueckgeben: Farben wie vorher, Bildschirm leer, der Verlauf bleibt als normaler Text stehen
  out.restore=function()
    if restored then return end
    restored=true
    if colour and target.setPaletteColour then
      for c,rgb in pairs(saved_palette) do if rgb[1] then target.setPaletteColour(c,rgb[1],rgb[2],rgb[3]) end end
    end
    target.setBackgroundColour(32768); target.setTextColour(1)
    target.clear(); target.setCursorPos(1,1)
    local keep={}
    for _,line in ipairs(lines) do
      if not line.text:match('^%s*%-+$') and not line.text:find('CRN Installer',1,true) then keep[#keep+1]=line.text end
    end
    for i=math.max(1,#keep-(height-3)),#keep do env.print(keep[i]) end
  end
  if env.start then out.start=function(...) out.restore(); return env.start(...) end end
  return out
end

function M.real_env()
  local palette = rawget(_G, "colors") or {}
  local look_of = {
    balken = { palette.white, palette.blue }, titel = { palette.yellow, palette.black }, taste = { palette.cyan, palette.black },
    dim = { palette.lightGray, palette.black }, ok = { palette.lime, palette.black }, fehler = { palette.red, palette.black }, text = { palette.white, palette.black },
  }
  local colors = { titel = palette.yellow, ok = palette.lime, fehler = palette.red }
  local bar_width = 20
  return {
    paintline = function(parts)
      local color = term.isColor and term.isColor()
      for _, part in ipairs(parts) do
        local look = look_of[part[1]]
        if color and look then term.setTextColour(look[1]) term.setBackgroundColour(look[2]) end
        write(part[2])
        if color then term.setTextColour(palette.white or 1) term.setBackgroundColour(palette.black or 32768) end
      end
      print()
    end,
    paint = function(kind, text)
      local c = term.isColor and term.isColor() and colors[kind]
      if c then term.setTextColour(c) end
      print(text)
      if c then term.setTextColour(palette.white or 1) end
    end,
    -- Fortschrittsbalken in einer Zeile
    progress = function(done, total)
      local _, y = term.getCursorPos()
      local filled = math.floor(bar_width * done / total)
      term.setCursorPos(1, y)
      term.clearLine()
      write("[" .. string.rep("#", filled) .. string.rep(".", bar_width - filled) .. "] " .. done .. "/" .. total)
    end,
    progress_done = function() print() end,
    fs = fs, http = http, print = print, read = read, write = write,
    clear = function() term.clear(); term.setCursorPos(1, 1) end,
    start = function() shell.run("/crn/app/main.lua") end,
  }
end

if rawget(_G, "__CRN_TEST") then return M end
local args = { ... }
local env = M.real_env()
if #args == 0 then env = M.dialog_env(env, term, os.pullEvent) end
local ok, err = pcall(M.run, args, env)
if env.restore then env.restore() end
if not ok then error(err, 0) end
