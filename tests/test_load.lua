--[[
Purpose: Last mit 300 und mehr Signalen (Konzept 16, Stufe 9): 26 Signal-Nodes mit je 12 Signalen, mehrere Bahnhoefe und ein Knoten an einer Leitstelle. Geprueft werden Nachrichtenaufkommen je Sekunde, fehlerfreier Lauf, begrenzte Dateigroessen, Zahl der Geraeteaufrufe je Takt und dass jede Sperre in der Leitstelle ankommt. Dazu ein einziger Node mit 450 Signalen: seine Meldungen gehen in Teilen (keine Nachricht ueber der Funkgrenze), auch ueber einen Funkweg mit Verlust, Verdopplung und Vertauschung.
]]

local t = dofile("tests/lib/t.lua")
local H = dofile("tests/lib/harness.lua")

local SIGNALS_PER_NODE = 12
local SIGNAL_NODES = 26             -- 312 Signale

local function build()
  local h = H.new()
  local z = h.add_node({ id = "hauptstelle", roles = { "zentrale" }, tracks = {} })
  local nodes = {}
  for n = 1, SIGNAL_NODES do
    local tracks = {}
    for i = 1, SIGNALS_PER_NODE do
      tracks[#tracks + 1] = { name = "G" .. i, signals = { "Sig_" .. n .. "_" .. i } }
    end
    nodes[n] = h.add_node({ id = "strecke" .. n, roles = { "signal" }, central = "hauptstelle", tracks = tracks })
  end
  return h, z, nodes
end

-- ein einziger Signal-Node mit vielen Signalen in einem Gleis
local function single_big(count, bus, long_names)
  local h = H.new(bus and { bus = bus } or nil)
  local z = h.add_node({ id = "hauptstelle", roles = { "zentrale" }, tracks = {} })
  local sigs = {}
  local prefix = long_names and "Create_Signal_an_der_langen_Strecke_Nord_" or "Create_Signal_"
  for i = 1, count do sigs[i] = prefix .. i end
  local s = h.add_node({ id = "strecke", roles = { "signal" }, central = "hauptstelle", tracks = { { name = long_names and string.rep("Strecke_zwischen_Hauptbahnhof_und_Hafen_", 2) or "Strecke", signals = sigs } } })
  return h, z, s
end

-- keine Fehler- oder Warnmeldungen auf irgendeinem Computer
local function quiet(h)
  for _, d in ipairs(h.order) do
    for _, m in ipairs(d.node.messages) do
      t.ok(m.level == "info", d.id .. " meldet " .. m.level .. ": " .. m.text)
    end
  end
end

return {
  { "312 Signale an 26 Computern: Aufkommen, Fehlerfreiheit und Sperren kommen an", function()
    local h, z, nodes = build()
    local sent0 = h.bus.sent
    h.step(60)
    local zentrale = z.node.roles.zentrale
    t.eq(#zentrale.signal_overview(), SIGNAL_NODES * SIGNALS_PER_NODE)
    for _, d in ipairs(h.order) do
      for _, m in ipairs(d.node.messages) do
        t.ok(m.level == "info", d.id .. " meldet " .. m.level .. ": " .. m.text)
      end
    end
    -- Ruhephase: nur der Takt der Zustandsmeldungen laeuft
    local before = h.bus.sent
    h.step(60)
    local per_second = (h.bus.sent - before) / 60
    t.ok(per_second < 12, "Nachrichten je Sekunde im Ruhebetrieb: " .. per_second)
    -- eine Sperre auf einem fernen Signal erreicht die Leitstelle innerhalb weniger Sekunden
    local far = nodes[SIGNAL_NODES]
    far.node.roles.signal.lock("signal" .. SIGNALS_PER_NODE, "bediener", "Last")
    h.step(8)
    local found = false
    for _, row in ipairs(zentrale.signal_overview()) do
      if row.node == "strecke" .. SIGNAL_NODES and row.signal.forced then found = true end
    end
    t.ok(found, "Sperre sichtbar")
  end },
  { "Aenderungen vieler Signale gleichzeitig: Berichte bleiben begrenzt", function()
    local h, z, nodes = build()
    h.step(30)
    local before = h.bus.sent
    for n = 1, SIGNAL_NODES do
      for i = 1, SIGNALS_PER_NODE do nodes[n].world.set_base("Sig_" .. n .. "_" .. i, "RED") end
    end
    h.step(10)
    local burst = h.bus.sent - before
    -- jeder Node meldet seinen Zustand gesammelt: hoechstens einige Berichte je Node, nicht einen je Signal
    t.ok(burst <= SIGNAL_NODES * 6, "Berichte nach der Aenderung: " .. burst)
    local reds = 0
    for _, row in ipairs(z.node.roles.zentrale.signal_overview()) do if row.signal.state == "RED" then reds = reds + 1 end end
    t.eq(reds, SIGNAL_NODES * SIGNALS_PER_NODE)
  end },
  { "Dateigroessen bleiben begrenzt: Journal und Zustandsdateien nach langem Lauf", function()
    local h, z, nodes = build()
    local far = nodes[1]
    for round = 1, 150 do
      far.node.roles.signal.lock("signal1", "bediener", "Wechsel")
      far.node.roles.signal.unlock("signal1", "bediener")
      h.step(1)
    end
    local used = 0
    for _, f in ipairs(far.fs.list("/crn_data")) do
      local path = "/crn_data/" .. f
      if not far.fs.isDir(path) then used = used + far.fs.getSize(path) end
    end
    t.ok(used < 60000, "Datenverzeichnis des Signal-Nodes: " .. used .. " Byte")
    t.ok(far.node.journal.size() < 40000, "Journal: " .. far.node.journal.size())
  end },

  -- Ein einziger Signal-Node mit sehr vielen Signalen (Funknachrichten sind auf etwa 6000 Zeichen begrenzt) ------------------------------
  { "ein Node mit 450 Signalen: alle erreichen die Leitstelle in Teilen, ohne Fehler und mit begrenztem Aufkommen", function()
    local h, z, s = single_big(450)
    local hello_replies = 0
    local real_reply = z.node.reply
    z.node.reply = function(m, status, payload)
      if m.payload.kind == "hallo_signale" then hello_replies = hello_replies + 1 end
      return real_reply(m, status, payload)
    end
    local max_burst, last = 0, h.bus.sent
    for _ = 1, 40 do
      h.step(1)
      max_burst = math.max(max_burst, h.bus.sent - last)
      last = h.bus.sent
    end
    local overview = z.node.roles.zentrale.signal_overview()
    t.eq(#overview, 450)
    t.eq(overview[1].signal.id, "signal1")
    t.eq(overview[450].signal.id, "signal450", "Reihenfolge wie am Node")
    t.ok(overview[450].fresh, "frisch")
    t.eq(hello_replies, 1, "die Anmeldung in 15 Teilen wird einmal beantwortet (auf den ersten Teil)")
    t.ok(h.bus.max_len <= 6000, "groesste Nachricht: " .. h.bus.max_len)
    quiet(h)
    -- Ruhephase: ein vollstaendiger Durchlauf alle 5 s, in Teilen
    local before = h.bus.sent
    h.step(60)
    t.ok((h.bus.sent - before) / 60 < 4, "Nachrichten je Sekunde: " .. (h.bus.sent - before) / 60)
    -- der erste Takt traegt die Anmeldung (15 Teile), den ersten Durchlauf und die Konfigurationssicherung (je 6 Teile je Takt)
    t.ok(max_burst <= 32, "groesste Menge in einem Takt: " .. max_burst)
    quiet(h)
  end },
  { "ein Node mit 450 Signalen und langen Namen: zu grosse Berichtsteile werden geteilt, keine Nachricht ueber der Grenze", function()
    local h, z, s = single_big(450, nil, true)
    h.step(40)
    t.eq(#z.node.roles.zentrale.signal_overview(), 450)
    t.ok(h.bus.max_len <= 6000, "groesste Nachricht: " .. h.bus.max_len)
    t.ok(h.bus.max_len > 3000, "die Teile sind wirklich gross: " .. h.bus.max_len)
    quiet(h)
  end },
  { "ein Node mit 450 Signalen: eine Aenderung meldet nur den betroffenen Teil", function()
    local h, z, s = single_big(450)
    h.step(20)
    -- gleich nach einem vollstaendigen Durchlauf ist die Leitung ruhig
    local calm
    for _ = 1, 12 do
      local before = h.bus.sent
      h.step(1)
      if h.bus.sent == before then calm = true break end
    end
    t.ok(calm, "ruhiger Takt gefunden")
    local before = h.bus.sent
    s.world.set_base("Create_Signal_300", "RED")
    h.step(1)
    local used = h.bus.sent - before
    t.ok(used >= 1 and used <= 2, "Nachrichten fuer eine Aenderung: " .. used)
    local row = z.node.roles.zentrale.signal_overview()[300]
    t.eq(row.signal.id, "signal300"); t.eq(row.signal.state, "RED")
    local other = z.node.roles.zentrale.signal_overview()[299]
    t.eq(other.signal.id, "signal299"); t.eq(other.signal.state, "GREEN")
  end },
  { "ein Node mit 450 Signalen: Sperre auf dem letzten Signal kommt in der Leitstelle an", function()
    local h, z, s = single_big(450)
    h.step(15)
    local zentrale = z.node.roles.zentrale
    s.node.roles.signal.lock("signal450", "bediener", "Last")
    h.step(3)
    t.eq(zentrale.signal_overview()[450].signal.forced, true)
    -- und die Leitstelle kann sie von dort aus wieder loesen
    local ok = zentrale.signal_lock("strecke", "signal450", "loesen")
    t.eq(ok, true)
    h.step(3)
    t.eq(zentrale.signal_overview()[450].signal.forced, false)
  end },
  { "ein Node mit 450 Signalen ueber einen verlustbehafteten Funkweg: Vollstaendigkeit nach kurzer Zeit", function()
    local h, z, s = single_big(450, { seed = 7, drop = 0.1, dup = 0.1, reorder = true })
    h.step(90)
    local zentrale = z.node.roles.zentrale
    t.eq(#zentrale.signal_overview(), 450, "alle Signale bekannt")
    for _, n in ipairs({ 1, 41, 80, 200, 333, 450 }) do s.world.set_base("Create_Signal_" .. n, "RED") end
    h.step(25)
    local reds = 0
    for _, row in ipairs(zentrale.signal_overview()) do
      if row.signal.state == "RED" then reds = reds + 1 end
    end
    t.eq(reds, 6, "alle sechs Aenderungen angekommen")
    t.ok(h.bus.max_len <= 6000, "groesste Nachricht: " .. h.bus.max_len)
    quiet(h)
  end },
  { "Leitstelle: Berichtsteile in beliebiger Reihenfolge, doppelt und mit Luecken; eine kuerzere Liste schneidet den Rest ab", function()
    local h = H.new()
    local z = h.add_node({ id = "hauptstelle", roles = { "zentrale" }, tracks = {} })
    local s = h.add_node({ id = "strecke", roles = { "signal" }, central = "hauptstelle", tracks = { { name = "G", signals = { "A" } } } })
    local zentrale = z.node.roles.zentrale
    local function part(first, total, ids)
      local list = {}
      for i, id in ipairs(ids) do list[i] = { id = id, track_name = "G", available = true, state = "GREEN", forced = false, owners = {} } end
      local m = s.node.factory.make("meldung", "hauptstelle", { kind = "signale", node = "strecke", first = first, total = total, signals = list, t = 1 })
      z.node.roles.zentrale.on_message(m, "ok")
    end
    local function ids()
      local out = {}
      for _, row in ipairs(zentrale.signal_overview()) do out[#out + 1] = row.signal.id end
      return table.concat(out, ",")
    end
    part(4, 6, { "d", "e", "f" })                            -- spaeter Teil zuerst: Luecken bleiben leer
    t.eq(ids(), "d,e,f")
    part(1, 6, { "a", "b", "c" })
    t.eq(ids(), "a,b,c,d,e,f")
    part(1, 6, { "a", "b", "c" })                            -- doppelt
    t.eq(ids(), "a,b,c,d,e,f")
    part(1, 2, { "a", "b" })                                 -- Node hat jetzt nur noch zwei Signale
    t.eq(ids(), "a,b")
    part(1, 5, { "a", "b" })                                 -- waechst wieder: die frueheren d,e duerfen nicht wieder auftauchen
    t.eq(ids(), "a,b")
    part(1, 99999, { "x" })                                  -- unsinnige Angaben aendern nichts
    part(0, 3, { "x" })
    part(1.5, 3, { "x" })
    t.eq(ids(), "a,b")
  end },
  { "Konfigurationssicherung eines Nodes mit 450 Signalen: Teile, Vollstaendigkeit, Ersatz holt sie wieder ab", function()
    local h, z, s = single_big(450)
    h.step(40)
    local zentrale = z.node.roles.zentrale
    local backup = zentrale.backup_of("strecke")
    t.ok(backup, "Sicherung angekommen")
    t.eq(backup.revision, s.node.config.revision)
    t.eq(backup.config, require("core.ser").encode(s.node.config), "unveraenderter Inhalt")
    t.ok(h.bus.max_len <= 6000, "groesste Nachricht: " .. h.bus.max_len)
    quiet(h)
    -- Ersatzcomputer: die Sicherung kommt in Teilen zurueck
    z.node.roles.zentrale.retire("strecke")
    local blank = h.add_blank({ id = "neu" })
    blank.node.fetch_config("hauptstelle", "strecke")
    h.step(6)
    local state = blank.node.fetch_state
    t.eq(state.kind, "ok", state.text)
    t.eq(state.config.node.id, "strecke")
    t.eq(#state.config.devices ~= nil and 1 or 0, 1)
    local count = 0
    for _ in pairs(state.config.devices) do count = count + 1 end
    t.eq(count, 450)
    t.ok(h.bus.max_len <= 6000, "groesste Nachricht: " .. h.bus.max_len)
  end },
  { "Konfigurationssicherung: fehlt ein Teil, antwortet die Leitstelle 'unvollstaendig' und nichts Halbes wird gespeichert", function()
    local h = H.new()
    local z = h.add_node({ id = "hauptstelle", roles = { "zentrale" }, tracks = {} })
    local s = h.add_node({ id = "strecke", roles = { "signal" }, central = "hauptstelle", tracks = { { name = "G", signals = { "A" } } } })
    h.step(1)
    local zentrale = z.node.roles.zentrale
    local replies = {}
    local real_reply = z.node.reply
    z.node.reply = function(m, status, payload) replies[#replies + 1] = status return real_reply(m, status, payload) end
    local function part(i, n, text, rev)
      local m = s.node.factory.make("meldung", "hauptstelle", { kind = "konfig", node = "zwei", revision = rev or 5, part = i, parts = n, config = text })
      zentrale.on_config(m)
    end
    part(1, 3, "{a"); part(3, 3, "c}")
    t.eq(replies[#replies], "unvollstaendig")
    t.eq(zentrale.backup_of("zwei"), nil, "nichts gespeichert")
    part(1, 3, "{a"); part(2, 3, "b"); part(3, 3, "c}")
    t.eq(replies[#replies], "ok")
    t.eq(zentrale.backup_of("zwei").config, "{abc}")
    -- ungueltige Angaben werden abgelehnt
    part(1, 101, "x")
    t.eq(replies[#replies], "abgelehnt")
    part(0, 2, "x")
    t.eq(replies[#replies], "abgelehnt")
    z.node.reply = real_reply
  end },
  { "Konfigurationssicherung: ein verlorener Teil wird nicht als angekommen gewertet, der Node sendet nach einer Weile alles erneut", function()
    local h, z, s = single_big(120)
    local zentrale = z.node.roles.zentrale
    local real, dropped = zentrale.on_config, 0
    zentrale.on_config = function(m)
      if m.payload.part == 3 and dropped == 0 then dropped = 1 return end
      return real(m)
    end
    h.step(20)
    t.eq(dropped, 1, "ein Teil ging verloren")
    t.eq(zentrale.backup_of("strecke"), nil, "unvollstaendig: nichts gespeichert")
    h.step(40)
    t.ok(zentrale.backup_of("strecke"), "nach der Wiederholung angekommen")
    quiet(h)
  end },
  { "eine zu grosse Konfiguration wird nicht gesendet: eine einzige Warnung, kein Fehler im Funk", function()
    local h, z, s = single_big(2600)
    h.step(30)                                  -- ein Durchlauf in Teilen: je Takt hoechstens 6 Teile
    local warned, errors = 0, 0
    for _, m in ipairs(s.node.messages) do
      if m.level == "fehler" then errors = errors + 1 end
      if m.level == "warnung" and m.text:find("zu gross", 1, true) then warned = warned + 1 end
    end
    t.eq(errors, 0); t.eq(warned, 1)
    t.eq(z.node.roles.zentrale.backup_of("strecke"), nil)
    t.eq(#z.node.roles.zentrale.signal_overview(), 2600, "die Signale selbst werden trotzdem gemeldet")
    t.ok(h.bus.max_len <= 6000, "groesste Nachricht: " .. h.bus.max_len)
  end },
}
