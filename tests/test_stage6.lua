--[[
Purpose: Signal- und Knoten-Node im Testnetz: Zusatzsperren mit mehreren Besitzern, bestaetigtes Setzen, fremde Sperren bleiben stehen, Abgleich nach Ausfall, Meldungen an die Leitstelle, T-Kreuzung mit zwei Einfahrten und gemeinsamem Ausgang, Raeumung nur durch Nachweis, kein Freigeben durch Zeitablauf, Neustart mit gespeichertem Stand.
]]

local t = dofile("tests/lib/t.lua")
local H = dofile("tests/lib/harness.lua")

-- T-Kreuzung: West und Sued fahren nach Ost; Ost faehrt nach West. Alle drei Einfahrten/Ausfahrten mit Beobachter.
local function build()
  local h = H.new()
  local z = h.add_node({ id = "hauptstelle", roles = { "zentrale" }, tracks = {} })
  local k = h.add_node({
    id = "tee", roles = { "knoten" }, central = "hauptstelle",
    junction = {
      connections = { West = true, Ost = true, Sued = true },
      moves = { { from = "West", to = "Ost" }, { from = "Sued", to = "Ost" }, { from = "Ost", to = "West" } },
      conflicts = { { moves = { 1, 3 } } },
    },
    tracks = {
      { name = "West ein", signals = { "Sig_West" }, observers = { "Obs_West_ein" }, junction = { connection = "West", role = "ein" } },
      { name = "Sued ein", signals = { "Sig_Sued" }, observers = { "Obs_Sued_ein" }, junction = { connection = "Sued", role = "ein" } },
      { name = "Ost ein", signals = { "Sig_Ost" }, observers = { "Obs_Ost_ein" }, junction = { connection = "Ost", role = "ein" } },
      { name = "Ost aus", observers = { "Obs_Ost_aus" }, junction = { connection = "Ost", role = "aus" } },
      { name = "West aus", observers = { "Obs_West_aus" }, junction = { connection = "West", role = "aus" } },
    },
  })
  return h, z, k
end

local function dev(k, name) return k.world.devices[name].state end
local function forced(k, name) return dev(k, name).forced end

