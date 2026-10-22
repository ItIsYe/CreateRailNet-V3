--[[
Purpose: The operator's tool to bind the monitors of a panel computer (Gesamtkonzept Kap. 11.1, Pruefplan H-01, H-14).
Public API: run(argv, env) -> exit code (0 ok, 1 refused or failed). USAGE is the help text.
  env: fs, peripheral (the CC peripheral api), say(text), ask(prompt) -> text, id (this node), path (default state/panel_monitors.json).
Commands: list, check, bind <ID> [view] [scale], replace <ID>, unbind <ID>, label <ID> <text>, scale <ID> <n>, view <ID> <view>, group <G> <ID> <ID> ..., ungroup <G>.
Notes: bind shows a big number on every monitor that is not bound yet (text scale 5) and asks which number the operator sees on the screen that should get the id; nothing is bound without that answer and a
  second confirmation, nothing is rebound by itself (a missing monitor is reported by check, a replacement is done with replace and the same questions). A group shares only train, station and section.
  All texts German, ASCII only.
]]

local monitor_registry = require("src.panel.monitor_registry")

local monitor_tool = {}

monitor_tool.USAGE = table.concat({
  "Monitore dieses Computers binden (scripts/bind_monitors.lua)",
  "  list                       zeigt alle Monitore, ihre Bindung, Ansicht und Gruppe",
  "  check                      vergleicht Bindungen und angeschlossene Monitore (aendert nichts)",
  "  bind <ID> [Ansicht] [Skala]  einen Monitor an <ID> binden (grosse Nummer zeigt, welcher es ist)",
  "  replace <ID>               einen ersetzten Monitor fuer <ID> neu binden",
  "  unbind <ID>                Bindung loeschen",
  "  label <ID> <Text>          Name fuer Menschen",
  "  scale <ID> <0.5..5>        Textgroesse        view <ID> <Ansicht>  Startansicht",
  "  group <G> <ID> <ID> ...    Monitore verknuepfen (teilen nur Zug, Station, Abschnitt)",
  "  ungroup <G>                Gruppe aufloesen"
}, "\n")

local function yes(text) return text ~= nil and text:lower():match("^%s*[jy]") ~= nil end

