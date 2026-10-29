--[[
Purpose: Funkverkehr zwischen Nodes ueber rednet mit dem Umschlag aus core/msg: Modems waehlen (Funk fuer Computer untereinander, Kabel nur als Notloesung), senden, empfangen, Gegenstellen lernen, doppelte Besetzung einer Node erkennen, auf Auftraege fachlich antworten.
API: net.open(env) -> info; net.new{rednet, factory, inbox, clock, protocol} -> n; n.send(node_id, m); n.broadcast(m); n.receive(event) -> m, status, zusatz; n.reply(m, status, payload)
Notes: Rednet ist weder Anmeldung noch Verschluesselung (Konzept 13.5): geprueft werden nur bekannte Node-Kennungen und zulaessige Nachrichtentypen. Ein Funkmodem macht entfernte Create-Bloecke nicht zu lokalen Geraeten.
]]

local ser = require("core.ser")
local msg = require("core.msg")

local M = {}

local MAX_TEXT = 6000
local CONFLICT_WINDOW = 30      -- Sekunden Betriebszeit: zwei Computer mit derselben Node-Kennung

-- oeffnet rednet auf den Funkmodems; ohne Funk auf dem Kabelmodem (mit Hinweis)
function M.open(env)
  local info = { wireless = {}, wired = {}, opened = {} }
  for _, name in ipairs(env.peripheral.getNames()) do
    if env.peripheral.getType(name) == "modem" then
      local ok, wireless = pcall(env.peripheral.call, name, "isWireless")
      if ok and wireless then info.wireless[#info.wireless + 1] = name else info.wired[#info.wired + 1] = name end
    end
  end
  table.sort(info.wireless); table.sort(info.wired)
  for _, name in ipairs(info.wireless) do
    env.rednet.open(name)
    info.opened[#info.opened + 1] = name
  end
  if #info.opened == 0 and #info.wired > 0 then
    env.rednet.open(info.wired[1])
    info.opened[1] = info.wired[1]
    info.fallback = true
  end
  return info
end

function M.new(opts)
  local n = {}
  local protocol = opts.protocol or "crn1"
  local peers = {}                    -- node_id -> { cid, last }
  local conflicts = 0

  local function encode(m)
    local text = ser.encode(m)
    if #text > MAX_TEXT then error("net: Nachricht zu gross (" .. #text .. " Zeichen)", 0) end
    return text
  end

  function n.peer(node_id) return peers[node_id] and peers[node_id].cid end
  function n.conflicts() return conflicts end

  function n.send(node_id, m)
    local cid = n.peer(node_id)
    local text = encode(m)
    if cid then
      opts.rednet.send(cid, text, protocol)
      return "gerichtet"
    end
    opts.rednet.broadcast(text, protocol)
    return "rundruf"
  end

  function n.broadcast(m)
    opts.rednet.broadcast(encode(m), protocol)
  end

  -- event = { "rednet_message", absender_computer, text, protokoll }
  function n.receive(event)
    if event[1] ~= "rednet_message" or event[4] ~= protocol then return nil end
    local m = ser.decode(event[3])
    if m == nil then return nil, "invalid", "nicht lesbar" end
    local status, extra = opts.inbox.accept(m)
    if status == "ok" or status == "duplicate" then
      local now = opts.clock.now()
      local known = peers[m.senderNodeId]
      if known and known.cid ~= event[2] and now - known.last < CONFLICT_WINDOW then
        conflicts = conflicts + 1
        return m, "node_conflict", { node = m.senderNodeId, first = known.cid, second = event[2] }
      end
      peers[m.senderNodeId] = { cid = event[2], last = now }
    end
    if status == "duplicate" then
      -- wiederholter Auftrag: bekannte Antwort noch einmal senden, nichts neu ausfuehren
      local known_reply = opts.inbox.reply_for(m.messageId)
      if known_reply then
        n.send(m.senderNodeId, known_reply)
        return m, status, { resent = true }
      end
    end
    return m, status, extra
  end

  -- fachliche Antwort auf eine Nachricht; wird fuer wiederholte Anfragen gemerkt
  function n.reply(m, status, payload)
    local body = { kind = "antwort", status = status }
    for k, v in pairs(payload or {}) do body[k] = v end
    local reply = opts.factory.make("bestaetigung", m.senderNodeId, body, { correlationId = m.messageId, requestId = m.requestId })
    opts.inbox.remember(m.messageId, reply)
    n.send(m.senderNodeId, reply)
    return reply
  end

  -- technische Empfangsbestaetigung ("verarbeitbar"), keine fachliche Antwort
  function n.ack(m)
    local ack = opts.factory.make("bestaetigung", m.senderNodeId, { kind = "ack" }, { correlationId = m.messageId })
    n.send(m.senderNodeId, ack)
    return ack
  end

  return n
end

return M
