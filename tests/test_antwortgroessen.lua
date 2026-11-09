--[[
Purpose: Antworten der Leitstelle bleiben unter der Funkgrenze, auch mit langen Namen und vielen Eintraegen: Bahnhoefe, Vorlagen (seitenweise, vollstaendig beim Empfaenger) und Tafel (gekuerzt).
]]

local t = dofile("tests/lib/t.lua")
local H = dofile("tests/lib/harness.lua")
local ser = require("core.ser")

local LIMIT = 4800

local function build()
  local h = H.new()
  local z = h.add_node({ id = "hauptstelle", roles = { "zentrale" }, tracks = {} })
  local a = h.add_node({ id = "anmeldehof", roles = { "bahnhof", "anmeldung" }, central = "hauptstelle", registration = "Gleis 1",
    tracks = { { name = "Gleis 1", station_name = "Anmeldehof", known = {} } } })
  h.step(3)
  local asks = {}
  local real = z.node.reply
  z.node.reply = function(m, status, payload)
    asks[#asks + 1] = { kind = m.payload.kind, status = status, payload = payload, size = #ser.encode(payload) }
    return real(m, status, payload)
  end
  local function ask(payload)
    local m = a.node.factory.make("abfrage", "hauptstelle", payload)
    z.node.roles.zentrale.on_message(m, "ok")
    return asks[#asks]
  end
  return h, z, a, ask, asks
end

-- Namen im Verzeichnis sind hoechstens 30 Zeichen lang; Titel von Vorlagen und Linien sind freier
local function long(prefix, i) return (prefix .. " " .. i .. " " .. string.rep("N", 40)):sub(1, 30) end

return {
  { "Bahnhofsliste mit langen Namen: seitenweise, vollstaendig, unter der Funkgrenze", function()
    local h, z, a, ask = build()
    local zentrale = z.node.roles.zentrale
    for i = 1, 80 do assert(zentrale.stations.set((string.format("Station %d ", i) .. string.rep("N", 40)):sub(1, 40), { "Gleis " .. i })) end
    local got, after, pages = {}, nil, 0
    repeat
      local r = ask({ kind = "bahnhoefe_liste", after = after })
      t.ok(r.size <= LIMIT, "Seite hat " .. r.size)
      for _, st in ipairs(r.payload.stations) do got[#got + 1] = st.name end
      after = r.payload.stations[#r.payload.stations].name
      pages = pages + 1
      t.ok(pages < 40)
    until not r.payload.more
    t.ok(#got >= 80, "alle Gruppen und die gemeldeten Bahnhoefe: " .. #got)
  end },
  { "Vorlagen: lange Liste kommt seitenweise und vollstaendig bei der Anmeldung an", function()
    local h, z, a, ask, asks = build()
    local zentrale = z.node.roles.zentrale
    for i = 1, 90 do
      t.eq(zentrale.orders.add_template({
        id = string.format("vorlage-%03d", i), title = long("Fahrt", i) .. string.rep("T", 30), train = "GZ-001",
        stops = { { station = "Anmeldehof", wait = 1 }, { station = "Zielhof", wait = 1 } },
      }), true)
    end
    -- unmittelbar: Seiten und Groessen
    local first = ask({ kind = "vorlagen" })
    t.ok(first.size <= LIMIT, "erste Seite " .. first.size)
    t.eq(first.payload.more, true); t.eq(first.payload.von_vorn, true)
    t.eq(first.payload.templates[1].id, "vorlage-001")
    local second = ask({ kind = "vorlagen", nach = first.payload.templates[#first.payload.templates].id })
    t.ok(second.size <= LIMIT)
    t.eq(second.payload.von_vorn, nil)
    t.eq(second.payload.templates[1].id, string.format("vorlage-%03d", #first.payload.templates + 1), "nahtlos dahinter")
    -- unbekannte Kennung (zwischendurch geloescht): von vorn
    local lost = ask({ kind = "vorlagen", nach = "gibt-es-nicht" })
    t.eq(lost.payload.von_vorn, true); t.eq(lost.payload.templates[1].id, "vorlage-001")
    -- Unsinn als Cursor wird ignoriert
    t.eq(ask({ kind = "vorlagen", nach = 42 }).payload.von_vorn, true)
    -- Ende-zu-Ende: die Anmeldung fragt Seite fuer Seite und kennt am Ende alle 90 Vorlagen
    h.step(60)
    local known = a.node.roles.anmeldung.templates()
    t.eq(#known, 90, "alle Vorlagen beim Empfaenger")
    for i = 1, 90 do t.eq(known[i].id, string.format("vorlage-%03d", i)) end
  end },
  { "Vorlagen: Verlust und Doppelung der Seiten fuehren nicht zu doppelten oder fehlenden Eintraegen", function()
    for seed = 1, 6 do
      local h = H.new({ seed = seed, drop = 0.2, dup = 0.3, reorder = true })
      local z = h.add_node({ id = "hauptstelle", roles = { "zentrale" }, tracks = {} })
      local a = h.add_node({ id = "anmeldehof", roles = { "bahnhof", "anmeldung" }, central = "hauptstelle", registration = "Gleis 1",
        tracks = { { name = "Gleis 1", station_name = "Anmeldehof", known = {} } } })
      for i = 1, 70 do
        z.node.roles.zentrale.orders.add_template({
          id = string.format("vorlage-%03d", i), title = long("Fahrt", i) .. string.rep("T", 30), train = "GZ-001",
          stops = { { station = "Anmeldehof", wait = 1 }, { station = "Zielhof", wait = 1 } },
        })
      end
      local ok = h.until_true(function()
        local known = a.node.roles.anmeldung.templates()
        if #known ~= 70 then return false end
        for i = 1, 70 do if known[i].id ~= string.format("vorlage-%03d", i) then return false end end
        return true
      end, 400)
      t.ok(ok, "Zufallsmuster " .. seed .. ": " .. #a.node.roles.anmeldung.templates() .. " von 70")
    end
  end },
  { "Tafel: viele Linien werden auf die Funkgrenze gekuerzt (more), die ersten Zeilen bleiben", function()
    local h, z, a, ask = build()
    local zentrale = z.node.roles.zentrale
    zentrale.orders.add_template({ id = "pendel", title = "Pendel", train = "GZ-001", stops = { { station = "Anmeldehof", wait = 1 }, { station = "Zielhof", wait = 1 } } })
    for i = 1, 60 do
      zentrale.lines.set({ id = string.format("linie-%03d", i), title = long("Linie", i) .. string.rep("L", 30), template = "pendel", trains = { "GZ-001" }, interval = 600, offset = i })
    end
    local r = ask({ kind = "tafel" })
    t.eq(r.status, "ok")
    t.ok(r.size <= LIMIT, "Antwort " .. r.size)
    t.eq(r.payload.more, true, "gekuerzt")
    t.ok(#r.payload.rows >= 5 and #r.payload.rows < 60, "Zeilen: " .. #r.payload.rows)
    t.eq(r.payload.rows[1].line, "linie-001")
    -- wenige Linien: nichts gekuerzt
    for i = 6, 60 do zentrale.lines.remove(string.format("linie-%03d", i)) end
    local small = ask({ kind = "tafel" })
    t.eq(#small.payload.rows, 5); t.eq(small.payload.more, nil)
    -- falscher Typ: abgelehnt, nicht abgestuerzt und nicht "alle Linien"
    local bad = ask({ kind = "tafel", station = { 1 } })
    t.eq(bad.status, "abgelehnt"); t.contains(bad.payload.grund, "Bahnhof")
    t.eq(ask({ kind = "tafel", station = "Anmeldehof" }).status, "ok")
  end },
  { "Vorlagen: eine doppelt zugestellte (auch letzte) Seite ersetzt die Liste nicht, ein abgebrochener Abruf wird beim naechsten Abruf neu aufgebaut", function()
    local h, z, a = build()
    local zentrale = z.node.roles.zentrale
    for i = 1, 90 do
      zentrale.orders.add_template({
        id = string.format("vorlage-%03d", i), title = long("Fahrt", i) .. string.rep("T", 30), train = "GZ-001",
        stops = { { station = "Anmeldehof", wait = 1 }, { station = "Zielhof", wait = 1 } },
      })
    end
    local captured = {}
    table.insert(a.node.hooks.on_message, 1, function(m)
      if m.messageType == "bestaetigung" and m.payload.antwort_auf == "vorlagen" then captured[#captured + 1] = m end
    end)
    h.step(60)
    local anm = a.node.roles.anmeldung
    t.eq(#anm.templates(), 90)
    t.ok(#captured >= 2, "mehrere Seiten gesehen")
    local last_page
    for _, m in ipairs(captured) do if not m.payload.more then last_page = m end end
    t.ok(last_page, "letzte Seite gesehen")
    anm.on_message(last_page, "duplicate")
    t.eq(#anm.templates(), 90, "die doppelt zugestellte letzte Seite ersetzt die Liste nicht")
    anm.on_message(captured[1], "duplicate")
    anm.on_message(captured[2], "duplicate")
    t.eq(#anm.templates(), 90)
    -- dieselbe Seite zweimal als neu zugestellt (verspaetete Antwort eines frueheren Abrufs): keine doppelten Eintraege
    local round
    for i, m in ipairs(captured) do if m.payload.von_vorn then round = i end end
    t.ok(round and captured[round + 2] and not captured[round + 2].payload.more, "eine vollstaendige Runde am Ende")
    anm.on_message(captured[round], "ok")
    anm.on_message(captured[round + 1], "ok")
    anm.on_message(captured[round + 1], "ok")
    anm.on_message(captured[round + 2], "ok")
    t.eq(#anm.templates(), 90, "doppelt eingetroffene Seite zaehlt einmal")
    -- Abruf nach der ersten Seite abgebrochen (Seite 2 geht verloren), dazwischen aendert sich eine Vorlage: der naechste Abruf liefert den neuen Stand
    local dropped_second = false
    h.bus.filter = function(from, to, text)
      if to ~= a.cid then return false end
      local ok, m = pcall(ser.decode, text)
      if ok and type(m) == "table" and m.messageType == "bestaetigung" and m.payload and m.payload.antwort_auf == "vorlagen" and m.payload.von_vorn ~= true then
        dropped_second = true
        return true
      end
      return false
    end
    h.step(80)
    t.ok(dropped_second, "Folgeseite abgefangen")
    h.bus.filter = nil
    local first_id = captured[1].payload.templates[1].id
    local changed = zentrale.orders.template(first_id)
    changed.title = "Neuer Titel"
    t.eq(zentrale.orders.add_template(changed), true)
    -- den ersten Abschluss nach der Aenderung beobachten (spaetere Abrufe wuerden einen Fehler verdecken)
    local before = anm.templates()
    for _ = 1, 40 do
      h.step(1)
      if anm.templates() ~= before then break end
    end
    t.ok(anm.templates() ~= before, "ein Abruf wurde abgeschlossen")
    t.eq(#anm.templates(), 90, "genau 90 Vorlagen, keine doppelten")
    t.eq(anm.templates()[1].id, first_id)
    t.eq(anm.templates()[1].title, "Neuer Titel", "der neue Stand ersetzt den alten, auch wenn der vorige Abruf abgebrochen wurde")
  end },
}