local function views_text()
  local names = {}
  for name in pairs(monitor_registry.VIEWS) do names[#names + 1] = name end
  table.sort(names)
  return table.concat(names, ", ")
end

function monitor_tool.run(argv, env)
  local say = env.say or function() end
  local registry = monitor_registry.new({ fs = env.fs, path = env.path or monitor_registry.DEFAULT_PATH, peripheral = env.peripheral, node_id = env.id })
  local state, why = registry.load()
  if state == "corrupt" then
    say("Die Monitor-Datei ist nicht lesbar (" .. tostring(why) .. "). Es wird nichts gebunden, bis sie geprueft ist.")
    return 1
  end

  local command = argv[1]
  if command == nil or command == "help" then say(monitor_tool.USAGE); return 0 end

  local function unbound_candidates()
    local report = registry.verify()
    return report.unbound
  end

  -- the operator picks the screen that should get the id: a big number on every candidate
  local function pick(list)
    if #list == 0 then say("Kein freier Monitor angeschlossen."); return nil end
    if #list == 1 then
      registry.identify(list[1], "1")
      local answer = env.ask("Auf dem Monitor " .. list[1] .. " steht jetzt eine 1. Ist das der richtige? (j/n) ")
      if yes(answer) then return list[1] end
      say("Abgebrochen. Nichts gebunden.")
      return nil
    end
    for index, name in ipairs(list) do registry.identify(name, tostring(index)) end
    local answer = env.ask("Welche Zahl steht auf dem richtigen Monitor? (1-" .. #list .. ", n = Abbruch) ")
    local number = tonumber(answer or "")
    if not number or number ~= math.floor(number) or number < 1 or number > #list then
      say("Abgebrochen. Nichts gebunden.")
      return nil
    end
    return list[number]
  end

  if command == "list" then
    local report = registry.verify()
    for _, record in ipairs(registry.list()) do
      local group = registry.group_of(record.logical_id)
      say(record.logical_id .. "  " .. record.peripheral .. "  Ansicht " .. record.start_view .. "  Skala " .. tostring(record.scale) .. (group and ("  Gruppe " .. group) or "") .. (report.missing[record.logical_id] and "  FEHLT" or ""))
    end
    for _, name in ipairs(report.unbound) do say("(frei) " .. name) end
    if #registry.list() == 0 and #report.unbound == 0 then say("Keine Monitore.") end
    return 0
  elseif command == "check" then
    local report = registry.verify()
    for id, name in pairs(report.missing) do say("FEHLT: " .. id .. " (" .. name .. ") - mit 'replace " .. id .. "' neu binden") end
    for _, name in ipairs(report.unbound) do say("Nicht gebunden: " .. name) end
    if report.ok then say("Alle Monitore sind gebunden und da.") end
    return report.ok and 0 or 1
  elseif command == "bind" or command == "replace" then
    local id = argv[2]
    if not id then say("Welche ID? Beispiel: bind LEIT-1"); return 1 end
    if command == "bind" and registry.get(id) then say(id .. " ist schon gebunden. Mit 'replace " .. id .. "' ersetzen."); return 1 end
    if command == "replace" and not registry.get(id) then say(id .. " ist nicht gebunden. Mit 'bind " .. id .. "' anlegen."); return 1 end
    local view, scale = argv[3], tonumber(argv[4] or "")
    if view and not monitor_registry.VIEWS[view] then say("Unbekannte Ansicht " .. view .. ". Moeglich: " .. views_text()); return 1 end
    local name = pick(unbound_candidates())
    if not name then return 1 end
    if not yes(env.ask("Monitor " .. name .. " wirklich an " .. id .. " binden? (j/n) ")) then say("Abgebrochen. Nichts gebunden."); return 1 end
    local meta = { confirmed = true, start_view = view, scale = scale, label = id }
    local ok, err
    if command == "bind" then ok, err = registry.bind(id, name, meta) else ok, err = registry.replace(id, name, meta) end
    if not ok then say("Nicht gebunden: " .. tostring(err)); return 1 end
    registry.identify(name, id)
    say(id .. " ist an " .. name .. " gebunden.")
    return 0
  elseif command == "unbind" then
    local id = argv[2]
    if not id or not registry.get(id) then say("Diese ID ist nicht gebunden."); return 1 end
    if not yes(env.ask(id .. " wirklich loeschen? (j/n) ")) then say("Abgebrochen."); return 1 end
    local ok, err = registry.unbind(id)
    if not ok then say("Nicht geloescht: " .. tostring(err)); return 1 end
    say(id .. " ist nicht mehr gebunden.")
    return 0
  elseif command == "label" then
    local id, text = argv[2], argv[3]
    if not id or not text then say("label <ID> <Text>"); return 1 end
    if not registry.set_label(id, text) then say("Nicht gesetzt."); return 1 end
    return 0
  elseif command == "scale" then
    local ok, err = registry.set_scale(argv[2], tonumber(argv[3] or ""))
    if not ok then say("Nicht gesetzt: " .. tostring(err or "Skala 0.5 bis 5 in Halbschritten")); return 1 end
    return 0
  elseif command == "view" then
    local ok, err = registry.set_start_view(argv[2], argv[3])
    if not ok then say("Nicht gesetzt: " .. tostring(err or "Ansicht " .. tostring(argv[3]))); return 1 end
    return 0
  elseif command == "group" then
    local members = {}
    for index = 3, #argv do members[#members + 1] = argv[index] end
    local ok, err = registry.define_group(argv[2], members)
    if not ok then say("Keine Gruppe: " .. tostring(err)); return 1 end
    say("Gruppe " .. argv[2] .. ": " .. table.concat(members, ", ") .. " (teilen nur Zug, Station, Abschnitt)")
    return 0
  elseif command == "ungroup" then
    if not registry.dissolve_group(argv[2]) then say("Diese Gruppe gibt es nicht."); return 1 end
    return 0
  end
  say("Unbekannter Befehl '" .. tostring(command) .. "'.\n" .. monitor_tool.USAGE)
  return 1
end

return monitor_tool
