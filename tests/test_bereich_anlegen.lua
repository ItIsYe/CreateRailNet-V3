--[[
Purpose: Bereich von der Node aus anlegen (Konzept 10.2): Bildschirm Neuer Bereich im Ablauf; die Leitstelle speichert zentral, dieselbe Anforderung legt nichts doppelt an, Fehler und fehlende Leitstelle bleiben ohne Folgen.
]]

local t = dofile("tests/lib/t.lua")
local H = dofile("tests/lib/harness.lua")
local storelib = require("core.store")

-- Leitstelle ohne Bereich und ein leerer Computer bis zum Bildschirm "Bereich waehlen"
local function setup()
  local h = H.new()
  local z = h.add_node({ id = "hauptstelle", roles = { "zentrale" }, tracks = {} })
  local netz = z.node.roles.zentrale.netz
  local d = h.add_blank({ id = "neu" })
  d.world.add_signal("Create_Signal_1"); d.world.add_signal("Create_Signal_2")
  h.step(1)
  local v = d.view()
  v.set_page("einrichtung")
  d.tap(v, "act:start")
  d.tap(v, "sel:modus:2"); d.tap(v, "act:weiter")
  h.step(5); d.node.render()
  d.tap(v, "sel:netzwahl:1"); d.tap(v, "act:weiter")
  d.tap(v, "sel:rollen:5"); d.tap(v, "act:weiter")
  h.step(3); d.node.render()
  return h, z, d, v, netz
end

local function screen(d) return d.node.setup.session().screen end

local function fill(d, v, name, e1, e2, count)
  d.type(v, "bname", name); d.type(v, "bende1", e1); d.type(v, "bende2", e2); d.type(v, "bzahl", count)
end

