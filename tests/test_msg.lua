--[[
Purpose: Nachrichtenumschlag und Empfangsregeln (src/core/msg.lua): Felder, Pruefung, eindeutige IDs ueber Neustarts, Duplikate, falsches Ziel, alte Zentralenlaeufe, Luecken, alte Reihenfolge, gemerkte Antworten.
]]

local t = dofile("tests/lib/t.lua")
local msg = require("core.msg")

local function pair(epoch)
  local f = msg.new({ node_id = "bahnhof-1", boot_id = 1, epoch = epoch or 0 })
  local box = msg.inbox({ node_id = "zentrale-1", central_id = "zentrale-1" })
  return f, box
end

return {
  { "Umschlag enthaelt alle Felder aus Konzept 13.2", function()
    local f = msg.new({ node_id = "bahnhof-1", boot_id = 3, epoch = 7 })
    local m = f.make("auftrag", "zentrale-1", { kind = "x" }, { requestId = "R1", correlationId = "C1", configRevision = 4 })
    t.eq(m.protocolVersion, 1)
    t.eq(m.messageId, "bahnhof-1:3:1")
    t.eq(m.senderNodeId, "bahnhof-1")
    t.eq(m.targetNodeId, "zentrale-1")
    t.eq(m.centralEpoch, 7)
    t.eq(m.sequence, 1)
    t.eq(m.messageType, "auftrag")
    t.eq(m.correlationId, "C1")
    t.eq(m.requestId, "R1")
    t.eq(m.configRevision, 4)
    t.eq(m.payload.kind, "x")
    t.eq(f.make("meldung", "*", {}).sequence, 2)
  end },
  { "Epoche kann eine Funktion sein", function()
    local e = 1
    local f = msg.new({ node_id = "a", boot_id = 1, epoch = function() return e end })
    t.eq(f.make("meldung", "*", {}).centralEpoch, 1)
    e = 2
    t.eq(f.make("meldung", "*", {}).centralEpoch, 2)
  end },
  { "IDs sind ueber Neustarts eindeutig", function()
    local a = msg.new({ node_id = "n", boot_id = 1 }).make("meldung", "*", {})
    local b = msg.new({ node_id = "n", boot_id = 2 }).make("meldung", "*", {})
    t.ok(a.messageId ~= b.messageId)
  end },
  { "Pruefung weist unbrauchbare Nachrichten ab", function()
    local f = msg.new({ node_id = "a", boot_id = 1 })
    local good = f.make("meldung", "b", {})
    t.eq(msg.validate(good), true)
    local function bad(mutate, part)
      local m = f.make("meldung", "b", {})
      mutate(m)
      local ok, why = msg.validate(m)
      t.eq(ok, false, part)
      t.eq(why, part)
    end
    bad(function(m) m.protocolVersion = 2 end, "protocolVersion")
    bad(function(m) m.messageId = "" end, "messageId")
    bad(function(m) m.senderNodeId = 5 end, "senderNodeId")
    bad(function(m) m.targetNodeId = nil end, "targetNodeId")
    bad(function(m) m.messageType = "befehl" end, "messageType")
    bad(function(m) m.sequence = -1 end, "sequence")
    bad(function(m) m.sequence = 1.5 end, "sequence")
    bad(function(m) m.centralEpoch = "1" end, "centralEpoch")
    bad(function(m) m.payload = "x" end, "payload")
    bad(function(m) m.requestId = {} end, "requestId")
    t.eq(msg.validate("text"), false)
    t.eq(msg.validate(nil), false)
  end },
  { "Duplikat wird erkannt", function()
    local f, box = pair()
    local m = f.make("meldung", "zentrale-1", {})
    t.eq((box.accept(m)), "ok")
    t.eq((box.accept(m)), "duplicate")
  end },
  { "falsches Ziel, Rundruf geht an alle", function()
    local f, box = pair()
    t.eq((box.accept(f.make("meldung", "depot-9", {}))), "wrong_target")
    t.eq((box.accept(f.make("meldung", "*", {}))), "ok")
  end },
  { "ungueltige Nachricht liefert den Grund", function()
    local f, box = pair()
    local m = f.make("meldung", "zentrale-1", {})
    m.sequence = -4
    local status, why = box.accept(m)
    t.eq(status, "invalid")
    t.eq(why, "sequence")
  end },
  { "alter Zentralenlauf: Auftraege und Zentralen-Nachrichten wirken nicht mehr", function()
    local central = msg.new({ node_id = "zentrale-1", boot_id = 1, epoch = 5 })
    local station_box = msg.inbox({ node_id = "bahnhof-1", central_id = "zentrale-1" })
    t.eq((station_box.accept(central.make("auftrag", "bahnhof-1", {}))), "ok")
    t.eq(station_box.epoch(), 5)
    local old = msg.new({ node_id = "zentrale-1", boot_id = 0, epoch = 4 })
    t.eq((station_box.accept(old.make("auftrag", "bahnhof-1", {}))), "stale_epoch")
    t.eq((station_box.accept(old.make("meldung", "bahnhof-1", {}))), "stale_epoch", "auch Meldungen der Zentrale")
    -- eine Meldung eines anderen Nodes aus altem Lauf ist nur verspaetet, nicht ungueltig
    local other = msg.new({ node_id = "signal-1", boot_id = 1, epoch = 4 })
    local status, extra = station_box.accept(other.make("meldung", "bahnhof-1", {}))
    t.eq(status, "ok")
    t.eq(extra.late_epoch, true)
    -- ein Auftrag eines anderen mit alter Epoche wird abgewiesen
    t.eq((station_box.accept(other.make("auftrag", "bahnhof-1", {}))), "stale_epoch")
  end },
  { "die Epoche steigt nur durch die Zentrale", function()
    local box = msg.inbox({ node_id = "x", central_id = "zentrale-1" })
    local fremd = msg.new({ node_id = "fremder", boot_id = 1, epoch = 99 })
    box.accept(fremd.make("meldung", "x", {}))
    t.eq(box.epoch(), 0)
    local zentrale = msg.new({ node_id = "zentrale-1", boot_id = 1, epoch = 3 })
    box.accept(zentrale.make("meldung", "x", {}))
    t.eq(box.epoch(), 3)
  end },
  { "Luecken in der Folge werden gemeldet, alte Reihenfolge abgewiesen", function()
    local f, box = pair()
    local m1 = f.make("meldung", "zentrale-1", {})
    local m2 = f.make("meldung", "zentrale-1", {})
    local m3 = f.make("meldung", "zentrale-1", {})
    local m4 = f.make("meldung", "zentrale-1", {})
    t.eq((box.accept(m1)), "ok")
    local status, extra = box.accept(m4)
    t.eq(status, "ok"); t.eq(extra.gap, 2)
    t.eq((box.accept(m2)), "old_sequence")
    t.eq((box.accept(m3)), "old_sequence")
  end },
  { "neuer Start des Absenders setzt die Folge zurueck", function()
    local box = msg.inbox({ node_id = "z" })
    local boot1 = msg.new({ node_id = "n", boot_id = 1 })
    for _ = 1, 5 do box.accept(boot1.make("meldung", "z", {})) end
    local boot2 = msg.new({ node_id = "n", boot_id = 2 })
    local status, extra = box.accept(boot2.make("meldung", "z", {}))
    t.eq(status, "ok")
    t.eq(extra.gap, nil)
  end },
  { "gemerkte Antworten und Obergrenze", function()
    local box = msg.inbox({ node_id = "z", max_seen = 3 })
    for i = 1, 5 do box.remember("id" .. i, { n = i }) end
    t.eq(box.reply_for("id1"), nil)
    t.eq(box.reply_for("id5").n, 5)
  end },
  { "Duplikat-Speicher ist begrenzt", function()
    local box = msg.inbox({ node_id = "z", max_seen = 5 })
    local f = msg.new({ node_id = "n", boot_id = 1 })
    local first = f.make("meldung", "z", {})
    box.accept(first)
    for _ = 1, 10 do box.accept(f.make("meldung", "z", {})) end
    -- die erste ID wurde vergessen; wegen der Sequenzpruefung bleibt sie trotzdem wirkungslos
    t.eq((box.accept(first)), "old_sequence")
  end },
}
