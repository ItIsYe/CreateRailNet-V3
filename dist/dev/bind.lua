--[[
Purpose: Geraetebindung: welcher Anschluss gehoert zu welcher fachlichen Kennung (Gleis, Signal ...). Pruefung gegen einen Scan (vorhanden, richtiger Typ, benoetigte Methoden), nicht zugeordnete Geraete, Ersatz eines Geraets unter neuem Anschlussnamen.
API: bind.check(devices_config, scan) -> { [id] = { status, detail } }; bind.unbound(devices_config, scan) -> Liste; bind.rebind(devices_config, id, anschluss, scan) -> true | nil, grund; bind.routes(devices_config) -> { [anschluss] = { id, kind } }
Notes: status: "ok", "fehlt" (Anschluss nicht da), "falscher_typ", "methoden_fehlen". Ein Fund ist keine Gleiszuordnung (Konzept 15.1): die Zuordnung steht in der Konfiguration und wird vom Menschen bestaetigt.
]]

local detect = require("dev.detect")

local M = {}

function M.check(config, scan)
  local out = {}
  for id, spec in pairs(config) do
    local def = detect.KINDS[spec.kind]
    local device = detect.find(scan, spec.device)
    if not def then
      out[id] = { status = "falscher_typ", detail = "unbekannte Art " .. tostring(spec.kind) }
    elseif not device then
      out[id] = { status = "fehlt", detail = spec.device }
    elseif device.kind ~= spec.kind then
      out[id] = { status = "falscher_typ", detail = spec.device .. " ist " .. table.concat(device.types, ",") .. ", erwartet " .. def.type }
    else
      local missing = detect.missing(spec.kind, device)
      if #missing > 0 then
        out[id] = { status = "methoden_fehlen", detail = table.concat(missing, ",") }
      else
        out[id] = { status = "ok" }
      end
    end
  end
  return out
end

function M.unbound(config, scan)
  local used = {}
  for _, spec in pairs(config) do used[spec.device] = true end
  local out = {}
  for _, d in ipairs(scan) do
    if d.kind and (d.kind == "station" or d.kind == "signal" or d.kind == "observer") and not used[d.name] then out[#out + 1] = d end
  end
  return out
end

function M.rebind(config, id, device_name, scan)
  local spec = config[id]
  if not spec then return nil, "unbekannte Kennung" end
  local device = detect.find(scan, device_name)
  if not device then return nil, "Geraet nicht gefunden" end
  if device.kind ~= spec.kind then return nil, "falsche Art: " .. table.concat(device.types, ",") end
  if #detect.missing(spec.kind, device) > 0 then return nil, "Methoden fehlen" end
  for other_id, other in pairs(config) do
    if other_id ~= id and other.device == device_name then return nil, "Geraet gehoert schon zu " .. other_id end
  end
  spec.device = device_name
  return true
end

function M.routes(config)
  local out = {}
  for id, spec in pairs(config) do out[spec.device] = { id = id, kind = spec.kind } end
  return out
end

return M
