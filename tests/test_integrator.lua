--[[
Purpose: Integrator fuer alte Datenstaende (core/dataformat.lua, core/migrations.lua): Sicherung vor jeder Anpassung, Schritte in Reihenfolge, bei Fehler oder Absturz bleibt der alte Stand erhalten und die Anpassung laeuft beim naechsten Start sauber von vorn, neuere Daten werden nie angefasst. Dazu: Datenstaende aelterer Programmversionen starten im aktuellen Programm, und die Form der gespeicherten Dateien ist festgehalten (ohne neues Datenformat darf sie sich nicht aendern).
]]

local t = dofile("tests/lib/t.lua")
local cc = dofile("tests/fakes/cc.lua")
local storelib = require("core.store")
local dataformat = require("core.dataformat")
local migrations = require("core.migrations")
local ser = require("core.ser")
local model = require("setup.model")
local H = dofile("tests/lib/harness.lua")
local fixtures = dofile("tests/fixtures/alte_staende.lua")
local shape = dofile("tests/lib/shape.lua")
local GOLDEN = "tests/golden/datenform.txt"

local function world(opts)
  local fs = cc.fs(opts)
  fs.makeDir("/crn_data")
  return fs, storelib.new(fs)
end

local function seed(fs, store, format)
  store.save("/crn_data/format.lua", { format = format or 1, program = "0.1" })
  store.save("/crn_data/config.lua", { version = 1, revision = 3, node = { id = "n1", roles = { "signal" } } })
  store.save("/crn_data/sperren.lua", { locks = { s1 = { owner = "knoten" } } })
  fs.makeDir("/crn_data/nodesich")
  store.save("/crn_data/nodesich/n2.lua", { node = { id = "n2" }, revision = 7 })
end

-- Schritt 1 -> 2: benennt in config.lua revision in stand um, nimmt die Sicherungen der Leitstelle mit
local function rename_step(ctx)
  ctx.update("config.lua", function(c) c.stand = c.revision; c.revision = nil; return c end)
  ctx.update("nodesich/n2.lua", function(c) c.stand = c.revision; c.revision = nil; return c end)
end

local function opts(extra)
  local o = { format = 2, program = "0.2", migrations = { [1] = { text = "revision heisst jetzt stand", run = rename_step } } }
  for k, v in pairs(extra or {}) do o[k] = v end
  return o
end

local function snapshot(fs)
  local out = {}
  for path, text in pairs(fs._state.files) do
    if path:match("^crn_data/") and not path:match("%.tmp$") then out[path] = text end
  end
  return out
end

