--[[
Purpose: The doctor: looks at this computer and says whether it is ready to run its role, and what to do if it is not. Reads only; the one
  thing it writes is the record of its result (crn_status.lua), and only when asked to.
Public API:
  run(opts) -> report { checks, fails, warns, ready, ctx }
    opts: fs (CC fs api), peripheral (CC peripheral api), startup (path, default "startup.lua"),
          probe (nil | { state, detail } | function(ctx) -> { state, detail }: what a test of the link to the master found, see
          src/setup/link.lua; a function is asked only when the plan, the entry and a modem are there to ask with)
    check: { id, level = "ok" | "warn" | "fail", title, fix }
  lines(report, width) -> list of { text, kind }       one line per check, wrapped, "[ OK ] ..." / "[WARN] ..." / "[FEHL] ..."
  fix_lines(report, width) -> list of { text, kind }   what to do about every warning and failure
  summary(report) -> "Alles in Ordnung (9 Punkte)" | "2 Fehler, 1 Hinweis"
  status(report, opts) -> status for src/shared/setup_status.lua      opts: version, now
Notes: the checks, in order: installation complete, startup.lua, network plan (and its errors), the entry of this computer in it, the modem,
  the devices of the role (Create device or redstone side, platforms of a station, blocks of a master), the monitor, free space, the file
  state, the keys (only with auth_mode monitor / enforce), the OTA recovery in startup.lua, and the answer of the master. A failure means the computer cannot do its job; a warning means it
  can but something is probably not as meant. Nothing here switches a signal or a turnout.
]]

local storage_budget = require("src.shared.storage_budget")
local signal_bindings = require("src.shared.signal_bindings")
local hardware = require("src.setup.hardware")
local netplan = require("src.setup.netplan")
local terminal = require("src.setup.terminal")
local startup_template = require("src.shared.startup_template")
local keystore = require("src.shared.keystore")

local doctor = {}

local ROLE_LABEL = {
  master = "Master", signal = "Signal", sensor = "Melder", switch = "Weiche", station = "Bahnhof", depot = "Depot", train = "Zug", panel = "Monitor", arbiter = "Schiedsrichter", fleet = "Flotte",
}
local DEVICE = {
  signal = { class = "create_signal", label = "Create-Signal" },
  sensor = { class = "train_observer", label = "Train Observer" },
}
local TAGS = { ok = "[ OK ] ", warn = "[WARN] ", fail = "[FEHL] " }
-- what to do when a station / depot computer has no platforms / tracks: they stand in the plan of the master, from where this computer fetches them
local function FETCH_HINT(key, id)
  return "Sie stehen im Netzplan des Masters im Eintrag " .. id .. " unter \"" .. key .. "\" (mit sensor_id und block_id; docs/config_reference.md). Ist der Computer am Master angenommen und der Master neu gestartet, holt scripts/setup.lua --fetch-plan den Plan."
end
local KINDS = { ok = "ok", warn = "warn", fail = "err" }
-- the pages of the master and of a panel are drawn for this many characters (51 x 19 is a 5 x 3 block monitor at text scale 1)
local PAGE_ROLES = { master = true, panel = true }
local PAGE_WIDTH, PAGE_HEIGHT = 51, 19

local function kb(bytes) return math.floor(bytes / 1000 + 0.5) end

