--[[
Purpose: The network plan (one JSON file that describes computers, blocks and routes) as the setup wizard handles it: find, read, check,
  build the entry of one computer, write a short plan, print it the way people edit it.
Public API:
  PATH -> "configs/network.json"        DEFAULT_CHANNEL -> 777        DEFAULT_MASTER -> "MASTER-1"
  parse(text) -> cfg, errors | nil, nil, err    errors: list of validation messages or nil when the plan is valid
  explain(message, cfg) -> text                 one validation message in German ("channel: ganze Zahl groesser 0 noetig"); with the plan
                                                the position gets the id: "nodes[2] (SIG-2).role: ..."
  MONITOR_ROLES -> set of roles that show something on a monitor
  summary(cfg) -> { computers, blocks, routes, channel, master_id }       text(summary) -> "17 Computer, 3 Bloecke, 3 Routen"
  short_text(summary) -> "17 Computer, 3 Bloecke"
  examples(files) -> list of { path, name, summary, note }               files.list(dir), files.read(path)
  nodes_of_role(cfg, role) -> list of entries      find_node(cfg, id) -> entry | nil
  suggest_id(role, cfg) -> "SIG-2"                 valid_id(id) -> true | false, message
  build_entry(role, id, fields) -> entry           fields: adapter, peripheral, side, invert, active_position, display_name,
                                                   station_type, create_station_name, depot_type, create_station, monitor, modem
  short_plan(role, entry, channel, master_id) -> cfg      this computer and the master, valid on its own
  add_node(cfg, entry) -> cfg (copy)             set_fields(cfg, id, fields) -> cfg (copy)   fields {modem, monitor} of one entry
  encode(cfg) -> text (stable key order, one line per computer)       inline(entry) -> one line of JSON
  entry_lines(entry, width) -> the entry as short lines for a screen
Notes: pure functions; reading and writing files is the caller's business (files object), so the wizard can run against a made-up disk.
]]

local json = require("src.shared.json")
local validate = require("src.shared.validate")

local netplan = {}

netplan.PATH = "configs/network.json"
netplan.DEFAULT_CHANNEL = 777
netplan.DEFAULT_MASTER = "MASTER-1"

local EXAMPLE_NOTES = {
  ["network.example.json"] = "kleinster Start, 1 Block",
  ["network.redstone.example.json"] = "wie oben, alles per Redstone",
  ["network.full.example.json"] = "alles: Bahnhoefe, Depot, Fahrplan",
  ["network.create.example.json"] = "mit Create-Geraeten",
  ["network.mixed.example.json"] = "Create und Redstone gemischt",
  ["network.service_plan.example.json"] = "mit Fahrplan fuer einen Zug",
  ["network.station.example.json"] = "ein Bahnhof",
  ["network.depot.example.json"] = "ein Depot",
  ["network.train.example.json"] = "ein Zug",
  ["network.panel.example.json"] = "mit Bedien-Monitor",
}

netplan.MONITOR_ROLES = { master = true, panel = true, station = true, depot = true, train = true }

local ID_PREFIX = { master = "MASTER", signal = "SIG", sensor = "SEN", switch = "SW", station = "ST", depot = "DEPOT", train = "TRAIN", panel = "PANEL", arbiter = "ARB", fleet = "FLEET" }

-- readable files: the keys people look for come first, the rest alphabetically
local KEY_ORDER = {
  "v", "channel", "master_id", "nodes", "blocks", "routes", "service_plans",
  "id", "role", "display_name", "adapter", "peripheral", "side", "invert", "active_position",
  "station_type", "create_station_name", "depot_type", "create_station", "schedule_station", "modem", "monitor", "monitor_scale",
}
local KEY_RANK = {}
for i, key in ipairs(KEY_ORDER) do KEY_RANK[key] = i end

