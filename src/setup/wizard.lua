--[[
Purpose: The first-time setup of a computer: role, network plan, name, hardware, summary, then startup.lua (and the plan when needed).
Public API: run(opts) -> result { ok, aborted, role, id, config, written, rebooted, error }
  opts: args (argv list, "--role <role>" skips the role question), env { print, write, read, term, colors, fs, peripheral, os, link }
        env.link(opts) -> { state, detail } asks the master whether it knows this computer (src/setup/link.lua); without it nothing is asked
        env.fetch(opts) -> result fetches the plan from the master (src/setup/plan_fetch.lua); without it the plan cannot be fetched
        env.sleep(seconds), env.redstone: for the function test (CC sleep and redstone api)
        env.host (the CC version string, _HOST): for the diagnostic file
  check(path, env) -> { ok, path }          prints whether a network plan is valid (scripts/setup.lua --check [file])
  doctor(env) -> { ok, report }             prints what is wrong with this computer and what to do (scripts/setup.lua --doctor)
  fetch_plan(env) -> { ok, state, wrote }   fetches the plan from the master for a station / depot computer (scripts/setup.lua --fetch-plan)
  functest(env) -> { ok, state, result }    the guided function test (scripts/setup.lua --test): reads freely, switches only after a yes;
                                            state: passed / incomplete (a step got no yes) / failed / declined / setup (computer not set up)
    linktest(env) -> { ok, state, result }    how good the link to the master is (scripts/setup.lua --linktest): answers, time, largest message
  layout(env, path) -> { ok, state, wrote_plan, wrote_list }   builds the plan of a whole network from a description (scripts/setup.lua --layout [file]), on the master
  export(env) -> { ok, path }               writes crn_diag.txt: version, doctor result, own entry, devices, files, free space (scripts/setup.lua --export)
  ROLES -> list of { key, label, text }       parse_args(argv) -> { role, check, check_path, doctor, fetch_plan, functest, linktest, export, layout, layout_path }
Flow: Rolle > Netzplan > Name > Hardware > Pruefen. One question per page, every page fits 51 x 19, the header shows where you are. A step that
  has nothing to ask is left out (an example plan already says everything about this computer). "?" explains the question, "<" goes back.
  Nothing is written before the summary is confirmed.
Files: configs/network.json is the plan of this computer. Master: kept, copied from an example, or empty. Other computers: kept, a short plan
  (this computer and the master, valid on its own), or an example/own file used in place. startup.lua is rendered by src/shared/startup_template.lua.
Notes: ASCII only (CC:Tweaked draws bytes, not UTF-8); all text German. Written files go through src/shared/safe_write.lua (read back, old copy as .prev).
]]

local terminal = require("src.setup.terminal")
local hardware = require("src.setup.hardware")
local netplan = require("src.setup.netplan")
local startup_template = require("src.shared.startup_template")
local safe_write = require("src.shared.safe_write")
local doctor = require("src.setup.doctor")
local setup_status = require("src.shared.setup_status")
local functest = require("src.setup.functest")
local linktest = require("src.setup.linktest")
local export = require("src.setup.export")

local wizard = {}

wizard.ROLES = {
  { key = "master",  label = "Master",  text = "Zentrale Steuerung (nur einer)" },
  { key = "signal",  label = "Signal",  text = "steuert ein Signal" },
  { key = "sensor",  label = "Melder",  text = "meldet Zuege (Train Observer)" },
  { key = "switch",  label = "Weiche",  text = "stellt eine Weiche (Redstone)" },
  { key = "station", label = "Bahnhof", text = "gehoert zu einem Create-Bahnhof" },
  { key = "depot",   label = "Depot",   text = "Abstellbereich / Depot" },
  { key = "train",   label = "Zug",     text = "Bordcomputer im Zug" },
  { key = "panel",   label = "Monitor", text = "Bedien-Monitor (Panel)" },
  { key = "arbiter", label = "Schiedsrichter", text = "dritte Stimme der Masterwahl" },
}

local BACK = {}
local SKIP = {}
local ABORT = {}

local STEP_NAMES = { role = "Rolle", plan = "Netzplan", identity = "Name", hardware = "Hardware", summary = "Pruefen" }

local function role_info(key)
  for _, role in ipairs(wizard.ROLES) do if role.key == key then return role end end
  return nil
end

local function role_label(key)
  local info = role_info(key)
  return info and info.label or tostring(key)
end

local function side_word(key)
  for _, side in ipairs(hardware.SIDES) do if side.key == key then return side.label end end
  return tostring(key)
end

-- ── the disk ──────────────────────────────────────────────────────────────────────────────────────────────────────

local function make_files(fs_api)
  local files = {}
  function files.exists(path) return fs_api.exists(path) end
  function files.read(path)
    if not fs_api.exists(path) then return nil end
    local fh = fs_api.open(path, "r")
    if not fh then return nil end
    local body = fh.readAll()
    fh.close()
    return body
  end
  function files.write(path, body) return safe_write.write(path, body, { fs = fs_api }) end
  function files.list(dir)
    if not (fs_api.list and fs_api.exists(dir)) then return {} end
    local ok, names = pcall(fs_api.list, dir)
    if not ok or type(names) ~= "table" then return {} end
    table.sort(names)
    return names
  end
  return files
end

function wizard.parse_args(argv)
  local args = {}
  local i = 1
  while argv and i <= #argv do
    if argv[i] == "--role" then
      args.role = argv[i + 1]
      i = i + 2
    elseif argv[i] == "--doctor" then
      args.doctor = true
      i = i + 1
    elseif argv[i] == "--fetch-plan" then
      args.fetch_plan = true
      i = i + 1
    elseif argv[i] == "--test" then
      args.functest = true
      i = i + 1
    elseif argv[i] == "--linktest" then
      args.linktest = true
      i = i + 1
    elseif argv[i] == "--export" then
      args.export = true
      i = i + 1
    elseif argv[i] == "--layout" then
      args.layout = true
      local path = argv[i + 1]
      if path and path:sub(1, 2) ~= "--" then args.layout_path = path; i = i + 2 else i = i + 1 end
    elseif argv[i] == "--check" then
      args.check = true
      local path = argv[i + 1]
      if path and path:sub(1, 2) ~= "--" then args.check_path = path; i = i + 2 else i = i + 1 end
    else
      i = i + 1
    end
  end
  return args
end

