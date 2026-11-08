--[[
Purpose: Vorlaeufige Kennung eines noch nicht eingerichteten Computers: sie ist je Computer und Start eindeutig, damit mehrere frische Computer nacheinander oder gleichzeitig eingerichtet werden koennen, ohne dass die Leitstelle gemerkte Antworten eines anderen Computers (zum Beispiel dessen Node-Kennung) wiederholt oder sie als Doppelgaenger abweist.
]]

local t = dofile("tests/lib/t.lua")
local H = dofile("tests/lib/harness.lua")
local ser = require("core.ser")

local function setup()
  local h = H.new()
  local z = h.add_node({ id = "hauptstelle", roles = { "zentrale" }, tracks = {} })
  local netz = z.node.roles.zentrale.netz
  netz.add_area({ name = "West-Ost", ends = { "Westbahnhof", "Ostbahnhof" }, count = 2, pattern = "gegenlaeufig" })
  return h, z, netz
end

-- ein frischer Computer bis zum Bildschirm "Geraete waehlen" (Kennung wurde angefordert)
local function join(h, id, opts)
  opts = opts or {}
  local d = h.add_blank({ id = id })
  d.world.add_station("Create_Station_1", { station_name = "Hof" })
  h.step(1)
  local v = d.view()
  v.set_page("einrichtung")
  d.tap(v, "act:start")
  d.tap(v, "sel:modus:2"); d.tap(v, "act:weiter")
  h.step(5); d.node.render()
  d.tap(v, "sel:netzwahl:1"); d.tap(v, "act:weiter")
  d.tap(v, "sel:rollen:2"); d.tap(v, "act:weiter")
  h.step(3); d.node.render()
  d.tap(v, "sel:bereich:1")
  h.step(3); d.node.render()
  d.tap(v, "act:weiter"); d.tap(v, "act:weiter")
  h.step(3); d.node.render()
  return d, v, d.node.setup.session()
end