local function sorted_keys(t)
  local keys = {}
  for key in pairs(t) do keys[#keys + 1] = key end
  table.sort(keys, function(a, b)
    local ra, rb = KEY_RANK[a] or 1000, KEY_RANK[b] or 1000
    if ra ~= rb then return ra < rb end
    return tostring(a) < tostring(b)
  end)
  return keys
end

local function is_array(t)
  local n = 0
  for _ in pairs(t) do n = n + 1 end
  for i = 1, n do if t[i] == nil then return false end end
  return true
end

local function inline(value)
  local kind = type(value)
  if kind == "string" or kind == "number" or kind == "boolean" then return json.encode(value) end
  if kind == "table" then
    local parts = {}
    if is_array(value) then
      for _, item in ipairs(value) do parts[#parts + 1] = inline(item) end
      return "[" .. table.concat(parts, ", ") .. "]"
    end
    for _, key in ipairs(sorted_keys(value)) do parts[#parts + 1] = json.encode(tostring(key)) .. ": " .. inline(value[key]) end
    return "{" .. table.concat(parts, ", ") .. "}"
  end
  return "null"
end
netplan.inline = inline

function netplan.encode(cfg)
  local lines = { "{" }
  local keys = sorted_keys(cfg)
  for index, key in ipairs(keys) do
    local value = cfg[key]
    local comma = index < #keys and "," or ""
    if type(value) == "table" and is_array(value) and #value > 0 and type(value[1]) == "table" then
      lines[#lines + 1] = "  " .. json.encode(key) .. ": ["
      for i, item in ipairs(value) do lines[#lines + 1] = "    " .. inline(item) .. (i < #value and "," or "") end
      lines[#lines + 1] = "  ]" .. comma
    else
      lines[#lines + 1] = "  " .. json.encode(key) .. ": " .. inline(value) .. comma
    end
  end
  lines[#lines + 1] = "}"
  return table.concat(lines, "\n") .. "\n"
end

-- the entry as a few short lines (for a screen): {"id": ..., "role": ...,\n "adapter": ...}
function netplan.entry_lines(entry, width)
  local pairs_text = {}
  for _, key in ipairs(sorted_keys(entry)) do pairs_text[#pairs_text + 1] = json.encode(tostring(key)) .. ": " .. inline(entry[key]) end
  local lines, line = {}, "{"
  for i, item in ipairs(pairs_text) do
    local piece = item .. (i < #pairs_text and "," or "}")
    local candidate = line == "{" and ("{" .. piece) or (line .. " " .. piece)
    if #candidate > width and line ~= "{" and line ~= " " then
      lines[#lines + 1] = line
      line = " " .. piece
    else
      line = candidate
    end
  end
  lines[#lines + 1] = line
  return lines
end

-- ── the messages of the validator, in German ─────────────────────────────────────────────────────────────────────────
local KIND_WORD = { signal = "Signal", sensor = "Melder", switch = "Weichen", train = "Zug" }

local EXPLAIN = {
  { "^must be non%-empty string$", "Text fehlt oder ist leer" },
  { '^duplicate .- "(.*)"$', function(value) return 'doppelt vergeben: "' .. value .. '"' end },
  { "^must be an object$", "muss ein Objekt {} sein" },
  { "^unexpected structure %(", "der Aufbau stimmt nicht: eine Liste oder ein Eintrag hat die falsche Form" },
  { "^must be 1$", "muss 1 sein" },
  { "^must be integer > 0$", "ganze Zahl groesser 0 noetig" },
  { "^must be an array$", "muss eine Liste [] sein" },
  { "^must be a number >= 0$", "Zahl ab 0 noetig" },
  { "^must be number >= 0$", "Zahl ab 0 noetig" },
  { "^must be number$", "Zahl noetig" },
  { "^must be true or false$", "nur true oder false" },
  { '^invalid role "(.-)"$', function(role) return 'unbekannte Rolle "' .. role .. '"' end },
  { "^must be passenger, freight, or mixed$", "nur passenger, freight oder mixed" },
  { "^must be passenger, freight, mixed, or depot$", "nur passenger, freight, mixed oder depot" },
  { "^must be storage, staging, or mixed$", "nur storage, staging oder mixed" },
  { "^must be storage, staging, mixed, passenger, or freight$", "nur storage, staging, mixed, passenger oder freight" },
  { "^should define exact Create destination name for schedules$", "der Name des Bahnhofs in Create fehlt (create_station_name)" },
  { "^switch nodes require adapter=", 'Weichen brauchen adapter "redstone" (Vanilla-Create hat keine Weichen-Peripherie)' },
  { "^must reference node with role master$", "muss auf einen Eintrag mit der Rolle master zeigen" },
  { '^references unknown (%a+) node "(.-)"$', function(kind, value)
      if value == "nil" then return "Feld fehlt" end
      return "verweist auf einen " .. (KIND_WORD[kind] or kind) .. '-Eintrag, den es nicht gibt: "' .. value .. '"'
    end },
  { '^references unknown block "(.-)"$', function(value) return 'verweist auf einen Block, den es nicht gibt: "' .. value .. '"' end },
  { '^references unknown route "(.-)"$', function(value) return 'verweist auf eine Route, die es nicht gibt: "' .. value .. '"' end },
  { '^references unknown train "(.-)"$', function(value) return 'verweist auf einen Zug, den es nicht gibt: "' .. value .. '"' end },
  { '^references unknown service plan "(.-)"$', function(value) return 'verweist auf einen Fahrplan, den es nicht gibt: "' .. value .. '"' end },
  { '^references unknown station/depot "(.-)"', function(value) return 'verweist auf einen Bahnhof oder ein Depot, das es nicht gibt: "' .. value .. '"' end },
  { "^must contain at least one block$", "mindestens ein Block noetig" },
  { "^must contain at least one stop$", "mindestens ein Halt noetig" },
  { "^must provide route_id or from/to$", "route_id oder from/to noetig" },
  { "^must define at least one block$", "mindestens ein Block noetig" },
  { "^must define entry_signal for interlocking route$", "entry_signal fehlt" },
  { "^must not be a block of the route itself$", "darf nicht zur Route selbst gehoeren" },
  { "^sensor (.-) already used by block (.+)$", function(sensor, block) return "Melder " .. sensor .. " gehoert schon zu Block " .. block end },
}

local unpack_fn = table.unpack or unpack

function netplan.explain(message, cfg)
  local text = tostring(message)
  local path, rest = text:match("^(.-): (.*)$")
  if not path then return text end
  local shown = rest
  for _, rule in ipairs(EXPLAIN) do
    local found = { rest:find(rule[1]) }
    if found[1] then
      local replacement = rule[2]
      if type(replacement) == "function" then
        shown = replacement(unpack_fn(found, 3))
      else
        shown = replacement
      end
      break
    end
  end
  -- the position with the id of the entry: nodes[2] -> nodes[2] (SIG-2)
  if cfg then
    path = path:gsub("^(%a+)%[(%d+)%]", function(list, index)
      local item = type(cfg[list]) == "table" and cfg[list][tonumber(index)]
      if type(item) == "table" and type(item.id) == "string" then return list .. "[" .. index .. "] (" .. item.id .. ")" end
      return list .. "[" .. index .. "]"
    end)
  end
  return path .. ": " .. shown
end

function netplan.parse(text)
  local ok, cfg = pcall(json.decode, tostring(text or ""))
  if not ok or type(cfg) ~= "table" then return nil, nil, "keine gueltige JSON-Datei" end
  local valid, errors = validate.validate_config(cfg)
  if valid then return cfg, nil end
  return cfg, errors
end

function netplan.summary(cfg)
  return {
    computers = #(cfg.nodes or {}), blocks = #(cfg.blocks or {}), routes = #(cfg.routes or {}),
    channel = cfg.channel, master_id = cfg.master_id,
  }
end

function netplan.text(summary)
  return string.format("%d Computer, %d %s, %d %s", summary.computers, summary.blocks, summary.blocks == 1 and "Block" or "Bloecke",
    summary.routes, summary.routes == 1 and "Route" or "Routen")
end

-- "5 Computer, 3 Bloecke": short enough for a menu line
function netplan.short_text(summary)
  return string.format("%d Computer, %d %s", summary.computers, summary.blocks, summary.blocks == 1 and "Block" or "Bloecke")
end

function netplan.examples(files)
  local out = {}
  local dir = "configs/templates"
  for _, name in ipairs(files.list(dir)) do
    if name:match("^network%..*%.json$") then
      local text = files.read(dir .. "/" .. name)
      local cfg, errors = netplan.parse(text or "")
      if cfg and not errors then
        out[#out + 1] = { path = dir .. "/" .. name, name = name, summary = netplan.summary(cfg), note = EXAMPLE_NOTES[name] }
      end
    end
  end
  table.sort(out, function(a, b)
    if a.summary.computers ~= b.summary.computers then return a.summary.computers < b.summary.computers end
    return a.name < b.name
  end)
  return out
end

function netplan.nodes_of_role(cfg, role)
  local out = {}
  for _, node in ipairs(cfg.nodes or {}) do if node.role == role then out[#out + 1] = node end end
  return out
end

function netplan.find_node(cfg, id)
  for _, node in ipairs(cfg.nodes or {}) do if node.id == id then return node end end
  return nil
end

function netplan.suggest_id(role, cfg)
  local prefix = ID_PREFIX[role] or role:upper()
  local n = 1
  while cfg and netplan.find_node(cfg, prefix .. "-" .. n) do n = n + 1 end
  return prefix .. "-" .. n
end

function netplan.valid_id(id)
  if type(id) ~= "string" or id == "" then return false, "Bitte eine ID eingeben." end
  if #id > 32 then return false, "Hoechstens 32 Zeichen." end
  if not id:match("^[%w_%-%.]+$") then return false, "Nur Buchstaben, Ziffern und _ - . (keine Leerzeichen, keine Umlaute)." end
  return true
end

function netplan.build_entry(role, id, f)
  local entry = { id = id, role = role }
  if role == "signal" and type(f.signals) == "table" and #f.signals > 0 then
    -- several signals on one computer (docs/SIGNAL_NODES.md): the logical ids; which peripheral is which is bound on the computer (scripts/bind_signals.lua)
    entry.signals = {}
    for i, signal_id in ipairs(f.signals) do entry.signals[i] = signal_id end
  elseif role == "signal" or role == "sensor" then
    entry.adapter = f.adapter or "peripheral"
    if entry.adapter == "redstone" then entry.side = f.side else entry.peripheral = f.peripheral end
  elseif role == "switch" then
    entry.adapter = "redstone"
    entry.side = f.side
    entry.active_position = f.active_position or "DIVERGING"
    if f.invert then entry.invert = true end
  elseif role == "station" then
    entry.station_type = f.station_type or "passenger"
    entry.display_name = f.display_name or id
    entry.create_station_name = f.create_station_name or entry.display_name
  elseif role == "depot" then
    entry.depot_type = f.depot_type or "mixed"
    entry.display_name = f.display_name or id
  elseif role == "train" then
    entry.display_name = f.display_name or id
    if f.create_station and f.create_station ~= "" then
      entry.create_station = f.create_station
      entry.schedule_station = f.create_station
    end
  elseif role == "panel" then
    entry.display_name = f.display_name or id
  end
  -- the devices this computer uses, written only when they were chosen (one modem / one monitor are found by themselves)
  if f.modem and f.modem ~= "" then entry.modem = f.modem end
  if f.monitor and f.monitor ~= "" and netplan.MONITOR_ROLES[role] then entry.monitor = f.monitor end
  return entry
end

function netplan.short_plan(role, entry, channel, master_id)
  local nodes = {}
  local master = role == "master" and entry or { id = master_id, role = "master" }
  nodes[1] = master
  if role ~= "master" then nodes[2] = entry end
  return { v = 1, channel = channel, master_id = master.id, nodes = nodes, blocks = {}, routes = {} }
end

-- the entry with this id gets the given fields (nil values are left as they are); the rest of the plan is shared with the original
function netplan.set_fields(cfg, id, fields)
  local copy = {}
  for key, value in pairs(cfg) do copy[key] = value end
  copy.nodes = {}
  for _, node in ipairs(cfg.nodes or {}) do
    if node.id == id then
      local changed = {}
      for key, value in pairs(node) do changed[key] = value end
      for key, value in pairs(fields or {}) do if value ~= nil then changed[key] = value end end
      copy.nodes[#copy.nodes + 1] = changed
    else
      copy.nodes[#copy.nodes + 1] = node
    end
  end
  return copy
end

function netplan.add_node(cfg, entry)
  local copy = {}
  for key, value in pairs(cfg) do copy[key] = value end
  copy.nodes = {}
  for _, node in ipairs(cfg.nodes or {}) do copy.nodes[#copy.nodes + 1] = node end
  copy.nodes[#copy.nodes + 1] = entry
  return copy
end

return netplan
