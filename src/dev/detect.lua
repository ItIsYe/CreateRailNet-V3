--[[
Purpose: Geraete am Computer erkennen: Name, Typen und Methoden jedes Peripherals (auch Mehrfach-Typen wie "modem, peripheral_hub"), Einordnung in die Arten des Konzepts (Bahnhof, Signal, Beobachter, Anzeige ...), Vergleich mit den Methoden, die das Konzept erwartet (A01), Unterschied zwischen zwei Scans. Es wird nichts geschaltet.
API: detect.scan(peripheral) -> Liste { name, types, type, kind, methods = {name=true} }; detect.missing(kind, device) -> Liste fehlender Methoden; detect.diff(old, new) -> hinzugekommen, verschwunden; detect.summary(list) -> Zeilen; detect.KINDS
Notes: Alle Aufrufe sind geschuetzt: ein Geraet, das waehrend des Scans verschwindet, bricht den Scan nicht ab. Ein gefundenes Geraet ist noch keinem Gleis zugeordnet (Konzept 18.1).
]]

local M = {}

-- Peripheral-Typ -> Art (Konzept 18.2); Methodenlisten aus Konzept Kapitel 19 und 20, geprueft mit dem Messprogramm (docs/MESSWERTE.md, M03)
M.KINDS = {
  station = {
    type = "Create_Station",
    methods = { "getStationName", "setStationName", "isTrainPresent", "isTrainImminent", "isTrainEnroute", "getTrainName", "setTrainName",
      "hasSchedule", "getSchedule", "setSchedule", "canTrainReach", "distanceTo", "isInAssemblyMode", "setAssemblyMode", "assemble", "disassemble" },
  },
  signal = {
    type = "Create_Signal",
    methods = { "getState", "isForcedRed", "setForcedRed", "getSignalType", "cycleSignalType", "listBlockingTrainNames" },
  },
  observer = {
    type = "Create_TrainObserver",
    methods = { "isTrainPassing", "getPassingTrainName" },
  },
  displaylink = { type = "Create_DisplayLink", methods = { "setCursorPos", "getCursorPos", "getSize", "write", "clearLine", "clear", "update" } },
  monitor = { type = "monitor", methods = { "getSize", "setCursorPos", "write", "clear", "setTextColour", "setBackgroundColour" } },
  modem = { type = "modem", methods = { "isWireless", "open", "close", "transmit" } },
  relay = { type = "redstone_relay", methods = { "getInput", "setOutput", "getOutput" } },
}

local TYPE_TO_KIND = {}
for kind, def in pairs(M.KINDS) do TYPE_TO_KIND[def.type] = kind end

local function sorted_copy(list)
  local out = {}
  for _, v in ipairs(list) do out[#out + 1] = v end
  table.sort(out)
  return out
end

function M.scan(peripheral)
  local devices = {}
  local ok, names = pcall(peripheral.getNames)
  if not ok or type(names) ~= "table" then return devices end
  for _, name in ipairs(sorted_copy(names)) do
    local types = {}
    local packed = { pcall(peripheral.getType, name) }
    if packed[1] then
      for i = 2, #packed do
        if type(packed[i]) == "string" then types[#types + 1] = packed[i] end
      end
    end
    if #types > 0 then
      local methods = {}
      local mok, list = pcall(peripheral.getMethods, name)
      if mok and type(list) == "table" then
        for _, m in ipairs(list) do methods[m] = true end
      end
      local kind
      for _, ty in ipairs(types) do kind = kind or TYPE_TO_KIND[ty] end
      devices[#devices + 1] = { name = name, types = types, type = types[1], kind = kind, methods = methods }
    end
  end
  return devices
end

function M.missing(kind, device)
  local def = M.KINDS[kind]
  local out = {}
  if not def then return out end
  for _, method in ipairs(def.methods) do
    if not device.methods[method] then out[#out + 1] = method end
  end
  return out
end

function M.find(devices, name)
  for _, d in ipairs(devices) do if d.name == name then return d end end
end

function M.diff(old, new)
  local before, after = {}, {}
  for _, d in ipairs(old) do before[d.name] = d end
  for _, d in ipairs(new) do after[d.name] = d end
  local added, removed = {}, {}
  for name in pairs(after) do if not before[name] then added[#added + 1] = name end end
  for name in pairs(before) do if not after[name] then removed[#removed + 1] = name end end
  table.sort(added); table.sort(removed)
  return added, removed
end

-- Zeilen fuer Anzeige und Assistent: Art, Name, Typen; fehlende erwartete Methoden werden genannt
function M.summary(devices)
  local lines = {}
  for _, d in ipairs(devices) do
    local line = string.format("%-24s %s", d.name, table.concat(d.types, ","))
    if d.kind and (d.kind == "station" or d.kind == "signal" or d.kind == "observer") then
      local missing = M.missing(d.kind, d)
      if #missing > 0 then line = line .. "  fehlt: " .. table.concat(missing, ",") end
    end
    lines[#lines + 1] = line
  end
  return lines
end

return M