return {
  { "Zwei frische Computer nacheinander: jeder bekommt seine eigene Node-Kennung", function()
    local h, z, netz = setup()
    local a, va, sa = join(h, "a")
    t.eq(sa.screen, "3.geraete", a.text(va))
    t.eq(sa.wiz.claimed_id, "N0001")
    h.step(60)
    local b, vb, sb = join(h, "b")
    t.eq(sb.screen, "3.geraete", b.text(vb))
    t.eq(sb.wiz.claimed_id, "N0002", "der zweite Computer bekommt nicht noch einmal N0001")
    t.ok(netz.node("N0001") and netz.node("N0002"), "beide stehen im Verzeichnis")
    t.ok(netz.node("N0001").claim ~= netz.node("N0002").claim)
    -- ein dritter nach noch laengerer Zeit
    h.step(200)
    local c, vc, sc = join(h, "c")
    t.eq(sc.wiz.claimed_id, "N0003")
  end },
  { "Zwei frische Computer gleichzeitig (innerhalb weniger Sekunden): beide werden bedient, keiner gilt als Doppelgaenger", function()
    local h, z, netz = setup()
    local a, va, sa = join(h, "a")
    local b, vb, sb = join(h, "b")                 -- sofort danach, ohne Pause
    t.eq(sa.wiz.claimed_id, "N0001")
    t.eq(sb.wiz.claimed_id, "N0002")
    t.eq(sb.screen, "3.geraete", b.text(vb))
    for _, m in ipairs(z.node.messages) do t.ok(not m.text:find("Zwei Computer melden sich", 1, true), m.text) end
  end },
  { "Die vorlaeufige Kennung enthaelt die Computer-Kennung und aendert sich bei jedem Start", function()
    local h, z, netz = setup()
    local d = h.add_blank({ id = "a" })
    d.node.search_networks(); h.step(5)
    local first = d.node.replace_factory.node_id
    t.ok(first:match("^neu%-"), first)
    d.restart()
    d.node.search_networks(); h.step(5)
    local second = d.node.replace_factory.node_id
    t.ok(second ~= first, "nach dem Neustart eine andere Kennung: " .. first .. " / " .. second)
    -- ein anderer Computer hat eine andere
    local e = h.add_blank({ id = "e" })
    e.node.search_networks(); h.step(5)
    t.ok(e.node.replace_factory.node_id ~= second)
    t.ok(e.node.replace_factory.node_id ~= first)
    -- Sonderzeichen (zum Beispiel ":" oder Leerzeichen) werden entfernt, sie wuerden die Nachrichtenkennung zerstoeren
    local g = h.add_blank({ id = "g" })
    g.env.unique = function() return "9:ab c" end
    g.node.search_networks(); h.step(5)
    t.eq(g.node.replace_factory.node_id, "neu-9abc")
    t.ok(#g.node.search_status().networks >= 1, "die Suche funktioniert mit dieser Kennung")
    -- ohne Eindeutigkeitsfunktion in der Umgebung (aeltere Umgebung): Rueckfall auf den Startzaehler
    local f = h.add_blank({ id = "f" })
    f.env.unique = nil
    f.node.search_networks(); h.step(5)
    t.eq(f.node.replace_factory.node_id, "neu-" .. f.node.clock.boot_id())
  end },
  { "Ein Computer nach Neustart und abgebrochener Einrichtung fragt neu an (keine gemerkte alte Antwort) und behaelt dieselbe Kennung, es entsteht keine zweite", function()
    local h, z, netz = setup()
    local a, va, sa = join(h, "a")
    t.eq(sa.wiz.claimed_id, "N0001")
    -- der Computer wird neu gestartet (Einrichtung abgebrochen) und beginnt von vorn: dieselbe Anforderung dieses Computers, also dieselbe Kennung
    a.restart()
    local v2 = a.view()
    v2.set_page("einrichtung")
    a.tap(v2, "act:start")
    a.tap(v2, "sel:modus:2"); a.tap(v2, "act:weiter")
    h.step(5); a.node.render()
    a.tap(v2, "sel:netzwahl:1"); a.tap(v2, "act:weiter")
    a.tap(v2, "sel:rollen:2"); a.tap(v2, "act:weiter")
    h.step(3); a.node.render()
    a.tap(v2, "sel:bereich:1")
    h.step(3); a.node.render()
    a.tap(v2, "act:weiter"); a.tap(v2, "act:weiter")
    h.step(3); a.node.render()
    local s2 = a.node.setup.session()
    t.eq(s2.screen, "3.geraete", a.text(v2))
    t.eq(s2.wiz.claimed_id, "N0001", "die Anforderung dieses Computers bleibt, die Leitstelle fuehrt keine zweite Kennung")
    t.eq(#netz.nodes(), 1)
  end },
  { "Wird eine Antwort verworfen, nennt die Meldung den Grund", function()
    local h, z, netz = setup()
    local d = h.add_blank({ id = "a" })
    local v = d.view()
    d.node.directory_areas("hauptstelle")
    -- die echte Antwort wird abgefangen und mit falschem Ziel erneut zugestellt
    local fake
    h.bus.filter = function(from, to, text, proto)
      if to ~= d.cid then return false end
      local ok, m = pcall(ser.decode, text)
      if ok and type(m) == "table" and m.messageType == "bestaetigung" then
        m.targetNodeId = "andere"
        fake = { "rednet_message", from, ser.encode(m), proto }
        return true
      end
      return false
    end
    h.step(1)
    h.bus.filter = nil
    t.ok(fake, "Antwort abgefangen")
    table.insert(h.bus.nodes[d.cid].queue, fake)
    h.step(2)
    h.step(12)
    local st = d.node.directory_status()
    t.eq(st.kind, "halt")
    t.contains(st.text, "antwortet nicht")
    t.contains(st.text, "Antwort verworfen: wrong_target")
    -- eine neue Frage loescht den Hinweis: antwortet die Leitstelle jetzt gar nicht, steht kein veralteter Grund da
    z.node.handle = function() end
    d.node.directory_reset()
    d.node.directory_areas("hauptstelle")
    h.step(12)
    local again = d.node.directory_status()
    t.contains(again.text, "antwortet nicht")
    t.ok(not again.text:find("verworfen", 1, true), again.text)
  end },
  { "Drei frische Computer nacheinander unter Verlust, Doppelung und Vertauschung: je eine eigene Kennung, keine doppelt vergeben", function()
    for seed = 1, 6 do
      local h = H.new({ seed = seed, drop = 0.25, dup = 0.3, reorder = true })
      local z = h.add_node({ id = "hauptstelle", roles = { "zentrale" }, tracks = {} })
      local netz = z.node.roles.zentrale.netz
      netz.add_area({ name = "West-Ost", ends = { "Westbahnhof", "Ostbahnhof" }, count = 2, pattern = "gegenlaeufig" })
      local seen, claimed = {}, {}
      for k = 1, 3 do
        local d = h.add_blank({ id = "c" .. k })
        d.world.add_station("Create_Station_1", { station_name = "Hof" })
        h.step(1)
        local v = d.view()
        v.set_page("einrichtung")
        d.tap(v, "act:start")
        d.tap(v, "sel:modus:2"); d.tap(v, "act:weiter")
        h.step(8); d.node.render()
        d.tap(v, "sel:netzwahl:1"); d.tap(v, "act:weiter")
        d.tap(v, "sel:rollen:2"); d.tap(v, "act:weiter")
        h.step(10); d.node.render()
        d.tap(v, "sel:bereich:1")
        h.step(10); d.node.render()
        d.tap(v, "act:weiter"); d.tap(v, "act:weiter")
        h.step(10); d.node.render()
        local s = d.node.setup.session()
        t.eq(s.screen, "3.geraete", "Zufallsmuster " .. seed .. ", Computer " .. k .. ": " .. d.text(v))
        local id = s.wiz.claimed_id
        t.ok(id and not seen[id], "Zufallsmuster " .. seed .. ": Kennung " .. tostring(id) .. " nicht doppelt vergeben")
        seen[id] = true
        claimed[#claimed + 1] = id
      end
      t.eq(#netz.nodes(), 3, "Zufallsmuster " .. seed .. ": drei Eintraege im Verzeichnis")
    end
  end },
}