return {
  { "ohne Stand: neu angelegt; gleicher Stand: nichts zu tun; Programmname wird nachgefuehrt", function()
    local fs, store = world()
    t.eq((dataformat.check(fs, store, { format = 1, program = "0.1" })), "neu")
    t.eq((dataformat.check(fs, store, { format = 1, program = "0.1" })), "gleich")
    t.eq((dataformat.check(fs, store, { format = 1, program = "0.2" })), "gleich")
    t.eq(store.load("/crn_data/format.lua").program, "0.2")
  end },

  { "aelterer Stand: Sicherung aller Dateien (auch in Unterordnern), Schritt laeuft, Stand wird nachgefuehrt", function()
    local fs, store = world()
    seed(fs, store)
    local status, old, dir, err = dataformat.check(fs, store, opts())
    t.eq(status, "migriert", tostring(err))
    t.eq(old, 1)
    t.eq(store.load("/crn_data/config.lua").stand, 3)
    t.eq(store.load("/crn_data/config.lua").revision, nil)
    t.eq(store.load("/crn_data/nodesich/n2.lua").stand, 7, "Sicherung der Leitstelle wird mitangepasst")
    t.eq(store.load(dir .. "/config.lua").revision, 3, "Sicherung enthaelt den alten Stand")
    t.eq(store.load(dir .. "/nodesich/n2.lua").revision, 7)
    t.eq(store.load("/crn_data/format.lua").format, 2)
    t.ok(not fs.exists("/crn_data/migration.lua"), "kein Merker einer laufenden Anpassung bleibt")
    t.eq(#dataformat.backups(fs), 1)
  end },

  { "mehrere Schritte laufen nacheinander von dem Stand der Daten bis zum Stand des Programms", function()
    local fs, store = world()
    seed(fs, store)
    local order = {}
    local o = opts({ format = 4, migrations = {
      [1] = { text = "a", run = function(ctx) order[#order + 1] = 1; rename_step(ctx) end },
      [2] = { text = "b", run = function(ctx) order[#order + 1] = 2; ctx.update("config.lua", function(c) c.zwei = true; return c end) end },
      [3] = function(ctx) order[#order + 1] = 3; ctx.update("config.lua", function(c) c.drei = true; return c end) end,
    } })
    t.eq((dataformat.check(fs, store, o)), "migriert")
    t.eq(table.concat(order, ","), "1,2,3")
    local c = store.load("/crn_data/config.lua")
    t.ok(c.zwei and c.drei and c.stand == 3)
    -- Daten bei Stand 2: nur die Schritte 2 und 3
    local fs2, store2 = world()
    seed(fs2, store2, 2)
    order = {}
    t.eq((dataformat.check(fs2, store2, o)), "migriert")
    t.eq(table.concat(order, ","), "2,3")
  end },

  { "ein Schritt scheitert (Fehler): alle Dateien kommen zurueck, Stand bleibt, Ergebnis nennt den Grund", function()
    local fs, store = world()
    seed(fs, store)
    local before = snapshot(fs)
    local o = opts({ migrations = { [1] = { text = "kaputt", run = function(ctx)
      rename_step(ctx)
      ctx.save("neu.lua", { x = 1 })
      error("Absicht")
    end } } })
    local status, old, dir, err = dataformat.check(fs, store, o)
    t.eq(status, "fehlgeschlagen")
    t.eq(old, 1)
    t.contains(err, "Absicht")
    t.contains(err, "kaputt")
    t.eq(store.load("/crn_data/config.lua").revision, 3, "alter Stand zurueck")
    t.eq(store.load("/crn_data/nodesich/n2.lua").revision, 7)
    t.ok(not fs.exists("/crn_data/neu.lua"), "vom Schritt angelegte Datei entfernt")
    t.eq(store.load("/crn_data/format.lua").format, 1, "Stand bleibt alt")
    t.ok(not fs.exists("/crn_data/migration.lua"))
    -- nach der Rueckkehr sind alle Nutzdaten wie vorher
    for path, text in pairs(before) do
      if not path:match("%.prev$") and not path:match("sicherung_f") then t.eq(fs._state.files[path], text, path) end
    end
  end },

  { "ein Schritt meldet false mit Grund: ebenso zurueck; der zweite Versuch mit funktionierendem Schritt gelingt", function()
    local fs, store = world()
    seed(fs, store)
    local bad = opts({ migrations = { [1] = { text = "Pruefung", run = function(ctx) rename_step(ctx); return false, "Wert fehlt" end } } })
    local status, _, _, err = dataformat.check(fs, store, bad)
    t.eq(status, "fehlgeschlagen"); t.contains(err, "Wert fehlt")
    t.eq(store.load("/crn_data/config.lua").revision, 3)
    status = dataformat.check(fs, store, opts())
    t.eq(status, "migriert")
    t.eq(store.load("/crn_data/config.lua").stand, 3)
  end },

  { "ein Schritt, der eine Datei unlesbar hinterlaesst, gilt als gescheitert und wird zurueckgenommen (auch wenn eine Vorfassung noch lesbar waere)", function()
    local fs, store = world()
    seed(fs, store)
    store.save("/crn_data/config.lua", { version = 1, revision = 3, node = { id = "n1", roles = { "signal" } } })    -- zweites Speichern: .prev vorhanden
    t.ok(fs.exists("/crn_data/config.lua.prev"))
    local o = opts({ migrations = { [1] = { text = "zerstoert", run = function()
      local fh = fs.open("/crn_data/config.lua", "wb"); fh.write("-- crn 00000000 5\nkaput"); fh.close()
    end } } })
    local status, _, _, err = dataformat.check(fs, store, o)
    t.eq(status, "fehlgeschlagen"); t.contains(err, "config.lua")
    t.eq(store.load("/crn_data/config.lua").revision, 3)
  end },

  { "Absturz an jeder Stelle: der naechste Start stellt den alten Stand her und fuehrt die Anpassung genau einmal aus", function()
    local probe_fs, probe_store = world()
    seed(probe_fs, probe_store)
    local before = probe_fs._state.ops
    dataformat.check(probe_fs, probe_store, opts())
    local total = probe_fs._state.ops - before
    t.ok(total > 10, "es gibt viele Dateiaenderungen zu pruefen")
    for n = 1, total + 2 do
      local fs, store = world()
      seed(fs, store)
      fs._state.crash_at = fs._state.ops + n
      pcall(dataformat.check, fs, store, opts())
      fs._state.crash_at = nil
      fs._state.crashed = nil
      -- Neustart: Dateien heilen wie beim Start des Programms, dann erneut pruefen
      for _, p in ipairs({ "/crn_data/config.lua", "/crn_data/sperren.lua", "/crn_data/format.lua", "/crn_data/nodesich/n2.lua" }) do store.heal(p) end
      local count = 0
      local o = opts({ migrations = { [1] = { text = "zaehlen", run = function(ctx) count = count + 1; rename_step(ctx) end } } })
      local status, _, _, err = dataformat.check(fs, store, o)
      t.ok(status == "migriert" or status == "gleich", "Absturz " .. n .. ": " .. tostring(status) .. " " .. tostring(err))
      local c = store.load("/crn_data/config.lua")
      t.eq(c.stand, 3, "Absturz " .. n .. ": Stand migriert")
      t.eq(c.revision, nil, "Absturz " .. n)
      t.eq(store.load("/crn_data/nodesich/n2.lua").stand, 7, "Absturz " .. n)
      t.eq(store.load("/crn_data/sperren.lua").locks.s1.owner, "knoten", "Absturz " .. n .. ": Nutzdaten erhalten")
      t.eq(store.load("/crn_data/format.lua").format, 2, "Absturz " .. n)
      t.ok(count <= 1, "Absturz " .. n .. ": Schritt hoechstens einmal nach dem Neustart")
      t.ok(not fs.exists("/crn_data/migration.lua"), "Absturz " .. n)
      -- die Sicherung enthaelt immer den urspruenglichen Stand, nie einen halb angepassten
      for _, b in ipairs(dataformat.backups(fs)) do
        t.eq(store.load(b.dir .. "/config.lua").revision, 3, "Absturz " .. n .. ": Sicherung unverfaelscht")
      end
    end
  end },

  { "Bereich der Sicherung (scope): ein Schritt, der nur config.lua aendert, sichert nur sie; grosse fremde Dateien verhindern die Anpassung nicht", function()
    local function with_big()
      local fs, store = world()
      seed(fs, store)
      store.save("/crn_data/nodesich/gross.lua", { text = string.rep("x", 70000) })        -- groesser als die Grenze je Datei
      return fs, store
    end
    local function scoped(run) return opts({ migrations = { [1] = { text = "nur config", scope = { "config.lua" }, run = run } } }) end
    local function only_config(ctx) ctx.update("config.lua", function(c) c.stand = c.revision; c.revision = nil; return c end) end
    -- ohne Bereich: alles muss in die Sicherung, die grosse Datei verhindert es (unveraendert)
    local fs, store = with_big()
    local status, _, _, err = dataformat.check(fs, store, opts())
    t.eq(status, "fehlgeschlagen"); t.contains(err, "zu gross")
    -- mit Bereich: nur config.lua wird gesichert und angepasst
    fs, store = with_big()
    local dir
    status, _, dir, err = dataformat.check(fs, store, scoped(only_config))
    t.eq(status, "migriert", tostring(err))
    t.eq(store.load("/crn_data/config.lua").stand, 3)
    t.eq(store.load(dir .. "/config.lua").revision, 3, "Sicherung enthaelt den alten Stand")
    t.ok(not fs.exists(dir .. "/sperren.lua") and not fs.exists(dir .. "/nodesich"), "fremde Dateien sind nicht in der Sicherung")
    t.eq(#store.load("/crn_data/nodesich/gross.lua").text, 70000, "fremde Dateien bleiben unberuehrt")
    t.eq(#dataformat.backups(fs), 1)
    -- Schritt scheitert: config.lua kommt zurueck, was er neu angelegt hat, verschwindet, alles andere bleibt
    fs, store = with_big()
    status, _, _, err = dataformat.check(fs, store, scoped(function(ctx)
      only_config(ctx)
      ctx.save("neu.lua", { x = 1 })
      error("kaputt")
    end))
    t.eq(status, "fehlgeschlagen"); t.contains(err, "kaputt")
    t.eq(store.load("/crn_data/config.lua").revision, 3, "alter Stand zurueck")
    t.ok(not fs.exists("/crn_data/neu.lua"), "Neues verschwindet")
    t.eq(store.load("/crn_data/sperren.lua").locks.s1.owner, "knoten")
    t.eq(#store.load("/crn_data/nodesich/gross.lua").text, 70000)
    t.eq(store.load("/crn_data/format.lua").format, 1)
    -- Absturz an jeder Stelle: danach stimmt der Stand genau einmal
    local probe_fs, probe_store = with_big()
    local before = probe_fs._state.ops
    dataformat.check(probe_fs, probe_store, scoped(only_config))
    local total = probe_fs._state.ops - before
    for n = 1, total + 2 do
      fs, store = with_big()
      fs._state.crash_at = fs._state.ops + n
      pcall(dataformat.check, fs, store, scoped(only_config))
      fs._state.crash_at, fs._state.crashed = nil, nil
      for _, path in ipairs({ "/crn_data/config.lua", "/crn_data/format.lua" }) do store.heal(path) end
      local count = 0
      status, _, _, err = dataformat.check(fs, store, scoped(function(ctx) count = count + 1; only_config(ctx) end))
      t.ok(status == "migriert" or status == "gleich", "Absturz " .. n .. ": " .. tostring(status) .. " " .. tostring(err))
      t.eq(store.load("/crn_data/config.lua").stand, 3, "Absturz " .. n)
      t.eq(store.load("/crn_data/config.lua").revision, nil, "Absturz " .. n)
      t.eq(store.load("/crn_data/format.lua").format, 2, "Absturz " .. n)
      t.eq(#store.load("/crn_data/nodesich/gross.lua").text, 70000, "Absturz " .. n)
      t.ok(count <= 1, "Absturz " .. n)
    end
  end },

  { "Bereich der Sicherung: mehrere Schritte vereinen ihre Bereiche; der Platzbedarf zaehlt nur die gesicherten Dateien", function()
    local fs, store = world()
    seed(fs, store)
    store.save("/crn_data/nodesich/gross.lua", { text = string.rep("x", 70000) })
    local o = {
      format = 3, program = "0.3",
      migrations = {
        [1] = { text = "config", scope = { "config.lua" }, run = function(ctx) ctx.update("config.lua", function(c) c.eins = true end) end },
        [2] = { text = "sperren", scope = { "sperren.lua" }, run = function(ctx) ctx.update("sperren.lua", function(c) c.zwei = true end) end },
      },
    }
    local status, _, dir, err = dataformat.check(fs, store, o)
    t.eq(status, "migriert", tostring(err))
    t.eq(store.load("/crn_data/config.lua").eins, true); t.eq(store.load("/crn_data/sperren.lua").zwei, true)
    t.ok(fs.exists(dir .. "/config.lua") and fs.exists(dir .. "/sperren.lua"), "beide Bereiche gesichert")
    t.ok(not fs.exists(dir .. "/nodesich"), "mehr nicht")
    -- Platz: frei sind nur wenige tausend Byte; gesichert werden zwei kleine Dateien, nicht die 70 000 Byte
    local small, small_store = world({ capacity = 1000000 })
    seed(small, small_store)
    small_store.save("/crn_data/nodesich/gross.lua", { text = string.rep("x", 70000) })
    local used = 1000000 - small.getFreeSpace("/")
    local tight, tight_store = world({ capacity = used + 12000 })
    seed(tight, tight_store)
    tight_store.save("/crn_data/nodesich/gross.lua", { text = string.rep("x", 70000) })
    local status2, _, _, err2 = dataformat.check(tight, tight_store, o)
    t.eq(status2, "migriert", tostring(err2))
  end },

  { "Der echte Schritt 1 -> 2 braucht nur config.lua in der Sicherung: eine grosse Leitstelle (viele und grosse Dateien) wird trotzdem angepasst", function()
    t.eq(migrations.STEPS[1].scope[1], "config.lua"); t.eq(#migrations.STEPS[1].scope, 1)
    local fs, store = world()
    store.save("/crn_data/format.lua", { format = 1, program = "0.1" })
    store.save("/crn_data/config.lua", { status = "entwurf", node = { id = "x", claim = "c1-123456789012" }, devices = {}, tracks = {} })
    fs.makeDir("/crn_data/nodesich")
    for i = 1, 8 do store.save("/crn_data/nodesich/N000" .. i .. ".lua", { config = string.rep("y", 40000) }) end      -- zusammen weit ueber 150000 Byte
    store.save("/crn_data/netz.lua", { text = string.rep("z", 59000) })
    local status, _, dir, err = dataformat.check(fs, store, { program = "0.2" })
    t.eq(status, "migriert", tostring(err))
    t.ok(not fs.exists("/crn_data/config.lua"))
    t.eq(store.load("/crn_data/anforderung.lua").claim, "c1-123456789012")
    t.eq(store.load(dir .. "/config.lua").status, "entwurf")
    t.eq(#store.load("/crn_data/netz.lua").text, 59000)
  end },

  { "unvollstaendige Sicherung (Absturz beim Kopieren) zaehlt nicht und wird neu angelegt", function()
    local fs, store = world()
    seed(fs, store)
    fs.makeDir("/crn_data/sicherung_f1")
    local fh = fs.open("/crn_data/sicherung_f1/config.lua", "wb"); fh.write("halb"); fh.close()
    fh = fs.open("/crn_data/sicherung_f1/veraltet.lua", "wb"); fh.write("Rest einer frueheren Sicherung"); fh.close()
    t.eq(#dataformat.backups(fs), 0, "ohne Abschlussmerker keine gueltige Sicherung")
    local ok, err = dataformat.restore(fs, store, 1)
    t.eq(ok, nil); t.contains(err, "Keine Sicherung")
    local status, _, dir = dataformat.check(fs, store, opts())
    t.eq(status, "migriert")
    t.eq(store.load(dir .. "/config.lua").revision, 3)
    t.ok(not fs.exists(dir .. "/veraltet.lua"), "Reste einer frueheren Sicherung sind weg")
    t.eq(#dataformat.backups(fs), 1)
  end },

  { "zu wenig Platz fuer die Sicherung: nichts wird veraendert, Ergebnis nennt den Grund", function()
    local fs, store = world({ capacity = 6000 })
    seed(fs, store)
    local status, _, _, err = dataformat.check(fs, store, opts())
    t.eq(status, "fehlgeschlagen")
    t.contains(err, "Platz")
    t.eq(store.load("/crn_data/config.lua").revision, 3)
    t.eq(store.load("/crn_data/format.lua").format, 1)
  end },

  { "zu grosse Datei fuer die Sicherung: keine Anpassung ohne Sicherung", function()
    local fs, store = world()
    seed(fs, store)
    local big = {}
    for i = 1, 5000 do big[i] = "eintrag-" .. i .. "-mit-etwas-laengerem-text-damit-es-gross-wird" end
    store.save("/crn_data/riesig.lua", big)
    t.ok(fs.getSize("/crn_data/riesig.lua") > 60000)
    local status, _, _, err = dataformat.check(fs, store, opts())
    t.eq(status, "fehlgeschlagen"); t.contains(err, "riesig.lua")
    t.eq(store.load("/crn_data/config.lua").revision, 3)
  end },

  { "neuere Daten als das Programm: nichts wird veraendert; Sicherung zurueckspielen geht und fuehrt den Stand nach", function()
    local fs, store = world()
    seed(fs, store)
    local _, _, dir = dataformat.check(fs, store, opts())
    local status, old = dataformat.check(fs, store, { format = 1, program = "0.1" })
    t.eq(status, "zu_neu"); t.eq(old, 2)
    t.eq(store.load("/crn_data/config.lua").stand, 3, "unveraendert")
    t.eq(store.load("/crn_data/format.lua").format, 2, "der Stand der Daten bleibt")
    t.eq(dataformat.restore(fs, store, 1), true)
    t.eq(store.load("/crn_data/config.lua").revision, 3)
    t.eq(store.load("/crn_data/nodesich/n2.lua").revision, 7)
    t.eq((dataformat.check(fs, store, { format = 1, program = "0.1" })), "gleich")
    t.ok(dir ~= nil)
  end },

  { "Schritte des Programms: lueckenlos, FORMAT ist 1 + Anzahl, jeder Schritt hat Text und Funktion", function()
    local n = #migrations.STEPS
    t.eq(migrations.FORMAT, 1 + n)
    t.eq(dataformat.FORMAT, migrations.FORMAT)
    for i = 1, n do
      local step = migrations.STEPS[i]
      t.eq(type(step.run), "function", "Schritt " .. i)
      t.eq(type(step.text), "string", "Schritt " .. i)
    end
    local count = 0
    for k in pairs(migrations.STEPS) do count = count + 1; t.eq(type(k), "number") end
    t.eq(count, n, "keine Luecken")
    t.eq(migrations.validate({ [1] = { text = "a", run = function() end }, [3] = { text = "b", run = function() end } }) == nil, false, "Luecke wird erkannt")
  end },

  { "Programmstart mit alten Daten: Anpassung laeuft vor dem Laden der Konfiguration, Meldung, Sicherung, Anzeige", function()
    local h = H.new()
    local s = h.add_node({ id = "strecke", roles = { "gueterbahnhof" }, tracks = { { name = "Gleis 1", station_name = "Hof" } } })
    storelib.new(s.fs).save("/crn_data/format.lua", { format = 1, program = "0.1" })
    s.env_extra = { data_format = 2, data_steps = { [1] = { text = "Merker", run = function(ctx)
      ctx.update("config.lua", function(c) c.angepasst = true end)
    end } } }
    local n = s.restart()
    t.eq(n.format_status, "migriert")
    t.eq(n.config.angepasst, true, "die Konfiguration wird erst nach der Anpassung geladen")
    t.eq(n.status().kind, "ok")
    local found
    for _, m in ipairs(n.messages) do if m.text:find("Daten an das neue Programm angepasst", 1, true) then found = m end end
    t.ok(found and found.level == "info", "Meldung ueber die Anpassung")
    t.contains(found.text, "Format 1 auf 2")
    t.ok(#dataformat.backups(s.fs) == 1)
    local v = H.open_page(s, "uebersicht")
    t.contains(s.text(v), "Daten angepasst (Format 1)")
    t.ok(n.roles.station ~= nil, "die Rolle laeuft")
  end },

  { "Programmstart, Anpassung scheitert: nichts veraendert, Automatik aus, Grund sichtbar, naechster Start versucht es erneut", function()
    local h = H.new()
    local s = h.add_node({ id = "strecke", roles = { "gueterbahnhof" }, tracks = { { name = "Gleis 1", station_name = "Hof" } } })
    local store = storelib.new(s.fs)
    store.save("/crn_data/format.lua", { format = 1, program = "0.1" })
    local before = ser.encode(store.load("/crn_data/config.lua"))
    local attempts = 0
    s.env_extra = { data_format = 2, data_steps = { [1] = { text = "kaputt", run = function(ctx)
      attempts = attempts + 1
      ctx.update("config.lua", function(c) c.halb = true end)
      error("Absicht")
    end } } }
    local n = s.restart()
    t.eq(n.format_status, "fehlgeschlagen")
    t.eq(n.format_blocked, true)
    t.eq(n.status().text, "Datenanpassung gescheitert")
    t.eq(n.status().kind, "halt")
    t.eq(ser.encode(store.load("/crn_data/config.lua")), before, "Konfiguration unveraendert")
    t.eq(n.config.halb, nil)
    t.eq(next(n.roles), nil, "keine Rolle laeuft")
    local error_note
    for _, m in ipairs(n.messages) do if m.level == "fehler" and m.text:find("gescheitert", 1, true) then error_note = m end end
    t.ok(error_note, "Meldung")
    t.contains(error_note.text, "Absicht")
    local v = H.open_page(s, "uebersicht")
    t.contains(s.text(v), "Daten nicht angepasst")
    t.contains(s.text(v), "Absicht")
    -- naechster Start mit einem funktionierenden Programm
    s.env_extra = { data_format = 2, data_steps = { [1] = { text = "heil", run = function(ctx)
      ctx.update("config.lua", function(c) c.angepasst = true end)
    end } } }
    n = s.restart()
    t.eq(n.format_status, "migriert")
    t.eq(n.config.angepasst, true)
    t.ok(n.roles.station ~= nil)
    t.eq(attempts, 1)
  end },

  { "Staende aelterer Programmversionen starten im aktuellen Programm: Konfiguration bleibt, Rollen laufen, die Leitstelle kennt die Nodes", function()
    local versions = {}
    for version in pairs(fixtures) do versions[#versions + 1] = version end
    table.sort(versions)
    t.ok(#versions >= 2)
    for _, version in ipairs(versions) do
      local h = H.new()
      local z = h.add_node({ id = "hauptstelle", roles = { "zentrale" }, tracks = {} })
      local s = h.add_node({ id = "strecke", roles = { "gueterbahnhof" }, central = "hauptstelle",
        tracks = { { name = "Gleis 1", station_name = "Hof" } } })
      local b = h.add_node({ id = "bahnhof", roles = { "passagierbahnhof" }, central = "hauptstelle",
        tracks = { { name = "Gleis 1", station_name = "Westbahnhof" } }, registration = "Gleis 1" })
      local old = fixtures[version]
      local expect = {}
      for _, d in ipairs({ z, s, b }) do
        local files = old[d.id]
        for path in pairs(d.fs._state.files) do if path:match("^crn_data/") then d.fs._state.files[path] = nil end end
        for path, text in pairs(files) do
          local dir = path:match("^(.*)/[^/]+$")
          if dir and not d.fs.exists(dir) then d.fs.makeDir(dir) end
          d.fs._state.files[path] = text
        end
        -- Schritt 2 -> 3 entfernt den Freigabeausgang der Gleise (die Freigabe laeuft ueber den Fahrplan); Schritt 3 -> 4 die Rollen Signal und Knoten:
        -- eine Node nur mit diesen Rollen verliert ihre Einrichtung, sonst bleibt alles, wie es war
        local before = storelib.new(d.fs).load("/crn_data/config.lua")
        for _, track in pairs(type(before) == "table" and before.tracks or {}) do track.release = nil end
        -- Schritt 4 -> 5: die Bahnhofsrollen sind eine, Beobachter und Gleisrichtung fallen weg
        if type(before) == "table" and before.node then model.normalize_config(model.drop_legacy(before)) end
        expect[d.id] = ser.encode(before)
        d.restart()
      end
      h.step(150)
      for _, d in ipairs({ z, s, b }) do
        local n = d.node
        local where = version .. "/" .. d.id
        -- Formate dieser Staende sind aelter als das aktuelle Programm: einmal angepasst (aktive Einrichtungen bleiben dabei unveraendert)
        t.eq(n.format_status, "migriert", where)
        for _, m in ipairs(n.messages) do t.ok(m.level ~= "fehler", where .. ": " .. m.text) end
        if d.id == "strecke" then
          -- die Node trug nur die Rolle Signal (Create regelt die Strecke jetzt allein): ihre Einrichtung ist verworfen, die Sicherung des Integrators behaelt sie
          t.ok(not d.fs.exists("/crn_data/config.lua"), where .. ": Einrichtung verworfen")
          t.ok(#dataformat.backups(d.fs) >= 1, where .. ": Sicherung vorhanden")
        else
          t.eq(n.status().kind, "ok", where .. ": " .. n.status().text)
          t.eq(ser.encode(storelib.new(d.fs).load("/crn_data/config.lua")), expect[d.id], where .. ": Konfiguration unveraendert")
        end
      end
      t.ok(b.node.roles.station ~= nil, version .. ": Bahnhof")
      local nodes = z.node.roles.zentrale.info().nodes
      t.ok(nodes.bahnhof, version .. ": die Leitstelle kennt den Bahnhof")
    end
  end },

  { "Schritt 1 -> 2 (Entwurf entfaellt): ein gespeicherter Entwurf wird verworfen, Anforderungskennung und Testsperre-Marke bleiben nutzbar, eine aktive Einrichtung bleibt unveraendert", function()
    local step = migrations.STEPS[1]
    t.eq(step.text, "Entwurf der Einrichtung verwerfen")
    local function run(config)
      local fs, store = world()
      store.save("/crn_data/format.lua", { format = 1, program = "0.1" })
      if config then store.save("/crn_data/config.lua", config) end
      -- nur dieser Schritt: spaetere Schritte (Rollen Signal und Knoten entfallen) wuerden die Marke der Testsperre wieder loeschen
      local status, _, dir, err = dataformat.check(fs, store, { format = 2, program = "0.2", migrations = { [1] = migrations.STEPS[1] } })
      return status, fs, store, dir, err
    end
    -- Entwurf mit Anforderungskennung und stehengebliebener Testsperre
    local draft = { status = "entwurf", node = { id = "N0007", name = "", claim = "c1-123456789012", claimed = true }, devices = { signal1 = { kind = "signal", device = "Create_Signal_9" } },
      tracks = {}, pruefung = { lauf = { device = "signal1", t = 42 }, devices = {} } }
    local status, fs, store, dir, err = run(draft)
    t.eq(status, "migriert", tostring(err))
    t.ok(not fs.exists("/crn_data/config.lua"), "der Entwurf ist weg")
    t.eq(store.load("/crn_data/anforderung.lua").claim, "c1-123456789012", "die Kennung im Verzeichnis bleibt")
    local mark = store.load("/crn_data/pruefmarke.lua")
    t.eq(mark.name, "Create_Signal_9"); t.eq(mark.device, "signal1")
    t.eq(store.load(dir .. "/config.lua").status, "entwurf", "die Sicherung behaelt ihn")
    t.eq(store.load("/crn_data/format.lua").format, 2)
    -- Entwurf ohne Kennung: nur weg
    status, fs, store = run({ status = "entwurf", node = { id = "x", name = "x" }, devices = {}, tracks = {} })
    t.eq(status, "migriert"); t.ok(not fs.exists("/crn_data/config.lua")); t.ok(not fs.exists("/crn_data/anforderung.lua")); t.ok(not fs.exists("/crn_data/pruefmarke.lua"))
    -- ungueltige Kennung wird nicht uebernommen
    status, fs = run({ status = "entwurf", node = { id = "x", claim = "../../boese kennung" }, devices = {}, tracks = {} })
    t.ok(not fs.exists("/crn_data/anforderung.lua"))
    -- aktive Einrichtung: unveraendert (auch die Datei selbst)
    local active = { status = "aktiv", revision = 4, node = { id = "n1", name = "Westbahnhof", roles = { "signal" }, claim = "c1-abcdefabcdef" }, devices = {}, tracks = {} }
    status, fs, store = run(active)
    t.eq(status, "migriert")
    t.eq(ser.encode(store.load("/crn_data/config.lua")), ser.encode(active), "aktive Einrichtung unveraendert")
    t.ok(not fs.exists("/crn_data/pruefmarke.lua") and not fs.exists("/crn_data/anforderung.lua"))
    -- aktive Einrichtung mit stehengebliebener Marke: die Marke zieht in ihre Datei um, der Rest bleibt
    local stuck = { status = "aktiv", revision = 4, node = { id = "n1", roles = { "signal" } }, devices = { signal1 = { kind = "signal", device = "Sig_A" } }, tracks = {}, pruefung = { lauf = { device = "signal1", t = 9 }, devices = {} } }
    status, fs, store = run(stuck)
    t.eq(status, "migriert")
    t.eq(store.load("/crn_data/pruefmarke.lua").name, "Sig_A")
    local c = store.load("/crn_data/config.lua")
    t.eq(c.status, "aktiv"); t.eq(c.pruefung.lauf, nil); t.eq(c.revision, 4)
    -- keine Einrichtung: nichts zu tun
    status, fs = run(nil)
    t.eq(status, "migriert"); t.ok(not fs.exists("/crn_data/config.lua"))
  end },

  { "Schritt 2 -> 3 (Freigabeausgang entfaellt): tracks.*.release faellt weg, eine offene Freigabe im Bahnhofszustand gilt als verbraucht", function()
    local step = migrations.STEPS[2]
    t.contains(step.text, "Freigabeausgang")
    local fs, store = world()
    store.save("/crn_data/format.lua", { format = 2, program = "0.2" })
    store.save("/crn_data/config.lua", { status = "aktiv", node = { id = "n1", roles = { "passagierbahnhof" } }, devices = {},
      tracks = { gleis1 = { name = "Gleis 1", release = { side = "back" } }, gleis2 = { name = "Gleis 2" } } })
    store.save("/crn_data/station.lua", { tracks = { gleis1 = { stay = 3, release_set = true, release_train = "GZ-1", release_stay = 3, release_order = "A-1" }, gleis2 = { stay = 1, release_set = false } } })
    local status, _, _, err = dataformat.check(fs, store, { format = 3, program = "0.3", migrations = { [1] = migrations.STEPS[1], [2] = step } })
    t.eq(status, "migriert", tostring(err))
    local c = store.load("/crn_data/config.lua")
    t.eq(c.tracks.gleis1.release, nil); t.eq(c.tracks.gleis1.name, "Gleis 1"); t.eq(c.tracks.gleis2.name, "Gleis 2")
    local st = store.load("/crn_data/station.lua")
    t.eq(st.tracks.gleis1.release_set, false); t.eq(st.tracks.gleis1.release_train, nil); t.eq(st.tracks.gleis1.stay, 3, "der Aufenthaltszaehler bleibt")
  end },

  { "Schritt 3 -> 4 (Rollen Signal und Knoten entfallen): reine Signal-/Knoten-Node verliert ihre Einrichtung, Bahnhof mit Signal-Rolle behaelt den Bahnhofsteil", function()
    local step = migrations.STEPS[3]
    t.contains(step.text, "Signal")
    local function run(config, extra_files)
      local fs, store = world()
      store.save("/crn_data/format.lua", { format = 3, program = "0.3" })
      if config then store.save("/crn_data/config.lua", config) end
      for name, value in pairs(extra_files or {}) do store.save("/crn_data/" .. name, value) end
      local status, _, dir, err = dataformat.check(fs, store, { format = 4, program = "0.4", migrations = { [1] = migrations.STEPS[1], [2] = migrations.STEPS[2], [3] = step } })
      return status, fs, store, dir, err
    end
    -- reine Signal-Node: Einrichtung und Rollendateien weg, die Sicherung behaelt sie
    local status, fs, store, dir, err = run({ status = "aktiv", node = { id = "strecke", roles = { "signal" } }, devices = { signal1 = { kind = "signal", device = "Sig_1" } },
      tracks = { gleis1 = { name = "Gleis 1", signals = { "signal1" }, observers = {} } } }, { ["sperren.lua"] = { x = 1 }, ["pruefmarke.lua"] = { device = "signal1" } })
    t.eq(status, "migriert", tostring(err))
    t.ok(not fs.exists("/crn_data/config.lua"), "Einrichtung verworfen")
    t.ok(not fs.exists("/crn_data/pruefmarke.lua"), "Testsperre-Marke weg")
    t.eq(store.load(dir .. "/config.lua").node.id, "strecke", "die Sicherung behaelt die Einrichtung")
    -- reiner Knoten
    status, fs = run({ status = "aktiv", node = { id = "tee", roles = { "knoten" } }, devices = {}, tracks = {}, junction = { connections = {}, moves = {}, conflicts = {} } })
    t.eq(status, "migriert"); t.ok(not fs.exists("/crn_data/config.lua"))
    -- Bahnhof mit zusaetzlicher Signal-Rolle: Rolle, Signale, Knotenangaben und Pruefergebnisse weg, Bahnhof bleibt
    status, fs, store = run({ status = "aktiv", node = { id = "bf", roles = { "passagierbahnhof", "signal" }, junction = "K0001", junction_rev = 2 },
      devices = { station1 = { kind = "station", device = "Create_Station_1" }, signal1 = { kind = "signal", device = "Sig_1" } },
      tracks = { gleis1 = { name = "Gleis 1", station = "station1", signals = { "signal1" }, observers = {}, order_ok = true, junction = { connection = "West", role = "ein" } } },
      junction = { connections = { West = true }, moves = {}, conflicts = {} }, tests = { ["lesen:signal1"] = { ok = true } } })
    t.eq(status, "migriert")
    local c = store.load("/crn_data/config.lua")
    t.eq(#c.node.roles, 1); t.eq(c.node.roles[1], "passagierbahnhof")
    t.eq(c.devices.signal1, nil); t.eq(c.devices.station1.device, "Create_Station_1")
    t.eq(c.tracks.gleis1.signals, nil); t.eq(c.tracks.gleis1.junction, nil); t.eq(c.tracks.gleis1.station, "station1")
    t.eq(c.junction, nil); t.eq(c.node.junction, nil)
    t.eq(next(c.tests), nil, "die Pruefergebnisse gelten neu")
    -- Bahnhof ohne Signal-Rolle bleibt unveraendert
    local plain = { status = "aktiv", node = { id = "bf2", roles = { "depot" } }, devices = {}, tracks = {} }
    status, fs, store = run(plain)
    t.eq(status, "migriert"); t.eq(ser.encode(store.load("/crn_data/config.lua")), ser.encode(plain))
  end },

  { "Schritt 4 -> 5 (Bahnhofsrollen zusammengelegt, Beobachter und Gleisrichtung entfallen): nur config.lua aendert sich, alles andere bleibt", function()
    local step = migrations.STEPS[4]
    t.contains(step.text, "Bahnhofsrollen")
    local function run(config)
      local fs, store = world()
      store.save("/crn_data/format.lua", { format = 4, program = "0.4" })
      if config then store.save("/crn_data/config.lua", config) end
      store.save("/crn_data/register.lua", { trains = { a = 1 } })
      local status, _, dir, err = dataformat.check(fs, store, { format = 5, program = "0.5", migrations = { [4] = step } })
      return status, fs, store, dir, err
    end
    -- Bahnhof und Depot auf einem Computer, mit Beobachter und Richtung: eine Rolle, Beobachter und Richtung weg, Station und Gleis bleiben
    local status, fs, store, dir, err = run({ status = "aktiv", node = { id = "bf", roles = { "passagierbahnhof", "depot", "anmeldung" } },
      devices = { station1 = { kind = "station", device = "Create_Station_1" }, observer1 = { kind = "observer", device = "Obs_1" } },
      tracks = { gleis1 = { name = "Gleis 1", station = "station1", observers = { "observer1" }, direction = "hin", length = 12 } } })
    t.eq(status, "migriert", tostring(err))
    local c = store.load("/crn_data/config.lua")
    t.eq(table.concat(c.node.roles, ","), "bahnhof,anmeldung")
    t.eq(c.devices.observer1, nil); t.eq(c.devices.station1.device, "Create_Station_1")
    t.eq(c.tracks.gleis1.observers, nil); t.eq(c.tracks.gleis1.direction, nil)
    t.eq(c.tracks.gleis1.station, "station1"); t.eq(c.tracks.gleis1.length, 12)
    t.eq(store.load("/crn_data/register.lua").trains.a, 1, "andere Dateien bleiben")
    t.ok(store.load(dir .. "/config.lua").node.roles[1] == "passagierbahnhof", "die Sicherung behaelt den alten Stand")
    -- eine Leitstelle und eine schon neue Einrichtung bleiben unveraendert; ohne Einrichtung gibt es nichts zu tun
    local fresh = { status = "aktiv", node = { id = "zentrale", roles = { "zentrale", "bahnhof" } }, devices = {}, tracks = {} }
    status, fs, store = run(fresh)
    t.eq(status, "migriert"); t.eq(ser.encode(store.load("/crn_data/config.lua")), ser.encode(fresh))
    status, fs = run(nil)
    t.eq(status, "migriert"); t.ok(not fs.exists("/crn_data/config.lua"))
  end },

  { "Schritt 5 -> 6 (Betriebsstellen entfallen): die Betriebsstellen-Kennung der Anmeldung faellt weg, alles andere bleibt", function()
    local step = migrations.STEPS[5]
    t.contains(step.text, "Betriebsstellen")
    local function run(config)
      local fs, store = world()
      store.save("/crn_data/format.lua", { format = 5, program = "0.5" })
      if config then store.save("/crn_data/config.lua", config) end
      store.save("/crn_data/register.lua", { trains = { a = 1 } })
      local status, _, dir, err = dataformat.check(fs, store, { format = 6, program = "0.6", migrations = { [5] = step } })
      return status, fs, store, dir, err
    end
    -- eine Anmeldung mit gespeicherter Betriebsstelle: die Kennung (BF0001) faellt weg, Name und Label bleiben
    local status, fs, store, dir, err = run({ status = "aktiv", node = { id = "anm", roles = { "anmeldung" }, station = "BF0001", label = "N0005 | ANM | BF0001", name = "Anmeldung Hauptbahnhof N0005" },
      devices = { station1 = { kind = "station", device = "Create_Station_1" } }, tracks = {} })
    t.eq(status, "migriert", tostring(err))
    local c = store.load("/crn_data/config.lua")
    t.eq(c.node.station, nil); t.eq(c.node.name, "Anmeldung Hauptbahnhof N0005"); t.eq(c.devices.station1.device, "Create_Station_1")
    t.eq(store.load("/crn_data/register.lua").trains.a, 1, "andere Dateien bleiben")
    t.eq(store.load(dir .. "/config.lua").node.station, "BF0001", "die Sicherung behaelt den alten Stand")
    -- ein Bahnhofsname (schon im neuen Format gespeichert) und eine Einrichtung ohne Anmeldung bleiben unveraendert
    local named = { status = "aktiv", node = { id = "anm2", roles = { "anmeldung" }, station = "Hauptbahnhof" }, devices = {}, tracks = {} }
    status, fs, store = run(named)
    t.eq(status, "migriert"); t.eq(ser.encode(store.load("/crn_data/config.lua")), ser.encode(named))
    local plain = { status = "aktiv", node = { id = "bf", roles = { "bahnhof" } }, devices = {}, tracks = {} }
    status, fs, store = run(plain)
    t.eq(status, "migriert"); t.eq(ser.encode(store.load("/crn_data/config.lua")), ser.encode(plain))
    status, fs = run(nil)
    t.eq(status, "migriert"); t.ok(not fs.exists("/crn_data/config.lua"))
  end },

  { "Form der gespeicherten Dateien ist festgehalten: aendert sie sich, muss ein Anpassungsschritt her oder die Festlegung bewusst erneuert werden", function()
    local h = H.new()
    local z = h.add_node({ id = "hauptstelle", roles = { "zentrale" }, tracks = {} })
    local netz = z.node.roles.zentrale.netz
    assert(netz.claim_node({ claim = "claim-golden-0001", role = "bahnhof" }))
    assert(netz.claim_node({ claim = "claim-golden-0002", role = "anmeldung", station = "Hauptbahnhof" }))
    h.add_node({ id = "depot", roles = { "bahnhof" }, central = "hauptstelle", label = "N0001 | BHF", claim = "claim-golden-0001",
      tracks = {
        { name = "Abstell 1", station_name = "Depot Gleis 1", length = 40 },
      } })
    h.add_node({ id = "bahnhof", roles = { "bahnhof" }, central = "hauptstelle",
      tracks = { { name = "Gleis 1", station_name = "Westbahnhof" } }, registration = "Gleis 1" })
    h.step(150)
    local lines = {}
    for _, d in ipairs(h.order) do
      local store = storelib.new(d.fs)
      local role = d.spec.roles[1]
      for path in pairs(d.fs._state.files) do
        local name = path:match("^crn_data/(.+%.lua)$")
        if name and not name:match("%.prev$") and name ~= "clock.lua" then
          local value = store.load("/" .. path)
          local label = name:gsub("^nodesich/.+%.lua$", "nodesich/*.lua")
          for _, line in ipairs(shape.lines(role .. ":" .. label, value)) do lines[#lines + 1] = line end
        end
      end
    end
    local seen, unique = {}, {}
    for _, line in ipairs(lines) do if not seen[line] then seen[line] = true; unique[#unique + 1] = line end end
    table.sort(unique)
    local header = "# Datenformat " .. migrations.FORMAT
    if os.getenv("CRN_UPDATE_GOLDEN") == "1" then
      local fh = assert(io.open(GOLDEN, "wb"))
      fh:write(header, "\n", table.concat(unique, "\n"), "\n")
      fh:close()
    end
    local fh = io.open(GOLDEN, "rb")
    t.ok(fh, "Festlegung fehlt: CRN_UPDATE_GOLDEN=1 lua tools/run_tests.lua integrator")
    local text = fh:read("*a")
    fh:close()
    local golden, first = {}, nil
    for line in text:gmatch("[^\n]+") do
      if not first then first = line else golden[#golden + 1] = line end
    end
    t.eq(first, header, "Die Festlegung gehoert zu einem anderen Datenformat: pruefen und erneuern (CRN_UPDATE_GOLDEN=1 lua tools/run_tests.lua integrator)")
    local want, have, plus, minus = {}, {}, {}, {}
    for _, line in ipairs(golden) do want[line] = true end
    for _, line in ipairs(unique) do have[line] = true; if not want[line] then plus[#plus + 1] = "+ " .. line end end
    for _, line in ipairs(golden) do if not have[line] then minus[#minus + 1] = "- " .. line end end
    if #plus + #minus > 0 then
      local shown = {}
      for i = 1, math.min(#plus, 8) do shown[#shown + 1] = plus[i] end
      for i = 1, math.min(#minus, 8) do shown[#shown + 1] = minus[i] end
      error("Die Form gespeicherter Dateien hat sich geaendert (" .. #plus .. " neu, " .. #minus .. " weg):\n  " .. table.concat(shown, "\n  ") ..
        "\nNur Felder ergaenzt, die das Programm beim Laden mit einer Vorgabe fuellt: Festlegung erneuern (CRN_UPDATE_GOLDEN=1 lua tools/run_tests.lua integrator)." ..
        "\nSonst (umbenannt, entfernt, Bedeutung geaendert): Schritt an src/core/migrations.lua anhaengen, siehe docs/DATENFORMAT.md.", 0)
    end
  end },
}