function doctor.run(opts)
  local o = opts or {}
  local fs_api = o.fs or _G.fs
  local devices = hardware.scan(o.peripheral or _G.peripheral)
  local report = { checks = {}, fails = 0, warns = 0, ready = true, ctx = {} }
  local ctx = report.ctx
  local modem_usable = false

  local function add(id, level, title, fix)
    report.checks[#report.checks + 1] = { id = id, level = level, title = title, fix = fix }
    if level == "fail" then report.fails = report.fails + 1 elseif level == "warn" then report.warns = report.warns + 1 end
  end

  local function exists(path) return fs_api and fs_api.exists and fs_api.exists(path) end
  local function read(path)
    if not exists(path) then return nil end
    local fh = fs_api.open(path, "r")
    if not fh then return nil end
    local body = fh.readAll()
    fh.close()
    return body
  end

  -- 1. installation complete
  if exists("crn_install_journal.lua") or exists("crn_install_journal.lua.prev") then
    add("install", "fail", "Installation unvollstaendig", "Den Installer fortsetzen: installer --resume")
  else
    add("install", "ok", "Installation vollstaendig")
  end

  -- 2. startup.lua
  local startup_path = o.startup or "startup.lua"
  local startup_text = read(startup_path)
  local parsed = startup_text and startup_template.parse(startup_text) or nil
  if not startup_text then
    add("startup", "fail", "startup.lua fehlt", "Den Assistenten ausfuehren: scripts/setup.lua")
  elseif not parsed then
    add("startup", "fail", "startup.lua ist nicht vom Assistenten", "Den Assistenten ausfuehren: scripts/setup.lua (die alte Datei bleibt als startup.lua.prev)")
  else
    ctx.role, ctx.id, ctx.config = parsed.role, parsed.id, parsed.config
    add("startup", "ok", (ROLE_LABEL[parsed.role] or parsed.role) .. " " .. parsed.id)
    if not (startup_text:find("src.shared.ota_recovery", 1, true) and startup_text:find("crn_install_journal", 1, true)) then
      add("recovery", "warn", "startup.lua ohne Wiederherstellung", "Die Wiederherstellung nachtragen: scripts/upgrade_startup.lua")
    end
  end

  -- 3. the plan
  if ctx.config then
    local plan_text = read(ctx.config)
    if not plan_text then
      add("plan", "fail", "Netzplan fehlt: " .. ctx.config, "Den Assistenten ausfuehren (scripts/setup.lua) oder die Datei anlegen.")
    else
      local cfg, errors = netplan.parse(plan_text)
      if not cfg then
        add("plan", "fail", "Netzplan ist kein gueltiges JSON", "Die Datei " .. ctx.config .. " reparieren oder mit dem Assistenten neu anlegen (scripts/setup.lua).")
      elseif errors then
        ctx.cfg = cfg
        add("plan", "fail", "Netzplan: " .. #errors .. " Fehler",
          "Alle Fehler zeigt: scripts/setup.lua --check. Der erste: " .. netplan.explain(errors[1], cfg))
      else
        ctx.cfg = cfg
        local summary = netplan.summary(cfg)
        add("plan", "ok", "Netzplan: " .. summary.computers .. " Computer, Kanal " .. tostring(cfg.channel))
      end
    end
  end

  -- 4. the entry of this computer
  if ctx.cfg and ctx.id then
    if ctx.role == "master" then
      if ctx.cfg.master_id ~= ctx.id then
        add("identity", "fail", "Master-ID passt nicht zum Netzplan",
          "Im Netzplan heisst der Master '" .. tostring(ctx.cfg.master_id) .. "', dieser Computer '" .. ctx.id .. "'. Eins von beiden aendern (scripts/setup.lua).")
      end
    end
    local entry = netplan.find_node(ctx.cfg, ctx.id)
    if not entry then
      add("identity", "fail", "Im Netzplan fehlt der Eintrag " .. ctx.id,
        "Den Assistenten noch einmal ausfuehren: er legt den Eintrag an. Beim Master muss der Eintrag ebenfalls stehen.")
    elseif entry.role ~= ctx.role then
      add("identity", "fail", "Rolle im Netzplan: " .. tostring(entry.role),
        "Dieser Computer ist " .. (ROLE_LABEL[ctx.role] or ctx.role) .. ". Den Eintrag " .. ctx.id .. " oder die Rolle aendern (scripts/setup.lua).")
    else
      ctx.entry = entry
      if not (ctx.role == "master" and ctx.cfg.master_id ~= ctx.id) then add("identity", "ok", "Eintrag " .. ctx.id .. " im Netzplan") end
    end
  end

  -- 5. the modem
  do
    local modems = hardware.of_class(devices, "modem")
    local bound = ctx.entry and ctx.entry.modem
    if bound then
      if hardware.find(devices, bound) then
        modem_usable = true
        add("modem", "ok", "Modem " .. bound .. " (festgelegt)")
      else
        add("modem", "fail", "Modem " .. bound .. " nicht gefunden", "Das Modem wieder anbauen oder den Namen im Netzplan aendern (Feld modem beim Eintrag " .. tostring(ctx.id) .. ").")
      end
    elseif #modems == 0 then
      add("modem", "fail", "Kein Modem", "Ein Modem direkt an den Computer setzen (oder per Kabel anbinden). Ohne Modem erreicht er das Netz nicht.")
    elseif #modems == 1 then
      modem_usable = true
      local kind = hardware.modem_kind(modems[1])
      add("modem", "ok", "Modem " .. modems[1].name .. " (" .. (kind ~= "" and (kind .. ", ") or "") .. "automatisch)")
    else
      modem_usable = true
      local names, wireless = {}, {}
      for _, info in ipairs(modems) do
        local kind = hardware.modem_kind(info)
        names[#names + 1] = info.name .. (kind ~= "" and (" (" .. kind .. ")") or "")
        if info.wireless == true then wireless[#wireless + 1] = info end
      end
      if #wireless == 1 then
        -- the net takes the wireless modem by itself; a cable modem beside it belongs to the monitors
        add("modem", "ok", "Modem " .. wireless[1].name .. " (Funk, automatisch)", "Gesehen: " .. table.concat(names, ", ") .. ". Das Funknetz nimmt das Funkmodem; ein Kabelmodem daneben bleibt fuer Monitore und Geraete.")
      else
        add("modem", "warn", "Mehrere Modems, keines festgelegt",
          "Es gibt " .. table.concat(names, ", ") .. ". Den Assistenten ausfuehren oder beim Eintrag \"modem\": \"" .. modems[1].name .. "\" eintragen, sonst entscheidet der Zufall.")
      end
    end
  end

  -- 6. the devices of the role
  local entry = ctx.entry
  if entry then
    local role = ctx.role
    local function side_ok(side)
      for _, known in ipairs(hardware.SIDES) do if known.key == side then return true end end
      return false
    end
    if role == "signal" and type(entry.signals) == "table" then
      -- several signals on this computer: each logical signal is bound to a device (scripts/bind_signals.lua), nothing is bound by itself
      local bindings = signal_bindings.new({ fs = fs_api, node_id = ctx.id })
      local state, why = bindings.load()
      local present = {}
      for _, info in ipairs(devices) do present[info.name] = info.type end
      local unbound, unusable, usable = {}, {}, 0
      if state == "corrupt" then
        add("device", "fail", "Signal-Bindungen unlesbar", "state/signal_bindings.json ist beschaedigt (" .. tostring(why) .. "): kein Signal dieses Computers wird benutzt. scripts/bind_signals.lua check; die Datei steht als .prev noch einmal da.")
      else
        for _, signal_id in ipairs(entry.signals) do
          if not bindings.get(signal_id) then unbound[#unbound + 1] = signal_id
          elseif bindings.is_usable(signal_id, present) then usable = usable + 1
          else unusable[#unusable + 1] = signal_id end
        end
        local total = #entry.signals
        if #unusable > 0 then
          add("device", "fail", #unusable .. " von " .. total .. " Signalen nicht nutzbar: " .. table.concat(unusable, ", "), "Das Geraet fehlt oder hat einen anderen Typ. scripts/bind_signals.lua check zeigt, was; mit replace <ID> ein Ersatzgeraet binden.")
        elseif #unbound > 0 then
          add("device", "warn", usable .. " von " .. total .. " Signalen gebunden, offen: " .. table.concat(unbound, ", "), "Nicht gebundene Signale bleiben rot. Je Signal: scripts/bind_signals.lua bind " .. unbound[1] .. " (das Modem eines Signals anschliessen, bestaetigen).")
        else
          add("device", "ok", "Signale: " .. total .. " von " .. total .. " gebunden und nutzbar")
        end
      end
    elseif role == "signal" or role == "sensor" then
      local want = DEVICE[role]
      if entry.adapter == "redstone" then
        if side_ok(entry.side) then add("device", "ok", want.label .. ": Redstone " .. entry.side)
        else add("device", "fail", "Redstone-Seite fehlt oder ist ungueltig", "Beim Eintrag " .. ctx.id .. " \"side\" auf left, right, front, back, top oder bottom setzen.") end
      else
        local name = entry.peripheral or entry.target or ctx.id
        local found = hardware.find(devices, name)
        if not found then
          add("device", "fail", want.label .. " " .. name .. " nicht gefunden",
            "Das Geraet anbauen (direkt oder ueber Kabel und Modem; 'peripherals' zeigt die Namen) oder den Namen im Netzplan aendern (Feld peripheral).")
        elseif found.class ~= want.class then
          add("device", "warn", name .. " ist kein " .. want.label, "Das Geraet " .. name .. " hat nicht die Methoden eines " .. want.label .. "s. Stimmt der Name im Netzplan?")
        else
          add("device", "ok", want.label .. " " .. name)
        end
      end
    elseif role == "switch" then
      if entry.adapter ~= "redstone" then
        add("device", "fail", "Weiche braucht Redstone", "Vanilla-Create-Weichen haben keine Peripherie: beim Eintrag \"adapter\": \"redstone\" und \"side\" setzen.")
      elseif side_ok(entry.side) then
        add("device", "ok", "Weiche: Redstone " .. entry.side)
      else
        add("device", "fail", "Redstone-Seite fehlt oder ist ungueltig", "Beim Eintrag " .. ctx.id .. " \"side\" auf left, right, front, back, top oder bottom setzen.")
      end
    elseif role == "train" then
      local name = entry.create_station or entry.schedule_station
      if not name then
        add("device", "warn", "Kein Create-Bahnhof eingetragen", "Ohne Bahnhof am Zug kann der Fahrplan nicht gesetzt werden. Den Assistenten ausfuehren oder \"create_station\" eintragen.")
      elseif not hardware.find(devices, name) then
        add("device", "fail", "Create-Bahnhof " .. name .. " nicht gefunden", "Den Bahnhof am Computer anbauen oder den Namen im Netzplan aendern (create_station).")
      else
        add("device", "ok", "Create-Bahnhof " .. name)
      end
    elseif role == "station" then
      if type(entry.platforms) ~= "table" or #entry.platforms == 0 then
        add("device", "warn", "Bahnhof ohne Bahnsteige", "Dieser Computer liest die Bahnsteige aus seinem eigenen Netzplan. " .. FETCH_HINT("platforms", ctx.id))
      else
        add("device", "ok", "Bahnhof: " .. #entry.platforms .. " Bahnsteig(e)")
      end
    elseif role == "depot" then
      if type(entry.tracks) ~= "table" or #entry.tracks == 0 then
        add("device", "warn", "Depot ohne Gleise", "Dieser Computer liest die Gleise aus seinem eigenen Netzplan. " .. FETCH_HINT("tracks", ctx.id))
      else
        add("device", "ok", "Depot: " .. #entry.tracks .. " Gleis(e)")
      end
    elseif role == "master" then
      local blocks, routes = #(ctx.cfg.blocks or {}), #(ctx.cfg.routes or {})
      if blocks == 0 or routes == 0 then
        add("device", "warn", "Netzplan ohne Bloecke oder Routen", "Es kann noch kein Zug fahren. Bloecke und Routen in " .. tostring(ctx.config) .. " eintragen (docs/config_reference.md), dann scripts/setup.lua --check.")
      else
        add("device", "ok", "Netzplan: " .. blocks .. " Block/Bloecke, " .. routes .. " Route(n)")
      end
    end
  end

  -- 7. the monitor
  if ctx.role and netplan.MONITOR_ROLES[ctx.role] then
    local monitors = hardware.of_class(devices, "monitor")
    local named = entry and entry.monitor
    local bad = ctx.role == "panel" and "fail" or "warn"
    -- the pages of the master and of a panel are laid out for 51 x 19 characters: a smaller monitor cuts them, the text scale is the way to more room
    local function monitor_line(name, how)
      local label = "Monitor " .. name .. " (" .. how .. ")"
      if not PAGE_ROLES[ctx.role] then return add("monitor", "ok", label) end
      if entry and entry.monitor_scale ~= nil then return add("monitor", "ok", label .. ", Textskalierung " .. tostring(entry.monitor_scale)) end
      local api = o.peripheral or _G.peripheral
      local width, height
      if api and api.wrap then
        local wrapped, device = pcall(api.wrap, name)
        if wrapped and type(device) == "table" and type(device.getSize) == "function" then
          local sized, w, h = pcall(device.getSize)
          if sized and type(w) == "number" and type(h) == "number" then width, height = w, h end
        end
      end
      if width and (width < PAGE_WIDTH or height < PAGE_HEIGHT) then
        return add("monitor", "warn", "Monitor " .. name .. " nur " .. width .. " x " .. height .. " Zeichen (die Seiten brauchen " .. PAGE_WIDTH .. " x " .. PAGE_HEIGHT .. ")",
          "Mehr Platz bringt eine kleinere Schrift: im Eintrag dieses Computers \"monitor_scale\": 0.5 (docs/config_reference.md), danach neu starten. Oder mehr Bloecke zum Monitor zusammenbauen.")
      end
      return add("monitor", "ok", label)
    end
    if named then
      if hardware.find(devices, named) then
        monitor_line(named, "festgelegt")
      else
        add("monitor", bad, "Monitor " .. named .. " nicht gefunden", "Den Monitor anbauen oder den Namen im Netzplan aendern (Feld monitor). Ohne Namen wird der erste gefundene genommen.")
      end
    elseif #monitors == 0 then
      add("monitor", bad, "Kein Monitor", "Einen Monitor direkt an den Computer setzen oder per Kabel anbinden. Ohne Monitor bleibt die Anzeige leer.")
    elseif #monitors == 1 then
      monitor_line(monitors[1].name, "automatisch")
    else
      add("monitor", "warn", "Mehrere Monitore, keiner festgelegt", "Beim Eintrag \"monitor\": \"" .. monitors[1].name .. "\" (oder einen anderen) eintragen, sonst gilt der erste.")
    end
  end

  -- 8. free space
  do
    local ok, free = pcall(function() return fs_api and fs_api.getFreeSpace and fs_api.getFreeSpace("/") end)
    if ok and type(free) == "string" then free = free:lower() == "unlimited" and math.huge or tonumber(free) end
    if ok and type(free) == "number" and free ~= math.huge and free >= 0 then
      if free < 8000 then
        add("space", "fail", "Speicher fast voll: " .. kb(free) .. " KB frei", "Platz schaffen (Logs und Spuren loeschen): Zustandsdateien brauchen Platz. Der Computer fasst fest 1 MB.")
      elseif free < 30000 then
        add("space", "warn", "Wenig Speicher: " .. kb(free) .. " KB frei", "Platz schaffen, damit Updates und Zustandsdateien Platz haben. Der Computer fasst fest 1 MB.")
      else
        add("space", "ok", "Speicher: " .. kb(free) .. " KB frei")
      end
    end
  end

  -- 8b. a computer holds a fixed 1 MB: after the program and the state files an update still needs room for the staged copies and the backups (src/shared/storage_budget.lua).
  -- The setup files (this tool is one of them) leave the computer when the tool is done: their bytes count as free.
  do
    local okf, free = pcall(function() return fs_api and fs_api.getFreeSpace and fs_api.getFreeSpace("/") end)
    local record = read("crn_install.lua")
    local bundle_block = record and record:match("bundle_files%s*=%s*(%b{})") or ""
    for path in bundle_block:gmatch('"([^"]+)"') do
      local body = read(path)
      if body and okf and type(free) == "number" then free = free + math.max(#body, storage_budget.MIN_FILE_COST) end
    end
    if okf and type(free) == "number" and free ~= math.huge and free >= 8000 and free < storage_budget.OTA_HEADROOM then
      add("space_ota", "warn", "Fuer ein Update bleibt nur " .. kb(free) .. " KB",
        "Ein Update braucht Platz fuer neue Dateien und Sicherungen. Logs und Spuren loeschen, sonst den Installer verwenden (er ersetzt Datei fuer Datei).")
    end
  end

  -- 9. which version of the files
  do
    local version = read("crn_version.txt")
    if version and version:match("%S") then
      add("version", "ok", "Dateistand " .. version:match("^%s*(%S+)"))
    else
      add("version", "warn", "Kein Dateistand bekannt", "Der Installer legt crn_version.txt an: einmal 'installer' ausfuehren.")
    end
  end

  -- 9b. keys for the authentication of the messages (only when the plan switches it on: auth_mode monitor / enforce)
  do
    local mode = ctx.cfg and ctx.cfg.auth_mode
    if (mode == "monitor" or mode == "enforce" or (mode ~= nil and mode ~= "off")) and ctx.role and ctx.id then
      local strict = mode ~= "monitor"
      local missing = strict and "fail" or "warn"
      if ctx.role == "master" then
        local master_key = keystore.load_master(nil, { fs = fs_api })
        local trust, trust_err = keystore.load_trust(nil, { fs = fs_api })
        if not master_key then
          add("keys", missing, "Kein Master-Schluessel", "Am ersten Master: scripts/keys.lua init. Am zweiten Master: keys import-master (docs/KEYS.md).")
        elseif not trust then
          add("keys", "fail", "Liste der Schluessel beschaedigt (" .. tostring(trust_err) .. ")", "Die Datei state/crn_trust.json wiederherstellen (state/crn_trust.json.prev) oder neu ausgeben (docs/KEYS.md).")
        else
          add("keys", mode == "monitor" and "warn" or "ok", "Schluessel: Master-Schluessel und Liste vorhanden" .. (mode == "monitor" and ", Pruefmodus (nichts wird abgelehnt)" or ""),
            mode == "monitor" and "Wenn alle Computer ihren Schluessel haben: im Netzplan auth_mode auf \"enforce\" stellen." or nil)
        end
      else
        local record, err = keystore.load_node(nil, { fs = fs_api })
        if not record then
          add("keys", missing, "Kein Schluessel fuer diesen Computer", "Am Master: scripts/keys.lua issue " .. tostring(ctx.id) .. "; hier: scripts/keys.lua install --id " .. tostring(ctx.id) .. " (docs/KEYS.md).")
        elseif record.id ~= ctx.id then
          add("keys", missing, "Der Schluessel gehoert zu " .. record.id, "Den richtigen Schluessel einrichten: scripts/keys.lua install --id " .. tostring(ctx.id) .. ".")
        else
          add("keys", mode == "monitor" and "warn" or "ok", "Schluessel Nummer " .. record.epoch .. " vorhanden" .. (mode == "monitor" and ", Pruefmodus (nichts wird abgelehnt)" or ""),
            mode == "monitor" and "Wenn alle Computer ihren Schluessel haben: im Netzplan auth_mode auf \"enforce\" stellen." or nil)
        end
      end
    end
  end

  -- 10. the master
  if o.probe and ctx.role and ctx.role ~= "master" and (type(o.probe) ~= "function" or (modem_usable and ctx.cfg and ctx.entry)) then
    local result = type(o.probe) == "function" and o.probe(ctx) or o.probe
    local state = type(result) == "table" and result.state or nil
    ctx.link = state or "no_answer"
    local master = ctx.cfg and ctx.cfg.master_id or "?"
    if state == "known" then
      add("link", "ok", "Master antwortet und kennt " .. tostring(ctx.id))
    elseif state == "pending" then
      add("link", "warn", "Master kennt " .. tostring(ctx.id) .. " noch nicht",
        "Am Master bestaetigen (Seite Einrichtung, neue Computer) oder die Zeile aus dem Assistenten in den Netzplan des Masters eintragen.")
    elseif state == "conflict" then
      add("link", "fail", "Master kennt " .. tostring(ctx.id) .. " mit anderer Rolle", "Die ID " .. tostring(ctx.id) .. " ist im Netzplan des Masters vergeben: eine andere ID nehmen oder dort die Rolle aendern.")
    elseif state == "rejected" then
      add("link", "warn", "Master hat " .. tostring(ctx.id) .. " abgelehnt",
        "Nach etwa 10 Minuten meldet sich der Computer erneut. Oder den Eintrag am Master von Hand in den Netzplan schreiben (die Zeile zeigt scripts/setup.lua am Ende).")
    elseif state == "old_master" then
      add("link", "ok", "Master antwortet (aelterer Stand)")
    elseif state == "no_modem" then
      -- reported by the modem check already
    else
      add("link", "warn", "Master antwortet nicht",
        "Laeuft der Master (" .. master .. ")? Gleicher Kanal, Modem in Reichweite, beide Modems offen? Der Test ist erst im Betrieb endgueltig.")
    end
  end

  report.ready = report.fails == 0
  return report
end

local function plural(n, one, many) return n .. " " .. (n == 1 and one or many) end

function doctor.summary(report)
  if report.fails == 0 and report.warns == 0 then return "Alles in Ordnung (" .. #report.checks .. " Punkte)" end
  local parts = {}
  if report.fails > 0 then parts[#parts + 1] = plural(report.fails, "Fehler", "Fehler") end
  if report.warns > 0 then parts[#parts + 1] = plural(report.warns, "Hinweis", "Hinweise") end
  return table.concat(parts, ", ")
end

function doctor.lines(report, width)
  local out = {}
  for _, check in ipairs(report.checks) do
    local tag = TAGS[check.level]
    local pad = string.rep(" ", #tag)
    for index, line in ipairs(terminal.wrap(check.title, width - #tag)) do
      out[#out + 1] = { text = (index == 1 and tag or pad) .. line, kind = KINDS[check.level] }
    end
  end
  return out
end

function doctor.fix_lines(report, width)
  local out = {}
  for _, check in ipairs(report.checks) do
    if check.level ~= "ok" and check.fix then
      for _, line in ipairs(terminal.wrap("- " .. check.title, width)) do out[#out + 1] = { text = line, kind = KINDS[check.level] } end
      for _, line in ipairs(terminal.wrap("  " .. check.fix, width)) do out[#out + 1] = { text = line, kind = "dim" } end
    end
  end
  return out
end

function doctor.status(report, opts)
  local o = opts or {}
  local ctx = report.ctx
  local now = o.now
  if not now then
    if os.epoch then now = math.floor(os.epoch("utc") / 1000) else now = os.time() end
  end
  return {
    state = report.ready and "GEPRUEFT" or "PRUEFUNG_OFFEN",
    role = ctx.role, id = ctx.id, config = ctx.config, version = o.version,
    at = math.floor(now), fail = report.fails, warn = report.warns,
  }
end

return doctor
