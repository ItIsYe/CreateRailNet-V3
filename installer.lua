--[[
Purpose: Installiert CRN per Download auf einen CC:Tweaked Computer: holt das Dateiverzeichnis einer festen Version, laedt nur die Dateien der gewaehlten Rolle, prueft Groesse und Pruefsumme jeder Datei und tauscht erst dann die Installation aus. Die Vorversion bleibt fuer die Rueckkehr erhalten.
Usage: installer                   Dialog: Schritt fuer Schritt auswaehlen (Menue, Version, Rolle, Zusammenfassung)
       installer ROLLE [REF]        ohne Dialog installieren oder aktualisieren (REF = Tag, Commit oder Zweig, Standard: main)
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

-- veroeffentlichte Versionen (Tags), neueste zuerst; ohne Antwort eine leere Liste (der Dialog funktioniert auch ohne)
function M.list_tags(env)
  if not env.http then return {} end
  local text = fetch(env, "https://api.github.com/repos/ItIsYe/CreateRailNet-V3/tags?per_page=8")
  local out = {}
  for name in (text or ""):gmatch('"name"%s*:%s*"([^"]+)"') do
    if valid_ref(name) then out[#out + 1] = name end
  end
  return out
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
  local ref = opts.positional[2] or "main"
  if not valid_ref(ref) then
    say("Ungueltige Version: '" .. tostring(ref) .. "' (erlaubt: Buchstaben, Ziffern, . _ - /)")
    return false
  end
  if is_moving(ref) and not opts.yes then
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
  local keys = {}
  for _, entry in ipairs(entries) do
    keys[entry.key] = true
    env.print(string.format(" %-2s %s%s", entry.key, entry.text, (default == entry.key) and "   <- Eingabetaste" or ""))
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
  if not env.fs.exists("/startup.lua") then return "wird angelegt (CRN startet beim Einschalten)" end
  local text = read_all(env, "/startup.lua") or ""
  if text:sub(1, #MARK) == MARK then return "bleibt (gehoert zu CRN)" end
  return "bleibt unveraendert (gehoert zu einem anderen Programm)"
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
      show(env, "titel", "CRN Installer")
      if manifest then
        say("Installiert: Version " .. tostring(manifest.version) .. ", Rolle " .. tostring(info and info.role or "unbekannt"))
      else
        say("Noch nichts installiert.")
      end
      say("Was moechten Sie tun?")
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
        step = "version"
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

    elseif step == "version" then
      say("Welche Version soll installiert werden?")
      if state.tags == nil then
        say("(veroeffentlichte Versionen werden gesucht ...)")
        state.tags = M.list_tags(env)
      end
      local entries, refs = {}, {}
      local last = info and info.ref
      local default
      if valid_ref(last) and last ~= "Rueckkehr" then
        entries[#entries + 1] = { key = "1", text = last .. " (zuletzt verwendet)" }
        refs["1"] = last
        default = "1"
      end
      for i, tag in ipairs(state.tags) do
        local key = tostring(#entries + 1)
        entries[#entries + 1] = { key = key, text = tag .. (i == 1 and " (neueste veroeffentlichte Version)" or "") }
        refs[key] = tag
        if not default and i == 1 then default = key end
      end
      entries[#entries + 1] = { key = "m", text = "main (beweglich: der Inhalt kann sich aendern)" }
      entries[#entries + 1] = { key = "e", text = "Version, Tag oder Commit eingeben" }
      entries[#entries + 1] = { key = "z", text = "Zurueck" }
      entries[#entries + 1] = { key = "q", text = "Abbrechen" }
      local key = choose(env, entries, default)
      if key == nil or key == "q" then return stop() end
      if key == "z" then
        step = "menu"
      else
        local ref = refs[key]
        if key == "m" then ref = "main" end
        if key == "e" then
          while not ref do
            say("Version eingeben (z = zurueck):")
            local typed = ask(env, true)
            if typed == nil then return stop() end
            if typed == "z" then break end
            if valid_ref(typed) then
              ref = typed
            else
              say("Ungueltig. Erlaubt sind Buchstaben, Ziffern, . _ - /")
            end
          end
        end
        if ref then
          if is_moving(ref) then say("Hinweis: '" .. ref .. "' ist ein beweglicher Zweig; der Inhalt kann sich zwischen zwei Aufrufen aendern.") end
          say("Verzeichnis wird geladen ...")
          local source, err = M.get_manifest(env, ref)
          if source then
            state.source = source
            step = "role"
          else
            say(err)
            state.keep = true
          end
        else
          state.keep = true
        end
      end

    elseif step == "role" then
      local source = state.source
      say("Welche Rolle hat dieser Computer?")
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
        step = "version"
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
        show(env, "titel", "Zusammenfassung")
        say("  Rolle:    " .. state.role)
        say("  Version:  " .. m.version .. " (Stand " .. m.id .. ") von " .. state.source.ref)
        say("  Dateien:  " .. #plan.paths .. ", " .. size_text(plan.need) .. " (frei " .. size_text(plan.free) .. (plan.short and "" or (", danach etwa " .. size_text(plan.free - plan.need))) .. ")")
        if manifest then
          say("  Bisher:   Version " .. tostring(manifest.version) .. " wird zur Vorversion")
          if info and info.role and info.role ~= state.role then
            say("  Achtung:  die Rolle wechselt von " .. info.role .. " zu " .. state.role)
          end
        else
          say("  Bisher:   neue Installation")
        end
        say("  startup:  " .. startup_text(env))
        say("  Daten:    /crn_data bleibt unberuehrt")
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
  "  installer ROLLE [VERSION]       ohne Dialog (VERSION = Tag, Commit oder Zweig; Standard main)",
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

function M.real_env()
  local palette = rawget(_G, "colors") or {}
  local colors = { titel = palette.yellow, ok = palette.lime, fehler = palette.red }
  local bar_width = 20
  return {
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
M.run({ ... }, M.real_env())