-- scripts/setup.lua --check [file]: is this network plan valid? (the master refuses to start with an invalid one)
function wizard.check(path, env)
  local t = terminal.new(env)
  local files = make_files(env.fs)
  path = path or netplan.PATH
  local text = files.read(path)
  if not text then
    t.say(path .. ": Diese Datei gibt es nicht.", "err")
    return { ok = false, path = path }
  end
  local cfg, errors, fatal = netplan.parse(text)
  if not cfg then
    t.say(path .. ": " .. tostring(fatal), "err")
    return { ok = false, path = path }
  end
  if errors then
    t.say(path .. ": " .. #errors .. " Fehler:", "err")
    for i = 1, math.min(10, #errors) do t.say("- " .. netplan.explain(errors[i], cfg)) end
    if #errors > 10 then t.say("... und " .. (#errors - 10) .. " weitere.", "dim") end
    return { ok = false, path = path, errors = errors }
  end
  t.say(path .. ": in Ordnung (" .. netplan.text(netplan.summary(cfg)) .. ").", "ok")
  return { ok = true, path = path }
end

local STATION_TYPES = {
  { value = "passenger", label = "Personenverkehr" }, { value = "freight", label = "Fracht" }, { value = "mixed", label = "gemischt" },
}
local DEPOT_TYPES = {
  { value = "storage", label = "Abstellen", desc = "Zuege stehen dauerhaft" },
  { value = "staging", label = "Bereitstellen", desc = "Zuege warten auf ihren Einsatz" },
  { value = "mixed", label = "gemischt" },
}
local POSITIONS = {
  { value = "DIVERGING", label = "Abzweig" }, { value = "STRAIGHT", label = "geradeaus" },
}

-- the German word for a value the plan stores in English (the questions and the summary use the same words)
local function label_of(list, value)
  for _, item in ipairs(list) do if item.value == value then return item.label end end
  return tostring(value)
end

-- what the doctor asks when it wants to know whether the master knows this computer (nil: no way to ask)
local function probe_function(env)
  if not env.link then return nil end
  return function(ctx)
    return env.link({
      channel = ctx.cfg.channel, master_id = ctx.cfg.master_id, id = ctx.id, role = ctx.role, entry = ctx.entry,
      setup = { state = "KONFIGURIERT" }, modem_name = ctx.entry and ctx.entry.modem, peripheral = env.peripheral,
    })
  end
end

-- the version of the installed files (crn_version.txt: "<ref>-<id>"), or nil
local function file_version(files)
  local text = files.read("crn_version.txt")
  return text and text:match("^%s*(%S+)") or nil
end

-- the doctor's result goes into crn_status.lua: what was checked, when, against which file state (a failure to write it is no failure of the setup)
local function record_status(env, files, report)
  local status = doctor.status(report, { version = file_version(files) })
  if status.role and status.id then pcall(setup_status.write, env.fs, status) end
  return status
end

-- scripts/setup.lua --doctor: what is wrong with this computer, and what to do about it (changes nothing but the record of the result)
function wizard.doctor(env)
  local t = terminal.new(env)
  local files = make_files(env.fs)
  t.say("Pruefung dieses Computers", "title")
  local probe = probe_function(env)
  if probe then t.say("Frage den Master (bis zu einige Sekunden) ...", "dim") end
  local report = doctor.run({ fs = env.fs, peripheral = env.peripheral, probe = probe })
  for _, line in ipairs(doctor.lines(report, t.width() - 1)) do t.say(line.text, line.kind) end
  t.blank()
  t.say(doctor.summary(report), report.fails > 0 and "err" or (report.warns > 0 and "warn" or "ok"))
  local fixes = doctor.fix_lines(report, t.width() - 1)
  if #fixes > 0 then
    t.blank()
    t.say("Was zu tun ist:", "title")
    for _, line in ipairs(fixes) do t.say(line.text, line.kind) end
  end
  record_status(env, files, report)
  return { ok = report.ready, report = report }
end

-- ── the plan of the master (station and depot computers) ────────────────────────────────────────────────────────────

local PLAN_KEY = { station = "platforms", depot = "tracks" }
local PLAN_WORD = { station = "Bahnsteig(e)", depot = "Gleis(e)" }

-- does this entry have the platforms / tracks that the plan of the master would bring?
local function has_devices(entry, role)
  local list = entry and PLAN_KEY[role] and entry[PLAN_KEY[role]]
  return type(list) == "table" and #list > 0
end

-- Fetches the plan, shows what came, and writes it after a "yes". report = a doctor report of this computer (its role, id, plan and entry).
-- io = { ask_yes(question, default) } (the wizard passes its own, the command line a plain one). Returns { ok, state, wrote }.
local function fetch_flow(env, t, files, io, report)
  local ctx = report.ctx
  if not ctx.role then
    t.say("Dieser Computer ist noch nicht eingerichtet. Erst scripts/setup.lua ausfuehren.", "err")
    return { ok = false, state = "setup", wrote = false }
  end
  if not PLAN_KEY[ctx.role] then
    t.say("Nur Bahnhof- und Depot-Computer holen ihren Plan vom Master.", "warn")
    return { ok = false, state = "role", wrote = false }
  end
  if not (ctx.cfg and ctx.entry and ctx.config and ctx.id) then
    t.say("Dieser Computer hat noch keinen gueltigen Netzplan mit seinem Eintrag. Erst scripts/setup.lua ausfuehren.", "err")
    return { ok = false, state = "setup", wrote = false }
  end
  if not env.fetch then
    t.say("Das Holen des Plans ist auf diesem Computer nicht verfuegbar.", "err")
    return { ok = false, state = "unavailable", wrote = false }
  end
  t.say("Frage den Master nach seinem Netzplan (das dauert ohne Antwort einige Sekunden) ...", "dim")
  local called, got = pcall(env.fetch, {
    channel = ctx.cfg.channel, master_id = ctx.cfg.master_id, id = ctx.id, role = ctx.role,
    modem_name = ctx.entry.modem, peripheral = env.peripheral,
    on_total = function(parts, bytes) t.say("Uebertragung: " .. parts .. " Teil(e), " .. bytes .. " Bytes ...", "dim") end,
  })
  if not called then got = { ok = false, state = "error", message = "Das Holen des Plans ist fehlgeschlagen: " .. tostring(got):sub(1, 120) } end
  if type(got) ~= "table" or not got.ok then
    t.say(type(got) == "table" and got.message or "Der Plan konnte nicht geholt werden.", "err")
    return { ok = false, state = type(got) == "table" and got.state or "error", wrote = false }
  end

  t.say("Plan vom Master: " .. netplan.text(netplan.summary(got.cfg)) .. " (Pruefsumme " .. got.version .. ").", "ok")
  local key, word = PLAN_KEY[ctx.role], PLAN_WORD[ctx.role]
  local count = type(got.entry[key]) == "table" and #got.entry[key] or 0
  if count == 0 then
    t.say("Im Plan des Masters hat " .. ctx.id .. " noch keine " .. word .. ". Dort im Eintrag unter \"" .. key .. "\" eintragen (docs/config_reference.md), den Master neu starten und dann noch einmal: scripts/setup.lua --fetch-plan", "warn")
    return { ok = true, state = "empty", wrote = false }
  end
  t.say(ctx.id .. ": " .. count .. " " .. word .. ".")

  -- the devices (and the text scale of the monitor) stay as they are on this computer (the master wrote its entry from what the computer announced, before it was set up for good)
  local body = got.text
  local fields = { modem = ctx.entry.modem, monitor = ctx.entry.monitor, monitor_scale = ctx.entry.monitor_scale }
  local differs = false
  for key, value in pairs(fields) do if got.entry[key] ~= value then differs = true end end
  if differs then body = netplan.encode(netplan.set_fields(got.cfg, ctx.id, fields)) end
  local parsed, errors = netplan.parse(body)
  if not parsed or errors then
    t.say("Der Plan waere mit den Geraeten dieses Computers nicht gueltig. Nichts geaendert.", "err")
    return { ok = false, state = "invalid", wrote = false }
  end
  if files.read(ctx.config) == body then
    t.say("Dieser Computer hat schon genau diesen Plan.", "ok")
    return { ok = true, state = "same", wrote = false }
  end
  if io.ask_yes("Diesen Plan als " .. ctx.config .. " speichern? Die alte Fassung bleibt als " .. ctx.config .. ".prev.", true) ~= true then
    t.say("Nichts geaendert.", "dim")
    return { ok = true, state = "declined", wrote = false }
  end
  local ok, err = files.write(ctx.config, body)
  if not ok then
    t.say("Der Plan konnte nicht gespeichert werden: " .. tostring(err), "err")
    return { ok = false, state = "write", wrote = false }
  end
  t.say("Gespeichert: " .. ctx.config .. ". Er gilt ab dem naechsten Start dieses Computers (reboot).", "ok")
  return { ok = true, state = "written", wrote = true }
end

-- the questions of the commands that run on their own (not inside the wizard): a yes / no question; input that ends is a no
local function cli_io(t)
  return {
    ask_yes = function(question, default_yes)
      t.say(question)
      while true do
        local line = t.ask(default_yes and "[J/n] > " or "[j/N] > ")
        if line == nil then return false end
        line = line:lower()
        if line == "" then return default_yes end
        if line == "j" or line == "ja" or line == "y" or line == "yes" then return true end
        if line == "n" or line == "nein" or line == "no" then return false end
        t.say("Bitte j oder n eingeben.", "err")
      end
    end,
  }
end

-- scripts/setup.lua --fetch-plan: fetch the plan of the master again (the master's plan changed), after a "yes" write it
function wizard.fetch_plan(env)
  local t = terminal.new(env)
  local files = make_files(env.fs)
  t.say("Plan vom Master holen", "title")
  local io = cli_io(t)
  local report = doctor.run({ fs = env.fs, peripheral = env.peripheral })
  local outcome = fetch_flow(env, t, files, io, report)
  if outcome.wrote then
    local after = doctor.run({ fs = env.fs, peripheral = env.peripheral })
    record_status(env, files, after)
    t.say("Pruefung: " .. doctor.summary(after), after.fails > 0 and "err" or (after.warns > 0 and "warn" or "ok"))
  end
  return outcome
end

-- scripts/setup.lua --test: the guided function test of this computer. Reading needs no question, anything that switches is asked for one action
-- at a time (and put back afterwards); the result goes into the record of this computer (crn_status.lua, field hw) and from there to the master.
function wizard.functest(env)
  local t = terminal.new(env)
  local files = make_files(env.fs)
  local io = cli_io(t)
  t.say("Funktionstest dieses Computers", "title")
  local report = doctor.run({ fs = env.fs, peripheral = env.peripheral })
  local ctx = report.ctx
  if not (ctx.role and ctx.cfg and ctx.entry and ctx.id) then
    t.say("Dieser Computer ist noch nicht eingerichtet (Netzplan und Eintrag fehlen). Erst scripts/setup.lua ausfuehren.", "err")
    return { ok = false, state = "setup" }
  end
  if report.fails > 0 then t.say("Hinweis: die Pruefung (scripts/setup.lua --doctor) hat noch rote Punkte; der Test sagt dir dann auch, woran es liegt.", "warn") end
  t.say("Gelesen wird ohne Rueckfrage. Was etwas schaltet, wird einzeln gefragt und danach in den sicheren Zustand gebracht (Signal ROT, Weiche geradeaus). Ohne dein Ja passiert nichts. "
    .. "Dieser Computer sollte dabei nicht gerade im Betrieb sein (Strg+T beendet das Programm).", "dim")
  local opts = {
    peripheral = env.peripheral, redstone = env.redstone, sleep = env.sleep, link = env.link, confirm = io.ask_yes,
    on_step = function(step, phase, result)
      if phase == "end" then
        local tag = result.state == "ok" and "[ OK ] " or (result.state == "fail" and "[FEHL] " or "[----] ")
        t.say(tag .. step.title .. ": " .. tostring(result.detail), result.state == "ok" and "ok" or (result.state == "fail" and "err" or "dim"))
      end
    end,
  }
  t.blank()
  t.say("Das ist geplant:")
  for _, step in ipairs(functest.steps(ctx, opts)) do
    local kind = step.kind == "act" and "[SCHALTET] " or (step.kind == "show" and "[zeigt]    " or "[liest]    ")
    t.say("  " .. kind .. step.title)
  end
  t.blank()
  if io.ask_yes("Funktionstest starten?", true) ~= true then
    t.say("Nichts gemacht.", "dim")
    return { ok = true, state = "declined" }
  end
  t.blank()
  local result = functest.run(ctx, opts)
  t.blank()
  t.say(string.format("Ergebnis: %d bestanden, %d fehlgeschlagen, %d uebersprungen.", result.done, result.failed, result.skipped),
    result.failed > 0 and "err" or (result.skipped > 0 and "warn" or "ok"))
  -- only a complete test counts for the record: a step that was skipped (no yes) has not been tested
  local mark
  if result.failed > 0 then mark = "fail" elseif result.skipped == 0 and result.done > 0 then mark = "ok" end
  if mark then
    local status = setup_status.read(env.fs) or { state = "KONFIGURIERT", role = ctx.role, id = ctx.id, config = ctx.config, version = file_version(files) }
    status.hw, status.hw_at = mark, (env.os and env.os.epoch and math.floor(env.os.epoch("utc") / 1000)) or (os.epoch and math.floor(os.epoch("utc") / 1000)) or os.time()
    pcall(setup_status.write, env.fs, status)
    t.say(mark == "ok" and "Im Pruefprotokoll steht: Hardwaretest bestanden (der Master zeigt es nach der naechsten Meldung)." or "Im Pruefprotokoll steht: Hardwaretest fehlgeschlagen.", mark == "ok" and "ok" or "err")
  else
    t.say("Nicht alle Schritte wurden gemacht: im Pruefprotokoll bleibt der Hardwaretest, wie er war.", "dim")
  end
  return { ok = result.ok, state = result.failed > 0 and "failed" or (result.skipped > 0 and "incomplete" or "passed"), result = result }
end

-- scripts/setup.lua --linktest: how good is the link to the master? Questions are asked (the master sees ordinary probes), nothing is written.
local LINK_ADVICE = {
  none = "Keine Antwort vom Master. Laeuft er? Gleicher Kanal? Das Modem muss in Reichweite sein (Wireless) oder per Kabel verbunden und aktiviert (Kabelmodem: Rechtsklick, roter Ring).",
  bad = "Die meisten Nachrichten gehen verloren. Reichweite des Modems pruefen (Wireless-Modem), Kabel, und ob der Chunk des Masters geladen bleibt.",
  shaky = "Einzelne Nachrichten gehen verloren oder kommen spaet. Der Betrieb wiederholt sie, aber die Strecke ist grenzwertig: Reichweite / Kabel / geladene Chunks pruefen.",
  old_master = "Der Master antwortet, kennt aber das Anmelden von Computern nicht (aelterer Stand). Die Strecke funktioniert; den Master aktualisieren.",
  no_modem = "Dieser Computer hat kein nutzbares Modem. scripts/setup.lua --doctor sagt, was fehlt.",
}

function wizard.linktest(env)
  local t = terminal.new(env)
  t.say("Funkstrecke zum Master testen", "title")
  local report = doctor.run({ fs = env.fs, peripheral = env.peripheral })
  local ctx = report.ctx
  if not (ctx.role and ctx.cfg and ctx.entry and ctx.id) then
    t.say("Dieser Computer ist noch nicht eingerichtet (Netzplan und Eintrag fehlen). Erst scripts/setup.lua ausfuehren.", "err")
    return { ok = false, state = "setup" }
  end
  if ctx.role == "master" then
    t.say("Das ist der Master. Den Test auf einem anderen Computer des Netzes ausfuehren.", "warn")
    return { ok = false, state = "master" }
  end
  if not env.link then
    t.say("Hier kann nicht gefragt werden (kein Modemzugriff in dieser Umgebung).", "err")
    return { ok = false, state = "no_link" }
  end
  t.say("Der Master " .. tostring(ctx.cfg.master_id) .. " wird auf Kanal " .. tostring(ctx.cfg.channel) .. " gefragt. Er sieht gewoehnliche Anfragen dieses Computers (" .. tostring(ctx.id) .. "), geschaltet wird nichts. Das dauert bis zu einer halben Minute.", "dim")
  t.blank()
  local result = linktest.run(ctx, { link = env.link, peripheral = env.peripheral })
  local kind = (result.state == "ok" and result.part_ok) and "ok" or ((result.state == "none" or result.state == "bad" or result.state == "no_modem") and "err" or "warn")
  if result.sent > 0 then
    t.say(string.format("Fragen: %d gestellt, %d beantwortet, %d sofort.", result.sent, result.answered, result.quick), kind)
  end
  if result.rtt_avg then
    t.say(string.format("Laufzeit: im Mittel %.2f s (%.2f bis %.2f s).", result.rtt_avg, result.rtt_min, result.rtt_max), "dim")
  end
  if result.sizes and #result.sizes > 0 then
    t.say("Wie gross darf eine Nachricht sein (hin und zurueck)?")
    for _, size in ipairs(result.sizes) do
      t.say(string.format("  %5d Byte  %s", size.bytes, size.ok and "kommt an" or "KOMMT NICHT AN"), size.ok and "ok" or "err")
    end
  end
  if result.state == "ok" or result.state == "old_master" then
    if result.sizes then
      if result.part_ok then
        t.say("Die Strecke ist in Ordnung, auch Teile des Netzplans (" .. linktest.PART_BYTES .. " Byte) kommen durch.", "ok")
      else
        t.say("Kleine Nachrichten kommen an, grosse nicht (bis " .. tostring(result.largest) .. " Byte). Der Plan-Abruf (--fetch-plan) kann daran scheitern.", "warn")
      end
    end
  end
  if LINK_ADVICE[result.state] then t.say(LINK_ADVICE[result.state], result.state == "old_master" and "warn" or "err") end
  return { ok = result.state == "ok" and result.part_ok == true, state = result.state, result = result }
end

-- scripts/setup.lua --export: the diagnostic file crn_diag.txt (everything a person who is not at the computer needs; nothing is asked or switched)
function wizard.export(env)
  local t = terminal.new(env)
  t.say("Diagnosedatei schreiben", "title")
  local function call(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, value = pcall(fn, ...)
    return ok and value or nil
  end
  local clock = env.os or {}
  local now = clock.epoch and call(clock.epoch, "utc")
  local ok, path, text = export.write({
    fs = env.fs, peripheral = env.peripheral, host = env.host,
    computer_id = call(clock.getComputerID), label = call(clock.getComputerLabel),
    now = type(now) == "number" and math.floor(now / 1000) or nil, date = clock.date,
  })
  if not ok then
    t.say("Die Datei " .. export.PATH .. " konnte nicht geschrieben werden: " .. tostring(path), "err")
    return { ok = false, error = path }
  end
  t.say("Geschrieben: " .. path .. " (" .. #text .. " Byte).", "ok")
  t.say("Darin stehen: Version, Ergebnis der Pruefung, der Eintrag dieses Computers im Netzplan, die angeschlossenen Geraete, Dateien und freier Platz. Passwoerter gibt es nicht; der Netzplan selbst steht nicht drin.", "dim")
  t.say("Weitergeben: 'pastebin put " .. path .. "' (zeigt einen Code) oder die Datei aus dem Ordner des Computers kopieren.", "dim")
  return { ok = true, path = path }
end

-- scripts/setup.lua --layout [file]: the plan of a whole new network from a short description (src/setup/layout.lua), on the master. The build list is
-- harmless and written by default; the plan replaces configs/network.json only after a yes (the old file stays as .prev).
local LAYOUT_PATH = "configs/layout.txt"

-- The planner is for the master only. Every role has the wizard, so a literal require here would put 46 KB on every signal and detector computer: the
-- modules are named by a computed string (the require scan of the installer does not see it) and listed as entries of the master role instead
-- (src/tools/manifest_builder.lua; tests/test_installer_manifest.lua checks both sides).
local function planner(name) return require("src.setup." .. name) end

function wizard.layout(env, path)
  local layout, plan_builder, bauliste = planner("layout"), planner("plan_builder"), planner("bauliste")
  local t = terminal.new(env)
  local files = make_files(env.fs)
  local io = cli_io(t)
  t.say("Netz aus einer Beschreibung bauen", "title")
  local report = doctor.run({ fs = env.fs, peripheral = env.peripheral })
  local ctx = report.ctx
  if not (ctx.role and ctx.id and ctx.config) then
    t.say("Dieser Computer ist noch nicht eingerichtet. Erst scripts/setup.lua ausfuehren (Rolle Master).", "err")
    return { ok = false, state = "setup" }
  end
  if ctx.role ~= "master" then
    t.say("Das Netz wird am Master gebaut. Dieser Computer ist " .. role_label(ctx.role) .. " " .. ctx.id .. ".", "err")
    return { ok = false, state = "no_master" }
  end

  path = path or LAYOUT_PATH
  local text = files.read(path)
  if not text then
    t.say("Die Beschreibung " .. path .. " gibt es noch nicht.", "warn")
    t.say("Darin steht in wenigen Zeilen, welche Bahnhoefe, Strecken und Zuege das Netz hat. Ein Beispiel zum Abaendern kann ich anlegen.", "dim")
    if io.ask_yes("Beispiel als " .. path .. " anlegen?", true) ~= true then return { ok = false, state = "missing" } end
    local ok, err = files.write(path, layout.EXAMPLE)
    if not ok then
      t.say("Die Datei konnte nicht angelegt werden: " .. tostring(err), "err")
      return { ok = false, state = "write" }
    end
    t.say("Angelegt: " .. path .. ". Bearbeiten mit: edit " .. path .. " -- danach scripts/setup.lua --layout noch einmal.", "ok")
    return { ok = true, state = "example" }
  end

  local function refuse(title, list)
    t.say(title, "err")
    for _, line in ipairs(list) do t.say("- " .. line, "err") end
    return { ok = false, state = "invalid" }
  end

  local described, errors = layout.parse(text)
  if not described then return refuse("Die Beschreibung " .. path .. " ist nicht in Ordnung:", errors) end
  if described.given.master_id and described.master_id ~= ctx.id then
    return refuse("Die Beschreibung " .. path .. " ist nicht in Ordnung:", { "sie nennt den Master " .. described.master_id .. ", dieser Computer heisst " .. ctx.id .. " (die Zeile master weglassen)" })
  end
  described.master_id = ctx.id

  local old_text = files.read(ctx.config)
  local old_cfg = old_text and netplan.parse(old_text) or nil
  if not described.given.channel and old_cfg and type(old_cfg.channel) == "number" then described.channel = old_cfg.channel end

  local plan, meta = plan_builder.build(described)
  if not plan then return refuse("Aus der Beschreibung " .. path .. " wird kein Plan:", meta) end
  -- this computer keeps its own devices
  local old_master = old_cfg and netplan.find_node(old_cfg, ctx.id)
  local new_master = netplan.find_node(plan, ctx.id)
  if old_master and new_master then
    for _, key in ipairs({ "modem", "monitor", "monitor_scale" }) do
      if old_master[key] ~= nil then new_master[key] = old_master[key] end
    end
  end
  local body = netplan.encode(plan)
  local parsed, problems = netplan.parse(body)
  if not parsed or problems then return refuse("Der erzeugte Plan ist nicht gueltig (das sollte nicht passieren):", problems or { "keine gueltige Datei" }) end

  local stats = meta.stats
  t.say((described.name ~= "" and ("Netz \"" .. described.name .. "\": ") or "Netz: ") .. stats.stations .. " Bahnhoefe, " .. stats.depots .. " Depots, " .. #described.lines .. " Strecken, " .. stats.trains .. " Zuege.", "ok")
  t.say("Daraus entstehen " .. stats.blocks .. " Bloecke, " .. stats.routes .. " Routen und " .. stats.computers .. " Computer (" .. stats.signals .. " Signale, " .. stats.sensors .. " Melder, " .. stats.switches .. " Weichen).")
  if old_cfg then
    local now = {}
    for _, node in ipairs(plan.nodes) do now[node.id] = true end
    local gone = {}
    for _, node in ipairs(old_cfg.nodes or {}) do
      if type(node) == "table" and node.id and not now[node.id] then gone[#gone + 1] = node.id end
    end
    if #gone > 0 then
      table.sort(gone)
      local shown = {}
      for i = 1, math.min(8, #gone) do shown[i] = gone[i] end
      t.say("Im bisherigen Plan stehen " .. #gone .. " Computer, die im neuen fehlen: " .. table.concat(shown, ", ") .. (#gone > 8 and ", ..." or "") .. ". Sie gehoeren danach nicht mehr zum Netz.", "warn")
    end
  end

  local result = { ok = true, state = "declined", wrote_plan = false, wrote_list = false }
  t.blank()
  if io.ask_yes("Bauliste nach " .. bauliste.PATH .. " schreiben?", true) == true then
    local ok, err = safe_write.write(bauliste.PATH, bauliste.render(plan, meta, described), { fs = env.fs, keep_backup = false })
    if ok then
      result.wrote_list = true
      t.say("Geschrieben: " .. bauliste.PATH .. " (lesen mit: edit " .. bauliste.PATH .. ").", "ok")
    else
      t.say("Die Bauliste konnte nicht geschrieben werden: " .. tostring(err), "err")
    end
  end

  if files.read(ctx.config) == body then
    t.say("Dieser Computer hat schon genau diesen Plan.", "ok")
    result.state = "same"
    return result
  end
  t.say("Der Plan ersetzt " .. ctx.config .. " ganz; die alte Fassung bleibt als " .. ctx.config .. ".prev.", "dim")
  if io.ask_yes("Den Plan als " .. ctx.config .. " speichern?", false) ~= true then
    t.say("Der Plan wurde nicht gespeichert.", "dim")
    return result
  end
  local ok, err = files.write(ctx.config, body)
  if not ok then
    t.say("Der Plan wurde nicht gespeichert: " .. tostring(err), "err")
    result.ok, result.state = false, "write"
    return result
  end
  result.wrote_plan, result.state = true, "written"
  t.say("Gespeichert: " .. ctx.config .. ". Der Master braucht einen Neustart (reboot), damit er den Plan benutzt.", "ok")
  t.say("Danach die Computer nach der Bauliste einrichten.", "ok")
  local after = doctor.run({ fs = env.fs, peripheral = env.peripheral })
  record_status(env, files, after)
  return result
end

-- ── the wizard ────────────────────────────────────────────────────────────────────────────────────────────────────

function wizard.run(opts)
  local env = opts.env
  local args = wizard.parse_args(opts.args)
  if args.check then return wizard.check(args.check_path, env) end
  if args.doctor then return wizard.doctor(env) end
  if args.fetch_plan then return wizard.fetch_plan(env) end
  if args.functest then return wizard.functest(env) end
  if args.linktest then return wizard.linktest(env) end
  if args.export then return wizard.export(env) end
  if args.layout then return wizard.layout(env, args.layout_path) end
  local t = terminal.new(env)
  t.set_hint("Enter ok  ? Hilfe  < zurueck")
  local files = make_files(env.fs)
  local result = { written = {}, rebooted = false }

  local ctx = {
    role = nil, plan = nil, channel = nil, master_id = nil, node_id = nil, fields = {}, plan_entry = nil, single = {},
    peripherals = hardware.scan(env.peripheral),
  }
  if args.role and role_info(args.role) then ctx.preset_role = args.role; ctx.role = args.role end

  -- which steps are part of this run (the header shows exactly these)
  local applies
  local function trail()
    local names = {}
    for _, key in ipairs({ "role", "plan", "identity", "hardware", "summary" }) do
      if key == "summary" or applies[key]() then names[#names + 1] = STEP_NAMES[key] end
    end
    return names
  end
  local function page(key, sub)
    local title = STEP_NAMES[key] .. (sub and (" - " .. sub) or "")
    t.page(title, trail(), STEP_NAMES[key])
  end

  -- ── input helpers: the question is printed once, a wrong answer adds a line and asks again ──────────────────────

  local function read_line(prompt)
    local line = t.ask(prompt)
    if line == nil then error(ABORT, 0) end
    return line
  end

  -- a help screen of its own; the page with the question comes back afterwards
  local function show_help(text)
    local done = t.aside("Hilfe")
    t.say(text)
    t.blank()
    t.say("Weiter mit Enter.", "dim")
    read_line("> ")
    done()
    t.restore()
  end

  local function ask_text(question, o)
    t.say(question)
    if o.hint then t.say(o.hint, "dim") end
    while true do
      -- a long suggestion would push the prompt off the screen: Enter still takes all of it
      local shown = o.default and (#o.default > 24 and (o.default:sub(1, 21) .. "...") or o.default)
      local line = read_line((shown and ("[" .. shown .. "] ") or "") .. "> ")
      if line == "?" then
        show_help(o.help or "Zu dieser Frage gibt es keine weitere Hilfe.")
      elseif line == "<" then
        return BACK
      else
        if line == "" and o.default then line = o.default end
        if line == "" then
          t.say("Bitte etwas eingeben (? zeigt Hilfe).", "err")
        else
          local ok, err = true, nil
          if o.check then ok, err = o.check(line) end
          if ok then return line end
          t.say(err or "Das geht so nicht.", "err")
        end
      end
    end
  end

  -- items: { label, desc, value }; o.default = index, o.help, o.compact (no description lines)
  local function ask_choice(question, items, o)
    o = o or {}
    t.say(question)
    for i, item in ipairs(items) do
      t.say(string.format("%d) %s", i, item.label))
      if item.desc and not o.compact then t.say("     " .. item.desc, "dim") end
    end
    while true do
      local line = read_line((o.default and ("[" .. o.default .. "] ") or "") .. "> ")
      if line == "?" then
        show_help(o.help or "Waehle mit der Nummer.")
      elseif line == "<" then
        return BACK
      else
        if line == "" and o.default then line = tostring(o.default) end
        local n = tonumber(line)
        if n and n >= 1 and n <= #items and n % 1 == 0 then return items[n].value, n end
        t.say("Bitte eine Zahl von 1 bis " .. #items .. " eingeben.", "err")
      end
    end
  end

  local function ask_yes(question, default_yes, help)
    t.say(question)
    while true do
      local line = read_line(default_yes and "[J/n] > " or "[j/N] > "):lower()
      if line == "?" then
        show_help(help or "j = ja, n = nein.")
      elseif line == "<" then
        return BACK
      elseif line == "" then
        return default_yes
      elseif line == "j" or line == "ja" or line == "y" or line == "yes" then
        return true
      elseif line == "n" or line == "nein" or line == "no" then
        return false
      else
        t.say("Bitte j oder n eingeben.", "err")
      end
    end
  end

  local function pause(text)
    t.say(text or "Weiter mit Enter.", "dim")
    local line = read_line("> ")
    if line == "<" then return BACK end
    return "ok"
  end

  -- a list of small questions; "<" at the first one leaves the list. Coming back from the step after this one lands on the last question.
  -- A question that has nothing to ask (one device found, nothing to choose) returns SKIP: going forward it is passed, going back too.
  local function run_sub(list, from_back)
    local direction = from_back and -1 or 1
    local i = from_back and #list or 1
    if i < 1 then i = 1 end
    while i >= 1 and i <= #list do
      local r = list[i]()
      if r == BACK then
        if i == 1 then return BACK end
        direction = -1
        i = i - 1
      elseif r == SKIP then
        i = i + direction
      else
        direction = 1
        i = i + 1
      end
    end
    if i < 1 then return BACK end
    return "next"
  end

  -- ── describing things ───────────────────────────────────────────────────────────────────────────────────────────

  -- the name of the device a plan entry talks to (an entry without one uses its own id, like the adapters do)
  local function peripheral_name(entry)
    if entry.role == "train" then return entry.create_station or entry.schedule_station end
    if entry.adapter == "redstone" then return nil end
    return entry.peripheral or entry.target or entry.id
  end

  local function describe_entry(entry)
    if entry.role == "signal" or entry.role == "sensor" then
      if entry.adapter == "redstone" then return "Redstone, " .. side_word(entry.side) end
      return "Create-Geraet " .. tostring(peripheral_name(entry))
    elseif entry.role == "switch" then
      return "Redstone, " .. side_word(entry.side) .. ", aktiv " .. tostring(entry.active_position or "DIVERGING")
    elseif entry.role == "station" then
      return "Bahnhof '" .. tostring(entry.create_station_name or entry.display_name or entry.id) .. "'"
    elseif entry.role == "train" then
      return "Zug '" .. tostring(entry.display_name or entry.id) .. "'"
    end
    return tostring(entry.display_name or role_label(entry.role))
  end

  local function found_text(name)
    return name .. (hardware.find(ctx.peripherals, name) and " (gefunden)" or " (NICHT gefunden)")
  end

  local function modem_ok() return #hardware.of_class(ctx.peripherals, "modem") > 0 end

  -- ── a computer that is set up already ───────────────────────────────────────────────────────────────────────────────

  -- a new computer starts with the first question; one that is set up asks first whether to do it again
  local function welcome()
    local text = files.read("startup.lua")
    local existing = text and startup_template.parse(text) or nil
    ctx.existing = existing
    if existing and not ctx.preset_role then
      t.page("Einrichtung")
      t.say("Dieser Computer ist schon eingerichtet:", "err")
      t.say("  " .. role_label(existing.role) .. " " .. existing.id .. ", Netzplan " .. existing.config)
      t.blank()
      local again = ask_yes("Neu einrichten?", false, "Nein beendet den Assistenten, nichts wird geaendert. Ja fragt alles neu ab; deine Antworten von damals sind teils als Vorschlag da.")
      if again ~= true then return false end
      ctx.role = role_info(existing.role) and existing.role or nil
      ctx.node_id = existing.id
    end
    return true
  end

  -- ── Rolle ───────────────────────────────────────────────────────────────────────────────────────────────────────

  local function step_role()
    page("role")
    local items, default = {}, nil
    for i, role in ipairs(wizard.ROLES) do
      items[i] = { value = role.key, label = role.label .. " - " .. role.text }
      if role.key == ctx.role then default = i end
    end
    local value = ask_choice("Welche Aufgabe hat dieser Computer?", items, {
      default = default, compact = true,
      help = "Jeder Computer hat genau eine Aufgabe. Es gibt einen Master; alle anderen melden sich bei ihm. Signal, Melder und Weiche sitzen an der Strecke, Bahnhof und Depot bei den Gleisen, der Zug-Computer im Zug.",
    })
    if value == BACK then return BACK end
    ctx.role = value
    return "next"
  end

  -- ── Netzplan ────────────────────────────────────────────────────────────────────────────────────────────────────

  local function read_plan(path)
    local text = files.read(path)
    if not text then return nil end
    local cfg, errors, fatal = netplan.parse(text)
    return cfg, errors, fatal, text
  end

  local function choose_example(question)
    local list = netplan.examples(files)
    if #list == 0 then return nil end
    local items, default, help = {}, 1, { "Fertige Netzplaene zum Ausprobieren, danach anpassbar:" }
    for i, example in ipairs(list) do
      local short = example.name:gsub("^network%.", ""):gsub("%.example%.json$", "")
      if short == "" or example.name == "network.example.json" then short = "example"; default = i end
      items[i] = { value = example, label = string.format("%-13s%s", short, example.note or netplan.short_text(example.summary)) }
      help[#help + 1] = short .. ": " .. netplan.short_text(example.summary)
    end
    return ask_choice(question, items, { default = default, compact = true, help = table.concat(help, "\n") })
  end

  local function confirm_overwrite()
    if not files.exists(netplan.PATH) then return true end
    page("plan", "Ueberschreiben")
    local cfg = read_plan(netplan.PATH)
    local what = cfg and netplan.short_text(netplan.summary(cfg)) or "Datei"
    local yes = ask_yes(netplan.PATH .. " gibt es schon (" .. what .. "). Ueberschreiben?", false,
      "Die alte Datei bleibt als network.json.prev erhalten. Mit Nein kommst du zurueck zur Auswahl.")
    return yes == true
  end

  local function ask_network(from_back)
    local function channel()
      page("plan", "Kanal")
      local value = ask_text("Funkkanal des Netzes", {
        default = tostring(ctx.channel or netplan.DEFAULT_CHANNEL),
        hint = "Alle Computer dieses Netzes brauchen dieselbe Zahl.",
        help = "Der Kanal ist eine Zahl von 1 bis 65535. Computer mit verschiedenen Kanaelen hoeren einander nicht. Ein zweites, getrenntes Netz bekommt eine andere Zahl.",
        check = function(text)
          local n = tonumber(text)
          if n and n >= 1 and n <= 65535 and n % 1 == 0 then return true end
          return false, "Eine ganze Zahl von 1 bis 65535."
        end,
      })
      if value == BACK then return BACK end
      ctx.channel = tonumber(value)
    end
    local function master()
      if ctx.role == "master" then return "ok" end
      page("plan", "Master")
      local value = ask_text("ID des Masters", {
        default = ctx.master_id or netplan.DEFAULT_MASTER,
        hint = "So heisst der Master im Netzplan.",
        help = "Die ID steht beim Master in der Zeile 'master_id' des Netzplans und ist die ID, die er bei seiner Einrichtung bekommen hat.",
        check = netplan.valid_id,
      })
      if value == BACK then return BACK end
      ctx.master_id = value
    end
    return run_sub({ channel, master }, from_back)
  end

  -- the plan for a menu choice; nil = back to the menu (a sub question was left with "<" or a confirmation was declined)
  local function build_plan(choice, keep, keep_errors)
    if choice == "keep" then
      return { mode = "keep", path = netplan.PATH, cfg = keep, errors = keep_errors }
    elseif choice == "copy" then
      page("plan", "Beispiel")
      local example = choose_example("Welches Beispiel kopieren?")
      if example == BACK then return nil end
      local cfg, errors, _, text = read_plan(example.path)
      if not confirm_overwrite() then return nil end
      return { mode = "copy", path = netplan.PATH, cfg = cfg, errors = errors, source = example.path, source_text = text }
    elseif choice == "empty" or choice == "short" then
      if not confirm_overwrite() then return nil end
      return { mode = choice, path = netplan.PATH }
    end
    -- own file
    page("plan", "Datei")
    local path = ask_text("Pfad der Datei", {
      default = ctx.plan and ctx.plan.mode == "use" and ctx.plan.path or nil,
      hint = "zum Beispiel configs/mein_netz.json",
      help = "Die Datei muss ein gueltiger Netzplan sein (JSON). Der Assistent liest sie nur, er aendert sie nicht.",
      check = function(value)
        if not files.exists(value) then return false, "Diese Datei gibt es nicht." end
        local cfg, errors = netplan.parse(files.read(value) or "")
        if not cfg then return false, "Keine gueltige JSON-Datei." end
        if errors then return false, "Netzplan fehlerhaft: " .. tostring(errors[1]) end
        return true
      end,
    })
    if path == BACK then return nil end
    return { mode = "use", path = path, cfg = netplan.parse(files.read(path)) }
  end

  -- a plan with errors only gets in when the player insists
  local function accept_plan(plan)
    if not (plan.cfg and plan.errors) then return true end
    page("plan", "Fehler")
    t.say("Dieser Netzplan hat Fehler:", "err")
    for i = 1, math.min(3, #plan.errors) do t.say("- " .. netplan.explain(plan.errors[i], plan.cfg)) end
    if #plan.errors > 3 then t.say("... und " .. (#plan.errors - 3) .. " weitere.", "dim") end
    t.blank()
    t.say("Ein Computer mit diesem Netzplan startet nicht. Alle Fehler zeigt, auch spaeter:", "dim")
    t.say("  scripts/setup.lua --check", "dim")
    return ask_yes("Trotzdem diesen Netzplan nehmen?", false) == true
  end

  local function step_plan(from_back)
    local is_master = ctx.role == "master"
    -- coming back from the name: a plan that was created here asks its last question again, not the whole menu
    if from_back and ctx.plan and not ctx.plan.cfg then
      if ask_network(true) ~= BACK then return "next" end
    end
    while true do
      page("plan")
      if is_master then
        t.say("Der Netzplan beschreibt dein ganzes Netz: Computer, Bloecke, Routen. Es ist eine JSON-Datei, du baust sie nach und nach aus.", "dim")
      else
        t.say("Der Netzplan liegt komplett beim Master. Dieser Computer braucht nur seinen eigenen Eintrag.", "dim")
      end
      t.blank()
      local keep, keep_errors = read_plan(netplan.PATH)
      local items, default = {}, nil
      if keep then
        items[#items + 1] = { value = "keep", label = "Vorhandenen Netzplan behalten",
          desc = netplan.short_text(netplan.summary(keep)) .. (keep_errors and " - FEHLERHAFT" or "") }
        if not keep_errors then default = #items end
      end
      local has_examples = #netplan.examples(files) > 0
      if is_master then
        if has_examples then items[#items + 1] = { value = "copy", label = "Beispiel als Startpunkt kopieren", desc = "als " .. netplan.PATH .. ", zum Ausbauen" } end
        items[#items + 1] = { value = "empty", label = "Leeren Netzplan anlegen", desc = "nur der Master, den Rest traegst du ein" }
      else
        items[#items + 1] = { value = "short", label = "Kurzplan anlegen (empfohlen)", desc = "nur dieser Computer und der Master" }
      end
      items[#items + 1] = { value = "custom", label = "Eigene Datei angeben", desc = "Pfad zu einem fertigen Netzplan" }
      if not default then
        for i, item in ipairs(items) do
          if (is_master and (item.value == "copy" or item.value == "empty")) or (not is_master and item.value == "short") then default = i; break end
        end
      end
      local choice = ask_choice("Woher kommt der Netzplan?", items, {
        default = default,
        help = "Behalten: die vorhandene Datei bleibt. Kopieren/Anlegen: configs/network.json wird neu geschrieben (die alte Datei bleibt als .prev). Kurzplan: eine kleine gueltige Datei nur fuer diesen Computer; das ganze Netz steht beim Master. Eigene Datei: du gibst den Pfad an und sie wird nur gelesen.",
      })
      if choice == BACK then return BACK end

      local plan = build_plan(choice, keep, keep_errors)
      if plan and accept_plan(plan) then
        ctx.plan = plan
        if plan.cfg then
          ctx.channel, ctx.master_id = plan.cfg.channel, plan.cfg.master_id
          return "next"
        end
        if ask_network(false) ~= BACK then return "next" end
      end
    end
  end

  -- ── Name ────────────────────────────────────────────────────────────────────────────────────────────────────────

  local function step_identity()
    page("identity")
    local plan = ctx.plan
    local label = role_label(ctx.role)

    if ctx.role == "master" then
      local value = ask_text("ID des Masters", {
        default = ctx.node_id or netplan.DEFAULT_MASTER,
        hint = "So wird dieser Computer im Netz genannt.",
        help = "Die ID erscheint im Netzplan als master_id. Erlaubt sind Buchstaben, Ziffern und _ - . (keine Leerzeichen). Alle anderen Computer tragen sie als Master-ID ein.",
        check = netplan.valid_id,
      })
      if value == BACK then return BACK end
      ctx.node_id, ctx.master_id = value, value
      return "next"
    end

    local function id_check(value)
      local ok, err = netplan.valid_id(value)
      if not ok then return false, err end
      if value == ctx.master_id then return false, "Das ist die ID des Masters." end
      if plan.cfg then
        local other = netplan.find_node(plan.cfg, value)
        if other and other.role ~= ctx.role then return false, "Die ID gehoert im Netzplan zu " .. role_label(other.role) .. "." end
        if not other and plan.mode == "use" then return false, "Diese ID steht nicht im Netzplan (die Datei wird nur gelesen)." end
      end
      return true
    end
    local help = "Die ID muss im Netzplan des Masters stehen und hier genauso geschrieben sein. Erlaubt sind Buchstaben, Ziffern und _ - . (keine Leerzeichen)."

    local nodes = plan.cfg and netplan.nodes_of_role(plan.cfg, ctx.role) or {}
    if #nodes > 0 then
      local items, default = {}, 1
      for i, node in ipairs(nodes) do
        items[i] = { value = node.id, label = node.id, desc = describe_entry(node) }
        if node.id == ctx.node_id then default = i end
      end
      if plan.mode ~= "use" then items[#items + 1] = { value = false, label = "Andere ID eingeben" } end
      local value = ask_choice("Welcher Eintrag im Netzplan ist dieser " .. label .. "?", items, { default = default, help = help })
      if value == BACK then return BACK end
      if value then ctx.node_id = value; return "next" end
    elseif plan.mode == "use" then
      t.say("Im Netzplan " .. plan.path .. " gibt es keinen Eintrag mit der Rolle " .. label .. ".", "err")
      t.say("Waehle einen anderen Netzplan oder eine andere Rolle.", "dim")
      t.blank()
      pause("Zurueck mit Enter.")
      return BACK
    end
    local value = ask_text("ID dieses Computers (" .. label .. ")", {
      default = ctx.node_id or netplan.suggest_id(ctx.role, plan.cfg),
      hint = plan.cfg and "Sie wird in den Netzplan eingetragen." or "Die ID, unter der sich der Computer beim Master meldet.",
      help = help,
      check = id_check,
    })
    if value == BACK then return BACK end
    ctx.node_id = value
    return "next"
  end

  -- ── Hardware ────────────────────────────────────────────────────────────────────────────────────────────────────
  -- each function below returns a list of small questions; a computer whose plan entry already says everything has none

  local function side_question(question, hint, default_key)
    return function()
      page("hardware", role_label(ctx.role))
      local items, default = {}, 1
      for i, side in ipairs(hardware.SIDES) do
        items[i] = { value = side.key, label = side.label .. " (" .. side.key .. ")" }
        if side.key == (ctx.fields.side or default_key) then default = i end
      end
      if hint then t.say(hint, "dim") end
      local value = ask_choice(question, items, { default = default, compact = true,
        help = "Gemeint ist die Seite des Computers, nicht die des Signals. Vorne ist die Seite, an der der Computer zu dir schaut; links und rechts siehst du von dort aus." })
      if value == BACK then return BACK end
      ctx.fields.side = value
    end
  end

  -- exactly one device of the kind is attached: one page asks "this one?" instead of a list with a single line
  local function confirm_single(class, label, field, sets_adapter)
    return function()
      local found = hardware.of_class(ctx.peripherals, class)
      ctx.single[field] = false
      if #found ~= 1 then return SKIP end
      page("hardware", role_label(ctx.role))
      t.say(label .. " erkannt: " .. found[1].name .. " (" .. found[1].type .. ")", "ok")
      local yes = ask_yes("Dieses Geraet fuer diesen Computer verwenden?", true,
        "Es haengt genau ein passendes Geraet am Computer. Mit Nein kannst du ein anderes Geraet (oder bei Signal und Melder Redstone) angeben.")
      if yes == BACK then return BACK end
      if yes then
        ctx.single[field] = true
        ctx.fields[field] = found[1].name
        if sets_adapter then ctx.fields.adapter = "peripheral" end
      elseif sets_adapter then
        ctx.fields.adapter = nil
      end
      return "ok"
    end
  end

  local function device_question(class, label, default_name, field)
    field = field or "peripheral"
    return function()
      if ctx.single[field] then return SKIP end
      while true do
        page("hardware", role_label(ctx.role))
        local found = hardware.of_class(ctx.peripherals, class)
        if #found == 0 then
          t.say("Kein " .. label .. " an diesem Computer gefunden.", "err")
          t.say("Baue es direkt oder ueber Kabel/Modem an, dann r eingeben.", "dim")
          local name = ask_text("Name des Geraets (r = erneut suchen)", {
            default = ctx.fields[field] or default_name,
            help = "Der Name, unter dem das Geraet im Netzwerk des Computers erscheint (zum Beispiel " .. default_name .. "). Mit 'peripherals' im Computer siehst du alle.",
          })
          if name == BACK then return BACK end
          if name:lower() ~= "r" then ctx.fields[field] = name; return "ok" end
          ctx.peripherals = hardware.scan(env.peripheral)
        else
          local items, default = {}, 1
          for i, info in ipairs(found) do
            items[i] = { value = info.name, label = info.name .. " (" .. info.type .. ")" }
            if info.name == ctx.fields[field] then default = i end
          end
          items[#items + 1] = { value = false, label = "Anderer Name / erneut suchen" }
          local value = ask_choice(#found .. " " .. label .. " gefunden. Welches gehoert zu diesem Computer?", items, { default = default, compact = true,
            help = "Hier stehen alle passenden Geraete, die am Computer haengen. Gehoert deins nicht dazu, waehle den letzten Eintrag." })
          if value == BACK then return BACK end
          if value then ctx.fields[field] = value; return "ok" end
          ctx.peripherals = hardware.scan(env.peripheral)
          page("hardware", role_label(ctx.role))
          local name = ask_text("Name des Geraets (Enter = erneut suchen)", { default = "r", help = "Name wie in der Liste, oder r um neu zu suchen." })
          if name == BACK then return BACK end
          if name:lower() ~= "r" then ctx.fields[field] = name; return "ok" end
        end
      end
    end
  end

  local function connection_questions(kind)
    local class = kind == "signal" and "create_signal" or "train_observer"
    local label = kind == "signal" and "Create-Signal" or "Train Observer"
    local default_name = kind == "signal" and "Create_Signal_0" or "Create_TrainObserver_0"
    local function how()
      if ctx.single.peripheral then return SKIP end
      page("hardware", role_label(ctx.role))
      local found = #hardware.of_class(ctx.peripherals, class)
      t.say(found > 0 and (label .. " erkannt (" .. found .. ").") or ("Kein " .. label .. " erkannt."), found > 0 and "ok" or "dim")
      local value = ask_choice(kind == "signal" and "Wie steuert dieser Computer das Signal?" or "Wie meldet dieser Computer die Zuege?", {
        { value = "peripheral", label = label .. " am Computer", desc = "direkt oder ueber Kabel/Modem angeschlossen" },
        { value = "redstone", label = "Redstone", desc = kind == "signal" and "Redstone-Signal an einer Seite" or "Redstone-Signal kommt an einer Seite an" },
      }, { default = (ctx.fields.adapter == "redstone" or (found == 0 and ctx.fields.adapter ~= "peripheral")) and 2 or 1,
        help = "Das Create-Geraet ist die genaue Variante: der Computer spricht es direkt an. Redstone geht immer, wenn das Geraet nicht am Computer haengt." })
      if value == BACK then return BACK end
      ctx.fields.adapter = value
    end
    local function detail()
      if ctx.single.peripheral then return SKIP end
      if ctx.fields.adapter == "redstone" then
        return side_question(kind == "signal" and "An welcher Seite liegt der Ausgang?" or "An welcher Seite kommt das Signal an?")()
      end
      return device_question(class, label, default_name)()
    end
    return { confirm_single(class, label, "peripheral", true), how, detail }
  end

  local function display_question(question, help)
    return function()
      page("hardware", role_label(ctx.role))
      local value = ask_text(question, { default = ctx.fields.display_name or ctx.node_id, help = help })
      if value == BACK then return BACK end
      ctx.fields.display_name = value
    end
  end

  local function details_questions()
    local role, f = ctx.role, ctx.fields
    if role == "station" then
      return {
        function()
          page("hardware", role_label(role))
          local items, default = {}, 1
          for i, kind in ipairs(STATION_TYPES) do items[i] = { value = kind.value, label = kind.label }; if kind.value == f.station_type then default = i end end
          local value = ask_choice("Welche Art Bahnhof ist das?", items, { default = default, compact = true, help = "Personenverkehr, Fracht oder beides. Routen und Fahrplaene richten sich danach." })
          if value == BACK then return BACK end
          f.station_type = value
        end,
        display_question("Anzeigename des Bahnhofs", "Der Name, der auf den Monitoren angezeigt wird."),
        function()
          page("hardware", role_label(role))
          local value = ask_text("Name des Bahnhofs in Create", { default = f.create_station_name or f.display_name or ctx.node_id,
            hint = "Genau so, wie er im Create-Bahnhof steht.",
            help = "Create schickt Zuege zu Bahnhoefen ueber deren Namen. Gross-/Kleinschreibung und Leerzeichen muessen exakt stimmen." })
          if value == BACK then return BACK end
          f.create_station_name = value
        end,
      }
    elseif role == "depot" then
      return {
        function()
          page("hardware", role_label(role))
          local items, default = {}, 3
          for i, kind in ipairs(DEPOT_TYPES) do items[i] = { value = kind.value, label = kind.label, desc = kind.desc }; if kind.value == f.depot_type then default = i end end
          local value = ask_choice("Welche Art Depot ist das?", items, { default = default, help = "Abstellen: Zuege stehen dauerhaft. Bereitstellen: sie warten auf ihren Einsatz. Gemischt: beides." })
          if value == BACK then return BACK end
          f.depot_type = value
        end,
        display_question("Anzeigename des Depots", "Der Name, der auf den Monitoren angezeigt wird."),
      }
    elseif role == "train" then
      return {
        confirm_single("create_station", "Create-Bahnhof am Zug", "create_station"),
        device_question("create_station", "Create-Bahnhof am Zug", "Create_Station_0", "create_station"),
        display_question("Anzeigename des Zuges", "Der Name, der auf den Monitoren angezeigt wird."),
      }
    elseif role == "panel" then
      return { display_question("Anzeigename des Monitors", "Der Name, der oben auf dem Monitor steht.") }
    end
    return {}
  end

  -- without a modem the computer cannot reach the network: the way on has to be chosen deliberately (Enter stops here)
  local function modem_question()
    page("hardware", role_label(ctx.role))
    t.say("Dieser Computer hat kein Modem.", "err")
    t.say("Ohne Modem kann er nicht mit dem Netz sprechen. Setze ein Modem direkt an den Computer und starte den Assistenten neu - oder mach weiter und baue es spaeter an.", "dim")
    local go = ask_yes("Trotzdem ohne Modem weitermachen?", false, "Nein beendet den Assistenten, nichts wird geaendert: Modem anbauen, dann noch einmal starten. Ja schreibt die Einrichtung trotzdem; der Computer meldet sich erst, wenn das Modem da ist.")
    if go == BACK then return BACK end
    if go ~= true then error(ABORT, 0) end
    return "ok"
  end

  -- several modems: which one carries the radio network is written into the plan (with one, it is found by itself)
  local function modem_choice_question()
    return function()
      local modems = hardware.of_class(ctx.peripherals, "modem")
      page("hardware", role_label(ctx.role))
      local items, default = {}, 1
      for i, info in ipairs(modems) do
        items[i] = { value = info.name, label = info.name .. " (" .. info.type .. ")" }
        if info.name == ctx.fields.modem then default = i end
      end
      t.say("Dieser Computer hat " .. #modems .. " Modems.", "dim")
      local value = ask_choice("Ueber welches Modem laeuft das Funknetz?", items, { default = default, compact = true,
        help = "Gewaehlt wird ein bestimmtes Modem und im Netzplan festgehalten. Sonst nimmt der Computer irgendeines davon, und das kann nach einem Umbau ein anderes sein. Ein Kabel-Modem fuer Geraete ist nicht das fuer das Funknetz." })
      if value == BACK then return BACK end
      ctx.fields.modem = value
    end
  end

  -- several monitors: which one shows this computer's page
  local function monitor_choice_question()
    return function()
      local monitors = hardware.of_class(ctx.peripherals, "monitor")
      page("hardware", role_label(ctx.role))
      local items, default = {}, 1
      for i, info in ipairs(monitors) do
        items[i] = { value = info.name, label = info.name }
        if info.name == ctx.fields.monitor then default = i end
      end
      t.say("An diesem Computer haengen " .. #monitors .. " Monitore.", "dim")
      local value = ask_choice("Auf welchem Monitor erscheint die Anzeige?", items, { default = default, compact = true,
        help = "Der gewaehlte Monitor wird im Netzplan festgehalten. Sonst nimmt der Computer den ersten, den er findet." })
      if value == BACK then return BACK end
      ctx.fields.monitor = value
    end
  end

  -- devices can be written into the plan when this run writes the entry (a new plan, a new entry, the master of a copied example)
  local function can_bind()
    if not ctx.plan then return false end
    if not ctx.plan_entry then return true end
    return ctx.role == "master" and ctx.plan.mode == "copy"
  end

  local function missing_device_question()
    local entry = ctx.plan_entry
    local name = entry and peripheral_name(entry) or nil
    if entry and (entry.role ~= "signal" and entry.role ~= "sensor" and entry.role ~= "train") then name = nil end
    if not name or hardware.find(ctx.peripherals, name) then return nil end
    return function()
      page("hardware", role_label(ctx.role))
      t.say("Der Netzplan erwartet das Geraet " .. name .. " (Eintrag " .. ctx.node_id .. "), aber es ist nicht angeschlossen.", "err")
      t.say("Baue es an oder pruefe den Namen im Netzplan.", "dim")
      local go = ask_yes("Trotzdem weitermachen?", true)
      if go == BACK then return BACK end
      if go ~= true then error(ABORT, 0) end
      return "ok"
    end
  end

  local function hardware_questions()
    local list = {}
    -- before the plan and the name are known the step is announced for every role but the master, who has no devices to ask for
    local modems = #hardware.of_class(ctx.peripherals, "modem")
    local monitors = #hardware.of_class(ctx.peripherals, "monitor")
    if not ctx.node_id or not ctx.plan then
      if ctx.role == "master" and modems == 1 and monitors < 2 then return {} end
      return { function() return "ok" end }
    end
    ctx.plan_entry = ctx.plan.cfg and netplan.find_node(ctx.plan.cfg, ctx.node_id) or nil
    if ctx.plan_entry and ctx.plan_entry.role ~= ctx.role then ctx.plan_entry = nil end
    if modems == 0 then list[#list + 1] = modem_question
    elseif modems >= 2 and can_bind() then list[#list + 1] = modem_choice_question() end
    if netplan.MONITOR_ROLES[ctx.role] and monitors >= 2 and can_bind() then list[#list + 1] = monitor_choice_question() end
    if ctx.plan_entry then
      local missing = missing_device_question()
      if missing then list[#list + 1] = missing end
    elseif ctx.role == "signal" or ctx.role == "sensor" then
      for _, q in ipairs(connection_questions(ctx.role)) do list[#list + 1] = q end
    elseif ctx.role == "switch" then
      list[#list + 1] = side_question("An welcher Seite gibt der Computer das Weichen-Signal aus?", "Vanilla-Create-Weichen werden mit Redstone gestellt.", "left")
      list[#list + 1] = function()
        page("hardware", role_label(ctx.role))
        local value = ask_choice("Bei Redstone-Signal steht die Weiche auf ...", {
          { value = "DIVERGING", label = "Abzweig (DIVERGING)" }, { value = "STRAIGHT", label = "geradeaus (STRAIGHT)" },
        }, { default = ctx.fields.active_position == "STRAIGHT" and 2 or 1, compact = true,
          help = "Wenn der Computer Redstone ausgibt, schaltet die Weiche in diese Stellung. Im Zweifel Abzweig und im Spiel pruefen." })
        if value == BACK then return BACK end
        ctx.fields.active_position = value
      end
      list[#list + 1] = function()
        page("hardware", role_label(ctx.role))
        local value = ask_yes("Redstone-Signal umkehren?", ctx.fields.invert == true, "Ja, wenn die Weiche im Spiel genau falsch herum steht. Das ist die einfachste Korrektur.")
        if value == BACK then return BACK end
        ctx.fields.invert = value
      end
    else
      for _, q in ipairs(details_questions()) do list[#list + 1] = q end
    end
    return list
  end

  local function step_hardware(from_back) return run_sub(hardware_questions(), from_back) end

  -- ── Pruefen ─────────────────────────────────────────────────────────────────────────────────────────────────────

  local function final_entry()
    if ctx.plan_entry then return ctx.plan_entry end
    if ctx.role == "panel" and not ctx.fields.monitor then
      local monitors = hardware.of_class(ctx.peripherals, "monitor")
      if monitors[1] then ctx.fields.monitor = monitors[1].name end
    end
    return netplan.build_entry(ctx.role, ctx.node_id, ctx.fields)
  end

  local function plan_action()
    local plan = ctx.plan
    local entry_missing = not ctx.plan_entry and ctx.role ~= "master"
    if plan.mode == "copy" then
      return "neu aus " .. plan.source:gsub("^.*/", "") .. (entry_missing and (" + " .. ctx.node_id) or ""), true
    elseif plan.mode == "empty" then return "neu angelegt (nur der Master)", true
    elseif plan.mode == "short" then return "neu angelegt (Kurzplan)", true
    elseif plan.mode == "keep" then
      if entry_missing then return "bleibt, Eintrag " .. ctx.node_id .. " kommt dazu", true end
      return "bleibt unveraendert", false
    end
    return "wird nur gelesen", false
  end

  -- the devices an entry ends up using: named in the plan, chosen here, or found by themselves
  local function device_rows(entry, rows)
    local modems = hardware.of_class(ctx.peripherals, "modem")
    local bound = entry.modem or ctx.fields.modem
    if #modems == 0 then rows[#rows + 1] = { "Modem", "FEHLT (spaeter anbauen)" }
    elseif bound then rows[#rows + 1] = { "Modem", bound .. (hardware.find(ctx.peripherals, bound) and " (festgelegt)" or " (festgelegt, NICHT gefunden)") }
    elseif #modems == 1 then rows[#rows + 1] = { "Modem", modems[1].name .. " (automatisch)" }
    else rows[#rows + 1] = { "Modem", "NICHT festgelegt (" .. #modems .. " vorhanden)" } end
    if netplan.MONITOR_ROLES[ctx.role] then
      local monitors = hardware.of_class(ctx.peripherals, "monitor")
      local chosen = entry.monitor or ctx.fields.monitor
      if chosen then rows[#rows + 1] = { "Monitor", chosen .. (hardware.find(ctx.peripherals, chosen) and " (festgelegt)" or " (NICHT gefunden)") }
      elseif #monitors == 1 then rows[#rows + 1] = { "Monitor", monitors[1].name .. " (automatisch)" }
      elseif #monitors == 0 then rows[#rows + 1] = { "Monitor", "keiner (spaeter anbauen)" }
      else rows[#rows + 1] = { "Monitor", "NICHT festgelegt (" .. #monitors .. " vorhanden)" } end
    end
  end

  local function summary_rows(entry)
    local rows = {}
    local role = ctx.role
    if role == "signal" or role == "sensor" then
      rows[#rows + 1] = { "Anschluss", entry.adapter == "redstone" and ("Redstone, " .. side_word(entry.side)) or found_text(tostring(peripheral_name(entry))) }
    elseif role == "switch" then
      rows[#rows + 1] = { "Anschluss", "Redstone, " .. side_word(entry.side) .. (entry.invert and ", umgekehrt" or "") }
      rows[#rows + 1] = { "Stellung", "bei Signal: " .. label_of(POSITIONS, entry.active_position) }
    elseif role == "station" then
      rows[#rows + 1] = { "Bahnhof", tostring(entry.create_station_name) .. " (" .. label_of(STATION_TYPES, entry.station_type) .. ")" }
    elseif role == "depot" then
      rows[#rows + 1] = { "Depot", tostring(entry.display_name) .. " (" .. label_of(DEPOT_TYPES, entry.depot_type) .. ")" }
    elseif role == "train" then
      if peripheral_name(entry) then rows[#rows + 1] = { "Anschluss", found_text(tostring(peripheral_name(entry))) } end
      rows[#rows + 1] = { "Zug", tostring(entry.display_name) }
    end
    device_rows(entry, rows)
    return rows
  end

  local function steps_list()
    return {
      { key = "role", run = step_role }, { key = "plan", run = step_plan },
      { key = "identity", run = step_identity }, { key = "hardware", run = step_hardware },
    }
  end

  local function summary(steps)
    page("summary")
    local plan = ctx.plan
    local action, writes_plan = plan_action()
    local entry = final_entry()
    t.say(string.format("  %-10s%s", "Rolle", role_label(ctx.role)))
    t.say(string.format("  %-10s%s", "ID", ctx.node_id))
    t.say(string.format("  %-10sKanal %s, Master %s", "Netz", tostring(ctx.channel), tostring(ctx.master_id)))
    t.say(string.format("  %-10s%s", "Netzplan", plan.path))
    t.say(string.format("  %-10s%s", "", action), "dim")
    for _, row in ipairs(summary_rows(entry)) do t.say(string.format("  %-10s%s", row[1], row[2])) end
    t.blank()
    t.say("Geschrieben: startup.lua" .. (writes_plan and (", " .. plan.path) or "") .. ". Alte Dateien bleiben als .prev.", "dim")
    t.blank()
    t.say("[J] schreiben   [N] aendern   [A] abbrechen")
    while true do
      local line = read_line("> "):lower()
      if line == "" or line == "j" or line == "ja" then return "write" end
      if line == "a" or line == "abbrechen" then return "cancel" end
      if line == "?" then
        show_help("J schreibt startup.lua (und den Netzplan, wenn oben steht, dass er neu entsteht). N laesst dich einen Schritt noch einmal machen. A beendet, ohne etwas zu aendern.")
      elseif line == "<" then
        for index = #steps, 1, -1 do if applies[steps[index].key]() then return index end end
        return "again"
      elseif line == "n" or line == "nein" or line == "aendern" then
        page("summary", "aendern")
        local items = {}
        for index, step in ipairs(steps) do
          if applies[step.key]() then items[#items + 1] = { value = index, label = STEP_NAMES[step.key] } end
        end
        local choice = ask_choice("Welchen Schritt aendern?", items, { default = #items > 0 and 1 or nil, compact = true })
        if choice == BACK then return "again" end
        return choice
      else
        t.say("J = schreiben, N = aendern, A = abbrechen.", "err")
      end
    end
  end

  -- ── writing ─────────────────────────────────────────────────────────────────────────────────────────────────────

  local function write_all()
    local plan = ctx.plan
    local entry = final_entry()
    local _, writes_plan = plan_action()

    if writes_plan then
      local cfg
      if plan.mode == "empty" or plan.mode == "short" then
        cfg = netplan.short_plan(ctx.role, entry, ctx.channel, ctx.master_id)
      else
        cfg = plan.cfg
        if not ctx.plan_entry and ctx.role ~= "master" then cfg = netplan.add_node(cfg, entry) end
      end
      -- a copied example gets the modem / monitor that were chosen for its master entry
      local devices_changed = false
      if plan.mode == "copy" and ctx.plan_entry and (ctx.fields.modem or ctx.fields.monitor) then
        cfg = netplan.set_fields(cfg, ctx.node_id, { modem = ctx.fields.modem, monitor = ctx.fields.monitor })
        devices_changed = true
      end
      -- an example that is copied as it is keeps its own formatting; anything that was changed is written in the stable format
      local body
      if plan.mode == "copy" and ctx.plan_entry and not devices_changed then body = plan.source_text else body = netplan.encode(cfg) end
      local parsed, errors = netplan.parse(body)
      if not parsed or errors then
        return false, "Der erzeugte Netzplan ist nicht gueltig: " .. tostring(errors and errors[1] or "unbekannter Fehler")
      end
      local ok, err = files.write(plan.path, body)
      if not ok then return false, "Netzplan konnte nicht geschrieben werden: " .. tostring(err) end
      result.written[#result.written + 1] = plan.path
    end

    local startup, startup_err = startup_template.render({ role = ctx.role, id = ctx.node_id, config = plan.path })
    if not startup then return false, tostring(startup_err) end
    local ok, err = files.write("startup.lua", startup)
    if not ok then return false, "startup.lua konnte nicht geschrieben werden: " .. tostring(err) end
    local back = startup_template.parse(files.read("startup.lua") or "")
    if not (back and back.role == ctx.role and back.id == ctx.node_id and back.config == plan.path) then
      return false, "startup.lua wurde geschrieben, stimmt aber nicht mit den Eingaben ueberein."
    end
    result.written[#result.written + 1] = "startup.lua"
    result.config = plan.path
    -- how far the setup got: the doctor moves it on (and writes it again) once it has looked at what was just written
    pcall(setup_status.write, env.fs, { state = "KONFIGURIERT", role = ctx.role, id = ctx.node_id, config = plan.path, version = file_version(files),
      at = (env.os and env.os.epoch and math.floor(env.os.epoch("utc") / 1000)) or (os.epoch and math.floor(os.epoch("utc") / 1000)) or os.time() })
    return true
  end

  local MASTER_NEXT_STEPS = {
    "Naechste Schritte:",
    "1. Netzplan ausbauen: Computer, Bloecke und Routen",
    "   in " .. netplan.PATH .. " eintragen.",
    "2. Pruefen: scripts/setup.lua --check",
    "3. Neu starten, dann die anderen Computer",
    "   einrichten (Befehl in docs/INSTALL.md).",
  }

  -- the doctor found something: the list, then what to do about it (several pages when it is long)
  local function show_report(report)
    t.page("Pruefung", nil, nil, true)
    for _, line in ipairs(doctor.lines(report, t.width() - 1)) do t.say(line.text, line.kind) end
    t.blank()
    t.say(doctor.summary(report), report.fails > 0 and "err" or "warn")
    t.blank()
    pause("Weiter mit Enter: was zu tun ist.")
    local fixes = doctor.fix_lines(report, t.width() - 1)
    local room = math.max(6, t.height() - 5)
    local index = 1
    while index <= #fixes do
      t.page("Pruefung - was zu tun ist", nil, nil, true)
      local used = 0
      while index <= #fixes and used < room do
        t.say(fixes[index].text, fixes[index].kind)
        index = index + 1
        used = used + 1
      end
      t.blank()
      pause("Weiter mit Enter.")
    end
  end

  local function finish(report)
    t.page("Fertig")
    t.say("Eingerichtet: " .. role_label(ctx.role) .. " " .. ctx.node_id, "ok")
    t.say("  geschrieben: " .. table.concat(result.written, ", "))
    if report then
      local clean = report.fails == 0 and report.warns == 0
      t.say("Pruefung: " .. doctor.summary(report) .. (clean and "" or "  (scripts/setup.lua --doctor)"), report.fails > 0 and "err" or (clean and "ok" or "warn"))
    end
    t.blank()
    -- a node has a line to carry over to the master: the restart must not be the thing that wipes it off the screen
    local keep_screen = false
    if ctx.role == "master" then
      for _, line in ipairs(MASTER_NEXT_STEPS) do t.say(line) end
    elseif report and report.ctx.link == "known" then
      t.say("Der Master kennt diesen Computer schon: nichts weiter einzutragen.", "ok")
    elseif ctx.plan.mode == "use" or ctx.plan_entry then
      t.say("Der Eintrag " .. ctx.node_id .. " steht im Netzplan. Der Master braucht denselben Eintrag, falls er noch fehlt.", "dim")
    else
      if report and report.ctx.link == "pending" then
        t.say("Am Master bestaetigen (Seite Einrichtung) oder die Zeile unten im Netzplan des Masters unter \"nodes\" eintragen:", "ok")
      else
        t.say("Trage diese Zeile im Netzplan des Masters unter \"nodes\" ein:")
      end
      for _, line in ipairs(netplan.entry_lines(final_entry(), t.width() - 2)) do t.say(line) end
      t.say("Sie steht auch in " .. ctx.plan.path .. " dieses Computers.", "dim")
      keep_screen = true
    end
    t.blank()
    -- a red check or a line to carry over: the way on is the player's decision (Enter does not restart)
    local default_restart = not keep_screen and not (report and report.fails > 0)
    local reboot = ask_yes("Jetzt neu starten?", default_restart,
      default_restart and "Beim Neustart startet der Computer in seiner Rolle. Mit Nein startest du spaeter mit 'reboot'."
        or "Beim Neustart verschwindet diese Seite, und mit einer roten Pruefung laeuft der Computer nicht richtig. Erst beheben (scripts/setup.lua --doctor), dann 'reboot'. Mit Ja startest du trotzdem.")
    if reboot == true and env.os and env.os.reboot then
      result.rebooted = true
      t.say("Neustart ...", "dim")
      env.os.reboot()
    else
      t.say("Spaeter neu starten mit: reboot", "dim")
    end
  end

  -- ── the run ─────────────────────────────────────────────────────────────────────────────────────────────────────

  local function main()
    if not welcome() then result.aborted = true; return end
    local steps = steps_list()

    local function step_applies(index) return applies[steps[index].key]() end
    local function neighbour(index, direction)
      index = index + direction
      while index >= 1 and index <= #steps and not step_applies(index) do index = index + direction end
      return index
    end

    local i = neighbour(0, 1)
    local coming_back = false
    while true do
      while i <= #steps do
        local r = steps[i].run(coming_back)
        coming_back = false
        if r == BACK then
          local previous = neighbour(i, -1)
          if previous < 1 then
            page(steps[i].key)
            if ask_yes("Einrichtung abbrechen?", false) == true then result.aborted = true; return end
          else
            i = previous
            coming_back = true
          end
        else
          i = neighbour(i, 1)
        end
      end
      local decision = summary(steps)
      if decision == "cancel" then result.aborted = true; return end
      if decision == "write" then
        local ok, err = write_all()
        if ok then break end
        t.page("Fehler")
        t.say(err, "err")
        t.blank()
        t.say("Die alten Dateien sind unveraendert oder als .prev gesichert.", "dim")
        result.error = err
        pause("Zurueck zur Zusammenfassung mit Enter.")
        i = #steps + 1
      elseif decision == "again" then
        i = #steps + 1
      else
        i = decision
      end
    end
    -- the files are written: from here on the setup is done, whatever happens to the pages that follow
    result.ok = true
    result.role, result.id = ctx.role, ctx.node_id
    local probe = ctx.role ~= "master" and probe_function(env) or nil
    if probe then
      t.page("Pruefung", nil, nil, true)
      t.say("Pruefe diesen Computer und frage den Master, ob er ihn kennt (das dauert ohne Antwort einige Sekunden) ...", "dim")
    end
    local report = doctor.run({ fs = env.fs, peripheral = env.peripheral, probe = probe })
    result.report = report
    record_status(env, files, report)
    if report.fails > 0 or report.warns > 0 then show_report(report) end
    -- a station / depot computer that knows the master but has no platforms / tracks: the master has them in its plan, and this computer can fetch it
    if PLAN_KEY[ctx.role or ""] and report.ctx.link == "known" and not has_devices(report.ctx.entry, ctx.role) and env.fetch then
      t.page("Plan vom Master holen", nil, nil, true)
      t.say("Der Master kennt diesen Computer. Er hat hier aber nur den Kurzplan, also keine " .. PLAN_WORD[ctx.role] .. ". Der Master kann seinen Netzplan senden; "
        .. "darin stehen sie, sobald du sie dort eingetragen hast.")
      t.blank()
      local wanted = ask_yes("Den Plan jetzt vom Master holen?", true,
        "Der Computer fragt den Master nach seinem Netzplan, prueft ihn (Pruefsumme, Format, dass er zu diesem Netz und Computer passt) und schreibt ihn erst nach deinem Ja. "
        .. "Die alte Datei bleibt als .prev. Spaeter geht dasselbe mit: scripts/setup.lua --fetch-plan")
      if wanted == true then
        t.blank()
        local outcome = fetch_flow(env, t, files, { ask_yes = ask_yes }, report)
        t.blank()
        pause("Weiter mit Enter.")
        if outcome.wrote then
          report = doctor.run({ fs = env.fs, peripheral = env.peripheral, probe = probe })
          result.report = report
          record_status(env, files, report)
        end
      end
    end
    finish(report)
  end

  applies = {
    role = function() return not ctx.preset_role end,
    plan = function() return true end,
    -- a master whose plan names it needs no question: its id comes from the plan
    identity = function()
      if ctx.role == "master" and ctx.plan and ctx.plan.cfg then
        ctx.node_id, ctx.master_id = ctx.plan.cfg.master_id, ctx.plan.cfg.master_id
        return false
      end
      return true
    end,
    hardware = function() return #hardware_questions() > 0 end,
  }

  local ok, err = pcall(main)
  if not ok then
    if err == ABORT then result.aborted = not result.ok
    else result.error = tostring(err); error(err, 0) end
  end
  return result
end

return wizard
