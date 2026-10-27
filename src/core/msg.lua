--[[
Purpose: Nachrichtenumschlag nach Konzept 13.2 und Empfangsregeln: Felder bauen und pruefen, Wiederholungen erkennen, alte Zentralenlaeufe abweisen, Luecken in der Folge melden, wiederholte Auftraege mit demselben Ergebnis beantworten (13.3).
API: msg.new{node_id, boot_id, epoch} -> factory mit make(type, target, payload, extra); msg.validate(m) -> ok, grund; msg.inbox{node_id, central_id, max_seen} -> inbox mit accept(m), epoch(), reply_for(id), remember(id, reply)
Notes: messageId = Absender:Start:Zaehler (Start = Boot-Kennung der Betriebsuhr), damit sie auch nach einem Neustart nie doppelt vorkommt. Eine technische Bestaetigung (bestaetigung mit payload.kind = "ack") heisst nur "verarbeitbar"; die fachliche Antwort steht in payload.status (angenommen, zurueckgestellt, abgelehnt). Keine Kryptografie (Konzept 13.5).
]]

local M = {}

M.PROTOCOL = 1

local TYPES = { meldung = true, auftrag = true, bestaetigung = true, abfrage = true }
M.TYPES = TYPES

local function nonempty(v) return type(v) == "string" and #v > 0 and #v <= 64 end
local function int(v) return type(v) == "number" and v == math.floor(v) and v >= 0 end
local function optional_id(v) return v == nil or type(v) == "string" or type(v) == "number" end

function M.validate(m)
  if type(m) ~= "table" then return false, "keine Tabelle" end
  if m.protocolVersion ~= M.PROTOCOL then return false, "protocolVersion" end
  if not nonempty(m.messageId) then return false, "messageId" end
  if not nonempty(m.senderNodeId) then return false, "senderNodeId" end
  if not nonempty(m.targetNodeId) then return false, "targetNodeId" end
  if not TYPES[m.messageType] then return false, "messageType" end
  if not int(m.sequence) then return false, "sequence" end
  if not int(m.centralEpoch) then return false, "centralEpoch" end
  if type(m.payload) ~= "table" then return false, "payload" end
  if not optional_id(m.correlationId) then return false, "correlationId" end
  if not optional_id(m.requestId) then return false, "requestId" end
  if not optional_id(m.configRevision) then return false, "configRevision" end
  return true
end

-- Fabrik fuer ausgehende Nachrichten eines Nodes
function M.new(opts)
  local f = { node_id = opts.node_id }
  local counter, sequence = 0, 0
  local function epoch()
    if type(opts.epoch) == "function" then return opts.epoch() end
    return opts.epoch or 0
  end
  function f.make(message_type, target, payload, extra)
    counter = counter + 1
    sequence = sequence + 1
    local m = {
      protocolVersion = M.PROTOCOL,
      messageId = opts.node_id .. ":" .. tostring(opts.boot_id) .. ":" .. counter,
      senderNodeId = opts.node_id,
      targetNodeId = target,
      centralEpoch = epoch(),
      sequence = sequence,
      messageType = message_type,
      payload = payload or {},
    }
    if extra then
      m.correlationId = extra.correlationId
      m.requestId = extra.requestId
      m.configRevision = extra.configRevision
    end
    return m
  end
  return f
end

local function boot_of(message_id)
  return message_id:match("^[^:]*:([^:]*):%d+$")
end

-- Empfangsseite: entscheidet je Nachricht, ob sie verarbeitet werden darf
function M.inbox(opts)
  local box = {}
  local max_seen = opts.max_seen or 300
  local seen, seen_order = {}, {}
  local replies, reply_order = {}, {}
  local last = {}                       -- Absender -> { boot, sequence }
  local known_epoch = opts.epoch or 0

  local function remember_seen(id)
    seen[id] = true
    seen_order[#seen_order + 1] = id
    if #seen_order > max_seen then seen[table.remove(seen_order, 1)] = nil end
  end

  function box.epoch() return known_epoch end

  function box.reply_for(id) return replies[id] end

  function box.remember(id, reply)
    replies[id] = reply
    reply_order[#reply_order + 1] = id
    if #reply_order > max_seen then replies[table.remove(reply_order, 1)] = nil end
  end

  -- liefert status, zusatz: ok | duplicate | invalid | wrong_target | stale_epoch | old_sequence
  -- Zusatz bei ok: { gap = Anzahl fehlender Nachrichten, late_epoch = true }
  function box.accept(m)
    local ok, why = M.validate(m)
    if not ok then return "invalid", why end
    if m.targetNodeId ~= opts.node_id and m.targetNodeId ~= "*" then return "wrong_target" end
    if seen[m.messageId] then return "duplicate" end
    local from_central = (opts.central_id ~= nil and m.senderNodeId == opts.central_id)
    if m.centralEpoch < known_epoch and (m.messageType == "auftrag" or from_central) then
      -- alte Nachrichten aus einem frueheren Zentralenlauf bewirken nichts Neues
      remember_seen(m.messageId)
      return "stale_epoch"
    end
    local extra = {}
    if m.centralEpoch < known_epoch then extra.late_epoch = true end
    local boot = boot_of(m.messageId)
    local prev = last[m.senderNodeId]
    if prev and prev.boot == boot then
      if m.sequence <= prev.sequence then
        remember_seen(m.messageId)
        return "old_sequence"
      end
      if m.sequence > prev.sequence + 1 then extra.gap = m.sequence - prev.sequence - 1 end
    end
    last[m.senderNodeId] = { boot = boot, sequence = m.sequence }
    remember_seen(m.messageId)
    if from_central and m.centralEpoch > known_epoch then known_epoch = m.centralEpoch end
    return "ok", extra
  end

  return box
end

return M
