--[[
Purpose: The network plan (one JSON file that describes computers, blocks and routes) as the setup wizard handles it: find, read, check,
  build the entry of one computer, write a short plan, print it the way people edit it.
Public API:
  PATH -> "configs/network.json"        DEFAULT_CHANNEL -> 777        DEFAULT_MASTER -> "MASTER-1"
  parse(text) -> cfg, errors | nil, nil, err    errors: list of validation messages or nil when the plan is valid
  summary(cfg) -> { computers, blocks, routes, channel, master_id }       text(summary) -> "17 Computer, 3 Bloecke, 3 Routen"
  short_text(summary) -> "17 Computer, 3 Bloecke"
  examples(files) -> list of { path, name, summary, note }               files.list(dir), files.read(path)
  nodes_of_role(cfg, role) -> list of entries      find_node(cfg, id) -> entry | nil
  suggest_id(role, cfg) -> "SIG-2"                 valid_id(id) -> true | false, message
  build_entry(role, id, fields) -> entry           fields: adapter, peripheral, side, invert, active_position, display_name,
                                                   station_type, create_station_name, depot_type, create_station, monitor
  short_plan(role, entry, channel, master_id) -> cfg      this computer and the master, valid on its own
  add_node(cfg, entry) -> cfg (copy)
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

local ID_PREFIX = { master = "MASTER", signal = "SIG", sensor = "SEN", switch = "SW", station = "ST", depot = "DEPOT", train = "TRAIN", panel = "PANEL" }

-- readable files: the keys people look for come first, the rest alphabetically
local KEY_ORDER = {
  "v", "channel", "master_id", "nodes", "blocks", "routes", "service_plans",
  "id", "role", "display_name", "adapter", "peripheral", "side", "invert", "active_position",
  "station_type", "create_station_name", "depot_type", "create_station", "schedule_station", "monitor",
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
  if role == "signal" or role == "sensor" then
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
    if f.monitor and f.monitor ~= "" then entry.monitor = f.monitor end
  end
  return entry
end

function netplan.short_plan(role, entry, channel, master_id)
  local nodes = {}
  local master = role == "master" and entry or { id = master_id, role = "master" }
  nodes[1] = master
  if role ~= "master" then nodes[2] = entry end
  return { v = 1, channel = channel, master_id = master.id, nodes = nodes, blocks = {}, routes = {} }
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