return {
  { "Neuer Bereich von der Node: angelegt, gewaehlt, Gleise stehen zur Uebernahme bereit", function()
    local h, z, d, v, netz = setup()
    t.eq(screen(d), "2.bereich", d.text(v))
    t.contains(d.text(v), "noch keinen Bereich")
    d.tap(v, "act:neuer_bereich")
    t.eq(screen(d), "2.b.neu", d.text(v))
    fill(d, v, "West-Ost", "Westbahnhof", "Ostbahnhof", "3")
    d.tap(v, "act:b_anlegen")
    h.step(4); d.node.render()
    t.eq(#netz.areas(), 1, v.hint)
    t.eq(netz.areas()[1].name, "West-Ost")
    t.eq(#netz.area("B0001").tracks, 3)
    t.eq(screen(d), "2.bereich", d.text(v))
    t.ok(d.has(v, "(o) West-Ost"), "der neue Bereich ist schon gewaehlt: " .. d.text(v))
    d.tap(v, "act:weiter")
    t.eq(screen(d), "2.gleise", d.text(v))
    t.ok(d.has(v, "[x] Gleis 3"), d.text(v))
  end },
  { "Vorlage waehlen: 'gleich' und 'beide' wirken auf die Gleisrichtungen", function()
    local h, z, d, v, netz = setup()
    d.tap(v, "act:neuer_bereich")
    fill(d, v, "Nur Ost", "West", "Ost", "2")
    d.tap(v, "act:b_vorlage")                                   -- gleich
    d.tap(v, "act:b_anlegen")
    h.step(4); d.node.render()
    t.eq(netz.area("B0001").tracks[1].direction, "Ost"); t.eq(netz.area("B0001").tracks[2].direction, "Ost")
    d.tap(v, "act:neuer_bereich")
    fill(d, v, "Offen", "Nord", "Sued", "1")
    d.tap(v, "act:b_vorlage"); d.tap(v, "act:b_vorlage")        -- gleich, beide
    d.tap(v, "act:b_anlegen")
    h.step(4); d.node.render()
    t.eq(netz.area("B0002").tracks[1].direction, "beide")
  end },
  { "Fehler der Leitstelle werden gezeigt, die Eingabe bleibt stehen; Pruefung auf der Node vor dem Senden", function()
    local h, z, d, v, netz = setup()
    netz.add_area({ name = "West-Ost", ends = { "A", "B" }, count = 1 })
    d.tap(v, "act:neu_laden"); h.step(3); d.node.render()
    d.tap(v, "act:neuer_bereich")
    d.tap(v, "act:b_anlegen")
    t.contains(v.hint, "Name des Bereichs fehlt")
    d.type(v, "bname", "Ost-West")
    d.tap(v, "act:b_anlegen")
    t.contains(v.hint, "Anschlussnamen fehlen")
    d.type(v, "bende1", "Westbahnhof"); d.type(v, "bende2", "Westbahnhof")
    d.type(v, "bzahl", "x")
    d.tap(v, "act:b_anlegen")
    t.contains(v.hint, "Gleisanzahl")
    d.type(v, "bzahl", "2")
    d.tap(v, "act:b_anlegen")
    h.step(4); d.node.render()
    t.eq(screen(d), "2.b.neu")
    t.contains(v.hint, "verschiedene Namen")
    d.type(v, "bende2", "Ostbahnhof")
    d.type(v, "bname", "west-ost")
    d.tap(v, "act:b_anlegen")
    h.step(4); d.node.render()
    t.contains(v.hint, "gibt es schon")
    t.eq(#netz.areas(), 1)
    d.type(v, "bname", "Ost-West")
    d.tap(v, "act:b_anlegen")
    h.step(4); d.node.render()
    t.eq(#netz.areas(), 2)
    t.eq(screen(d), "2.bereich")
  end },
  { "Wiederholung mit gleichen Angaben legt nichts doppelt an (Antwort ging verloren); geaenderte Angaben sind eine neue Anforderung", function()
    local h, z, d, v, netz = setup()
    local drop = true
    local real = z.node.reply
    z.node.reply = function(m, status, payload)
      if drop and m.payload and m.payload.kind == "bereich_anlegen" then return end
      return real(m, status, payload)
    end
    d.tap(v, "act:neuer_bereich")
    fill(d, v, "West-Ost", "Westbahnhof", "Ostbahnhof", "2")
    d.tap(v, "act:b_anlegen")
    h.step(12); d.node.render()
    t.eq(#netz.areas(), 1, "die Leitstelle hat angelegt, die Antwort kam nicht an")
    t.contains(d.text(v) .. v.hint, "antwortet nicht")
    drop = false
    d.tap(v, "act:b_anlegen")
    h.step(4); d.node.render()
    t.eq(#netz.areas(), 1, "keine doppelte Anlage")
    t.eq(screen(d), "2.bereich")
    t.ok(d.has(v, "(o) West-Ost"), d.text(v))
  end },
  { "Nach verlorener Antwort die Angaben geaendert: das ist eine neue Anforderung, der Bereich mit den neuen Angaben entsteht", function()
    local h, z, d, v, netz = setup()
    local drop = true
    local real = z.node.reply
    z.node.reply = function(m, status, payload)
      if drop and m.payload and m.payload.kind == "bereich_anlegen" then return end
      return real(m, status, payload)
    end
    d.tap(v, "act:neuer_bereich")
    fill(d, v, "West-Ost", "Westbahnhof", "Ostbahnhof", "2")
    d.tap(v, "act:b_anlegen")
    h.step(12); d.node.render()
    drop = false
    d.type(v, "bname", "Ost-West")
    d.tap(v, "act:b_anlegen")
    h.step(4); d.node.render()
    t.eq(#netz.areas(), 2, "der erste Bereich bleibt (Ergebnis war unbekannt), der zweite hat die neuen Angaben")
    t.ok(d.has(v, "(o) Ost-West"), d.text(v))
  end },
  { "Leitstelle: Kennung, Angaben und Wiederholung auf der Drahtebene", function()
    local h, z, d, v, netz = setup()
    local role = z.node.roles.zentrale
    local replies = {}
    local real = z.node.reply
    z.node.reply = function(m, status, payload) replies[#replies + 1] = { status = status, payload = payload } return real(m, status, payload) end
    local function ask(payload)
      role.on_message(d.node.replace_factory.make("abfrage", "hauptstelle", payload), "ok")
      return replies[#replies]
    end
    local spec = { kind = "bereich_anlegen", token = "t1-123456789", name = "West-Ost", ends = { "A", "B" }, count = 2 }
    t.eq(ask({ kind = "bereich_anlegen", name = "X", ends = { "A", "B" }, count = 1 }).status, "abgelehnt", "ohne Kennung")
    t.eq(ask({ kind = "bereich_anlegen", token = "kurz", name = "X", ends = { "A", "B" }, count = 1 }).status, "abgelehnt", "zu kurze Kennung")
    t.eq(ask({ kind = "bereich_anlegen", token = "t2-123456789", name = "X", count = 1 }).status, "abgelehnt", "ohne Anschluesse")
    t.eq(ask({ kind = "bereich_anlegen", token = "t2-123456789", name = "X", ends = { "A" }, count = 1 }).status, "abgelehnt", "ein Anschluss")
    t.eq(ask({ kind = "bereich_anlegen", token = "t2-123456789", name = "X", ends = 5, count = 1 }).status, "abgelehnt", "Anschluesse keine Liste")
    t.eq(ask({ kind = "bereich_anlegen", token = "t2-123456789", name = "X", ends = { "A", "B" }, count = 99 }).status, "abgelehnt", "zu viele Gleise")
    t.eq(ask({ kind = "bereich_anlegen", token = "t2-123456789", name = "X", ends = { "A", "B" }, count = 1, pattern = "quer" }).status, "abgelehnt", "unbekannte Vorlage")
    t.eq(#netz.areas(), 0)
    local first = ask(spec)
    t.eq(first.status, "ok"); t.eq(first.payload.created, true); t.eq(first.payload.area.id, "B0001")
    local again = ask(spec)
    t.eq(again.status, "ok"); t.eq(again.payload.created, false); t.eq(again.payload.area.id, "B0001")
    t.eq(#netz.areas(), 1)
    -- die Kennung bleibt auch nach dem Neustart der Leitstelle bekannt
    local store = storelib.new(z.fs)
    local reloaded = require("domain.netz").new({ store = store, path = "/crn_data/netz.lua" })
    local id, created = reloaded.add_area_once("t1-123456789", spec)
    t.eq(id, "B0001"); t.eq(created, false)
  end },
  { "Kennungsspeicher ist begrenzt: die aeltesten werden vergessen, der Zaehler laeuft nie zurueck", function()
    local M = require("domain.netz")
    local netz = M.new({})
    local saved = M.MAX_TOKENS
    M.MAX_TOKENS = 5
    local limit = M.MAX_TOKENS
    local first
    for i = 1, limit + 3 do
      local id = assert(netz.add_area_once(string.format("tok-%08d", i), { name = "Bereich " .. i, ends = { "A", "B" }, count = 1 }))
      first = first or id
    end
    local _, created = netz.add_area_once(string.format("tok-%08d", limit + 3), { name = "Bereich neu", ends = { "A", "B" }, count = 1 })
    t.eq(created, false, "die neueste Kennung ist noch bekannt")
    local again, was_new = netz.add_area_once("tok-00000001", { name = "Bereich spaet", ends = { "A", "B" }, count = 1 })
    t.eq(was_new, true, "eine vergessene Kennung legt neu an")
    t.ok(again ~= first, "mit neuer Kennung (nie wiederverwendet)")
    M.MAX_TOKENS = saved
  end },
}