-- Beobachter: Spitze am Beobachter (passing) und danach Ende vorbei (passed), wie die Ereignisse laut Messung
local function front(k, obs, train)
  dev(k, obs).passing = train
  k.world.queue[#k.world.queue + 1] = { "train_passing", obs, train }
end
local function tail(k, obs, train)
  dev(k, obs).passing = nil
  k.world.queue[#k.world.queue + 1] = { "train_passed", obs, train }
end

local function single_signal_node()
  local h = H.new()
  local z = h.add_node({ id = "hauptstelle", roles = { "zentrale" }, tracks = {} })
  local s = h.add_node({
    id = "strecke", roles = { "signal" }, central = "hauptstelle",
    tracks = {
      { name = "Nord", signals = { "Sig_N" }, observers = { "Obs_N" } },
      { name = "Sued", signals = { "Sig_S1", "Sig_S2" } },
    },
  })
  return h, z, s
end

return {
  -- Signal-Node -------------------------------------------------------------------------------------------------------------------------
  { "Signal-Node meldet Signale an die Leitstelle und zeigt sie auf der Seite", function()
    local h, z, s = single_signal_node()
    h.step(12)
    local overview = z.node.roles.zentrale.signal_overview()
    t.eq(#overview, 3)
    t.eq(overview[1].signal.available, true)
    t.eq(overview[1].signal.forced, false)
    local zv = H.open_page(z, "signale")
    t.ok(z.has(zv, "strecke / Nord"), z.text(zv))
    local sv = H.open_page(s, "signale")
    t.ok(s.has(sv, "Nord"), s.text(sv))
  end },
  { "Sperre mit mehreren Besitzern: physisch gesperrt, solange einer sie haelt; Aufheben ist nur die eigene Sperre", function()
    local h, z, s = single_signal_node()
    h.step(3)
    local sig = s.node.roles.signal
    t.eq(sig.lock("signal1", "knoten", "Einfahrt"), true)
    t.eq(forced(s, "Sig_N"), true)
    t.eq(sig.lock("signal1", "bediener", "Wartung"), true)
    t.eq(sig.unlock("signal1", "knoten"), true)
    t.eq(forced(s, "Sig_N"), true, "der Bediener haelt noch")
    t.eq(sig.unlock("signal1", "bediener"), true)
    t.eq(forced(s, "Sig_N"), false)
    t.eq(sig.unlock("signal1", "bediener"), true, "wiederholbar")
    local ok, err = sig.lock("Gibtsnicht", "x", "y")
    t.eq(ok, nil); t.contains(err, "unbekannt")
  end },
  { "Sperre gilt nur nach dem Zuruecklesen: reagiert das Signal nicht, ist sie nicht bestaetigt", function()
    local h, z, s = single_signal_node()
    h.step(3)
    s.world.devices["Sig_N"].state.ignore_hold = true
    local ok, err = s.node.roles.signal.lock("signal1", "bediener", "x")
    t.eq(ok, nil); t.contains(err, "nicht bestaetigt")
  end },
  { "Aufheben nimmt nie 'gruen' vor: eine native Rotursache bleibt", function()
    local h, z, s = single_signal_node()
    h.step(3)
    s.world.set_base("Sig_N", "RED")
    s.node.roles.signal.lock("signal1", "knoten", "x")
    s.node.roles.signal.unlock("signal1", "knoten")
    t.eq(forced(s, "Sig_N"), false)
    t.eq(s.world.devices["Sig_N"].methods.getState(), "RED", "die native Rotursache gilt weiter")
  end },
  { "fremde Sperre wird gemeldet und nie von selbst aufgehoben; Aufheben nur nach Bestaetigung", function()
    local h, z, s = single_signal_node()
    h.step(3)
    s.world.devices["Sig_N"].methods.setForcedRed(true)
    h.step(15)
    local states = s.node.roles.signal.states()
    t.eq(states[1].foreign, true)
    t.eq(forced(s, "Sig_N"), true, "bleibt gesperrt")
    local overview = z.node.roles.zentrale.signal_overview()
    t.eq(overview[1].signal.foreign, true)
    local v = H.open_page(s, "signale")
    s.tap(v, "act:aufheben")
    t.eq(forced(s, "Sig_N"), true, "erster Druck sperrt nichts frei")
    s.tap(v, "act:aufheben")
    t.eq(forced(s, "Sig_N"), false)
  end },
  { "verlorene eigene Sperre wird schuetzend neu gesetzt, ohne dass etwas freigegeben wird", function()
    local h, z, s = single_signal_node()
    h.step(3)
    s.node.roles.signal.lock("signal1", "knoten", "x")
    s.world.devices["Sig_N"].state.forced = false          -- Signalblock wurde neu geladen
    h.step(4)
    t.eq(forced(s, "Sig_N"), true)
  end },
  { "Neustart des Signal-Nodes: eigene Sperre bleibt, kein pauschales Freigeben", function()
    local h, z, s = single_signal_node()
    h.step(3)
    s.node.roles.signal.lock("signal1", "knoten", "x")
    h.restart("strecke")
    t.eq(forced(s, "Sig_N"), true)
    t.eq(s.node.roles.signal.states()[1].owners[1], "knoten")
    t.eq(s.node.roles.signal.unlock("signal1", "knoten"), true)
    t.eq(forced(s, "Sig_N"), false)
  end },
  { "Wiederanlauf: begonnenes Aufheben ohne Besitzer wird zu Ende gebracht", function()
    local h, z, s = single_signal_node()
    h.step(3)
    s.node.roles.signal.lock("signal1", "knoten", "x")
    -- Absturz nach dem Entfernen des Besitzers, vor dem Loesen: Journal hat die Absicht
    s.node.journal.begin("sperre.loesen", { signal = "signal1", owner = "knoten" })
    local file = s.fs.open("/crn_data/sperren.lua", "w")
    file.write("return { locks = {} }")
    file.close()
    h.restart("strecke")
    t.eq(forced(s, "Sig_N"), false, "die begonnene Aufhebung wurde vollendet")
    t.eq(#s.node.journal.pending(), 0)
  end },
  { "Leitstelle setzt und hebt Sperren ueber die Seite Signale", function()
    local h, z, s = single_signal_node()
    h.step(12)
    local v = H.open_page(z, "signale")
    z.tap(v, "act:sig_sperre")
    h.step(3)
    t.eq(forced(s, "Sig_N"), true)
    z.node.render()
    t.ok(z.has(v, "Sperre gesetzt"), z.text(v))
    h.step(8)
    z.node.render()
    t.ok(z.has(v, "von bediener"), z.text(v))
    z.tap(v, "act:sig_aufheben")
    h.step(3)
    t.eq(forced(s, "Sig_N"), false)
  end },
  { "INVALID wird als Stoerung gemeldet", function()
    local h, z, s = single_signal_node()
    h.step(3)
    s.world.set_base("Sig_N", "INVALID")
    h.step(8)
    local found = false
    for _, m in ipairs(z.node.messages) do if m.text:find("INVALID", 1, true) then found = true end end
    t.ok(found, "Leitstelle meldet INVALID")
    t.eq(s.node.roles.signal.states()[1].invalid, true)
  end },

  -- Knoten ---------------------------------------------------------------------------------------------------------------------------------
  { "Start: alle Einfahrten sind zusaetzlich gesperrt", function()
    local h, z, k = build()
    h.step(3)
    t.eq(forced(k, "Sig_West"), true)
    t.eq(forced(k, "Sig_Sued"), true)
    t.eq(forced(k, "Sig_Ost"), true)
    t.eq(#k.node.roles.knoten.areas.status(), 0)
  end },
  { "T-Kreuzung: zwei Zuege aus West und Sued, der zweite faehrt erst nach Raeumung durch den ersten ein", function()
    local h, z, k = build()
    h.step(3)
    front(k, "Obs_West_ein", "Zug A")
    h.step(1)
    front(k, "Obs_Sued_ein", "Zug B")
    h.step(2)
    t.eq(forced(k, "Sig_West"), false, "Zug A wird freigegeben")
    t.eq(forced(k, "Sig_Sued"), true, "Zug B muss warten")
    -- A faehrt ein: Einfahrt wird wieder gesperrt
    tail(k, "Obs_West_ein", "Zug A")
    h.step(2)
    t.eq(forced(k, "Sig_West"), true)
    t.eq(forced(k, "Sig_Sued"), true, "A ist im Bereich")
    -- Spitze von A am Ausgang: noch nicht frei (langer Zug)
    front(k, "Obs_Ost_aus", "Zug A")
    h.step(3)
    t.eq(forced(k, "Sig_Sued"), true, "Ausfahrt der Spitze ist keine Raeumung")
    tail(k, "Obs_Ost_aus", "Zug A")
    h.step(3)
    t.eq(forced(k, "Sig_Sued"), false, "Raeumung nachgewiesen: Zug B darf")
    tail(k, "Obs_Sued_ein", "Zug B")
    h.step(2)
    t.eq(forced(k, "Sig_Sued"), true)
  end },
  { "ohne Raeumungsnachweis keine Freigabe, auch nicht nach langer Zeit; der Bediener entscheidet nach Pruefung", function()
    local h, z, k = build()
    h.step(3)
    front(k, "Obs_West_ein", "Zug A"); h.step(2)
    tail(k, "Obs_West_ein", "Zug A"); h.step(2)
    front(k, "Obs_Sued_ein", "Zug B"); h.step(2)
    t.eq(forced(k, "Sig_Sued"), true)
    h.step(1000)
    t.eq(forced(k, "Sig_Sued"), true, "Zeitablauf gibt nichts frei")
    local status = k.node.roles.knoten.areas.status()
    t.eq(status[1].long, true)
    local v = H.open_page(k, "knoten")
    t.ok(k.has(v, "LANGE BELEGT"), k.text(v))
    k.tap(v, "act:aufloesen")
    t.eq(forced(k, "Sig_Sued"), true, "erster Druck loest nichts")
    k.tap(v, "act:aufloesen")
    h.step(3)
    t.eq(forced(k, "Sig_Sued"), false, "nach Pruefung des Bedieners darf B")
    t.contains(k.node.roles.knoten.areas.history()[1].how, "Bediener")
  end },
  { "Einfahrt ohne Freigabe wird gemeldet und sperrt Konflikte", function()
    local h, z, k = build()
    h.step(3)
    tail(k, "Obs_West_ein", "Zug A")       -- fuhr ein, obwohl gesperrt
    h.step(2)
    local found = false
    for _, m in ipairs(k.node.messages) do if m.text:find("eingefahren, ohne dass die Einfahrt freigegeben", 1, true) then found = true end end
    t.ok(found)
    front(k, "Obs_Sued_ein", "Zug B"); h.step(3)
    t.eq(forced(k, "Sig_Sued"), true)
  end },
  { "verlorenes Ereignis: die Abfrage der Beobachter holt den Zug trotzdem ab", function()
    local h, z, k = build()
    h.step(3)
    dev(k, "Obs_West_ein").passing = "Zug A"       -- Zug steht am Beobachter, ohne dass ein Ereignis ankam
    h.step(3)
    t.eq(forced(k, "Sig_West"), false)
    dev(k, "Obs_West_ein").passing = nil           -- und ist weggefahren, ohne Ereignis
    h.step(3)
    t.eq(forced(k, "Sig_West"), true, "Einfahrt wieder gesperrt")
    t.eq(k.node.roles.knoten.areas.status()[1].state, "eingefahren")
  end },
  { "unabhaengige Einfahrten sind gleichzeitig frei (West->Ost gegen Sued->Ost sind es nicht)", function()
    local h, z, k = build()
    h.step(3)
    front(k, "Obs_West_ein", "Zug A"); front(k, "Obs_Ost_ein", "Zug C")
    h.step(3)
    t.eq(forced(k, "Sig_West"), false)
    t.eq(forced(k, "Sig_Ost"), true, "Ost->West gegen West->Ost: ausdruecklicher Konflikt")
  end },
  { "Neustart des Knotens mit Zug im Bereich: Einfahrten gesperrt, wartender Zug bleibt gesperrt, Raeumung wirkt danach", function()
    local h, z, k = build()
    h.step(3)
    front(k, "Obs_West_ein", "Zug A"); h.step(2)
    tail(k, "Obs_West_ein", "Zug A"); h.step(2)
    front(k, "Obs_Sued_ein", "Zug B"); h.step(2)
    h.restart("tee")
    t.eq(forced(k, "Sig_West"), true)
    t.eq(forced(k, "Sig_Sued"), true, "nach dem Neustart nichts leichtfertig freigeben")
    tail(k, "Obs_Ost_aus", "Zug A"); h.step(3)
    t.eq(forced(k, "Sig_Sued"), false)
  end },
  { "Neustart: eine freigegebene, aber noch nicht eingefahrene Einfahrt bleibt offen", function()
    local h, z, k = build()
    h.step(3)
    front(k, "Obs_West_ein", "Zug A"); h.step(3)
    t.eq(forced(k, "Sig_West"), false)
    h.restart("tee")
    t.eq(forced(k, "Sig_West"), false, "die Freigabe wurde nicht stillschweigend zurueckgenommen")
    t.eq(k.node.roles.knoten.areas.status()[1].state, "freigegeben")
  end },
  { "Knoten meldet seine Nutzungen an die Leitstelle", function()
    local h, z, k = build()
    h.step(3)
    front(k, "Obs_West_ein", "Zug A"); h.step(8)
    local info = z.node.roles.zentrale.info()
    t.eq(info.knoten_state.tee.uses[1].train, "Zug A")
    t.eq(info.knoten_state.tee.uses[1].state, "freigegeben")
  end },
}
