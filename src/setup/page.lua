--[[
Purpose: Seite "Einrichtung" der Oberflaeche: fuehrt den Assistenten (setup/wizard) in sechs Hauptschritten. Jeder Schritt besteht aus kleinen Bildschirmen (eine Liste oder ein bis zwei Felder), damit er auch auf der kompakten Flaeche (51x19) passt. Ablauf: Anlage, Rolle, Geraete, Gleise, Test, Fertig. Es bearbeitet immer nur eine Ansicht die Einrichtung; andere zeigen "Einrichtung wird bearbeitet" (Konzept 28.4).
API: setup_page.new(services) -> Seite fuer ui/view; services = { scan(), env, now, store, config_path, config() -> aktuelle Konfiguration oder nil, on_saved(config), notify(level, text) }
Notes: Technische Anschlussnamen sind hier sichtbar (Schritt 3 und 4), im Betrieb ersetzen Gleisnamen sie. Schaltende Pruefungen verlangen eine Bestaetigung auf einem eigenen Bildschirm, der Geraet, erwartete Wirkung und den noetigen Ausgangszustand nennt. Mit "Abbrechen" (zweimal) werden die Eingaben verworfen; die gespeicherte Einrichtung bleibt unveraendert.
]]

local wizardlib = require("setup.wizard")
local model = require("setup.model")
local detect = require("dev.detect")
local signallib = require("dev.signal")
local pruefunglib = require("setup.pruefung")
local W = require("ui.widgets")

local M = {}

local DIRECTIONS = { { id = "hin", text = "hin (eine Richtung)" }, { id = "rueck", text = "rueck (Gegenrichtung)" }, { id = "beide", text = "beide Richtungen" } }

function M.new(services)
  local page = { id = "einrichtung", title = "Einrichtung" }

  -- gemeinsamer Zustand aller Ansichten: wer bearbeitet gerade?
  local session = { owner = nil, wiz = nil, screen = nil, stack = {}, track = nil, cancel_armed = false, test_pending = nil, pick = {}, dir = {} }

  -- Gefuehrte Einrichtung einer Signal-Node nach dem Netzverzeichnis (Konzept 12.1): Bereich waehlen, Gleise uebernehmen, Signale zuordnen,
  -- pruefen und aktivieren. Von Hand geht es weiter wie bisher ("Von Hand" auf dem Bildschirm Bereich).
  local GUIDED_TITLE = {
    ["2.bereich"] = "Bereich waehlen", ["2.b.neu"] = "Neuer Bereich", ["2.knoten"] = "Knoten waehlen", ["3.k.pruefen"] = "Knoten uebernehmen", ["3.gleise"] = "Gleise uebernehmen", ["4.zuordnung"] = "Signale zuordnen",
    ["4.z.signal"] = "Signal waehlen", ["4.z.detail"] = "Signal-Eigenschaften", ["4.z.gleis"] = "Gleis aendern", ["5.pruefen"] = "Pruefen und aktivieren",
  }
  local GUIDED_SEQUENCE = { "2.bereich", "3.gleise", "4.zuordnung", "5.pruefen" }

  local ensure_check, select_next_open            -- weiter unten bei den gefuehrten Bildschirmen
  local first_device_screen                       -- weiter unten bei den Gleisbildschirmen

  local function guided_mode()
    local w = session.wiz
    return w ~= nil and w.mode == "join" and #w.roles == 1 and w.roles[1] == "signal" and not session.manual and services.directory_areas ~= nil
  end

  -- Konzept 12.2: ist nur eine Rolle installiert (und passt zur Betriebsart), wird sie vorbelegt und die Auswahlseite entfaellt
  local function preset_role()
    local w = session.wiz
    if not w then return nil end
    local avail = w.available_roles()
    if #avail ~= 1 then return nil end
    if (w.mode == "create") == (avail[1] == "zentrale") then return avail[1] end
    return nil
  end

  local function apply_preset()
    local role = preset_role()
    if role and #session.wiz.roles == 0 then session.wiz.toggle_role(role) end
  end

  -- Bahnhof und Depot nutzen das Verzeichnis fuer Kennung, Name, Label und Gleise; Geraete, Ausgaenge und Pruefungen bleiben wie bisher
  local STATION_ROLES = { passagierbahnhof = true, gueterbahnhof = true, depot = true }
  local function station_mode()
    local w = session.wiz
    return w ~= nil and w.mode == "join" and #w.roles == 1 and STATION_ROLES[w.roles[1]] == true and not session.manual and services.directory_areas ~= nil
  end

  -- Knoten-Node: Anschluesse, Verbindungen und Konflikte kommen bestaetigt aus dem Verzeichnis
  local function knoten_mode()
    local w = session.wiz
    return w ~= nil and w.mode == "join" and #w.roles == 1 and w.roles[1] == "knoten" and not session.manual and services.directory_junctions ~= nil
  end

  local function sequence()
    apply_preset()
    local seq = { "1.modus" }
    if session.wiz.mode == "join" and services.search_networks then
      -- Beitreten: erst die Netze in Reichweite zur Auswahl; Name und Leitstelle von Hand nur, wenn keines passt
      seq[#seq + 1] = "1.netzwahl"
      if not (type(session.net_choice) == "table") then seq[#seq + 1] = "1.netz"; seq[#seq + 1] = "1.zentrale" end
    else
      seq[#seq + 1] = "1.netz"
      if session.wiz.mode == "join" then seq[#seq + 1] = "1.zentrale" end
    end
    if not preset_role() then seq[#seq + 1] = "2.rollen" end
    if guided_mode() then
      for _, id in ipairs(GUIDED_SEQUENCE) do seq[#seq + 1] = id end
      return seq
    end
    if station_mode() then
      for _, id in ipairs({ "2.bereich", "3.gleise", "3.geraete", "4.gleise", "5.test", "6.fertig" }) do seq[#seq + 1] = id end
      return seq
    end
    if knoten_mode() then
      for _, id in ipairs({ "2.knoten", "3.k.pruefen", "3.geraete", "4.gleise", "5.test", "6.fertig" }) do seq[#seq + 1] = id end
      return seq
    end
    seq[#seq + 1] = "2.name"
    seq[#seq + 1] = "3.geraete"
    local c = session.wiz.config
    -- die Anschluesse des Knotens zuerst: die Gleise verweisen darauf
    if model.has_role(c, "knoten") then seq[#seq + 1] = "4.knoten" end
    if model.has_role(c, "passagierbahnhof") or model.has_role(c, "gueterbahnhof") or model.has_role(c, "depot") or model.has_role(c, "signal") or model.has_role(c, "knoten") then
      seq[#seq + 1] = "4.gleise"
    end
    if model.has_role(c, "anmeldung") then seq[#seq + 1] = "4.anmeldung" end
    seq[#seq + 1] = "5.test"
    seq[#seq + 1] = "6.fertig"
    return seq
  end

  local function step_of(screen) return tonumber(screen:match("^(%d)")) end

  local function goto_screen(screen)
    session.screen = screen
    session.wiz.step = step_of(screen) or session.wiz.step
    session.cancel_armed = false
    if not screen:match("^1%.") then apply_preset() end
    -- lesende Pruefungen laufen von selbst (Konzept 13.1); schaltende erst nach Bestaetigung
    if screen == "5.test" and not session.wiz.guided then
      for _, test in ipairs(session.wiz.tests()) do
        if test.kind == "lesen" and session.wiz.test_state(test.id, nil, test) ~= "ok" then session.wiz.run_test(test.id, false) end
      end
    end
    if screen == "1.netzwahl" then
      session.net_choice = nil
      services.search_networks()
    elseif screen == "2.knoten" then
      session.dir = session.dir or {}
      if not session.dir.junctions then
        session.dir.want = "junctions"
        services.directory_junctions(session.wiz.central_id)
      end
    elseif screen == "2.bereich" then
      session.dir = session.dir or {}
      if not session.dir.areas then
        session.dir.want = "areas"
        services.directory_areas(session.wiz.central_id)
      end
    end
  end

  local function index_of(seq, screen)
    for i, id in ipairs(seq) do if id == screen then return i end end
    return nil
  end

  local function push(screen)
    session.stack[#session.stack + 1] = session.screen
    goto_screen(screen)
  end

  local function pop()
    local previous = table.remove(session.stack)
    if previous then goto_screen(previous) return true end
    return false
  end

  local function start(v, existing)
    session.owner = v
    session.wiz = wizardlib.new({ scan = services.scan, env = services.env, now = services.now, existing = existing, role_available = services.role_available })
    session.stack = {}
    session.track = nil
    session.pick = {}
    session.pending_role = nil
    session.net_choice = nil
    session.manual = nil
    session.checking = false
    session.dir = {}
    goto_screen("1.modus")
    -- Felder aus dem Zustand vorbelegen
    local st = v.page_state("einrichtung")
    st.fields = {
      netz = { value = session.wiz.network_name, max = 30 },
      schluessel = { value = session.wiz.key, max = 30 },
      zentrale = { value = session.wiz.central_id, max = 30 },
      name = { value = session.wiz.name, max = 30 },
      gleisname = { value = "", max = 30 },
      bname = { value = "", max = 30 }, bende1 = { value = "", max = 30 }, bende2 = { value = "", max = 30 }, bzahl = { value = "2", max = 2 },
      anschluss = { value = "", max = 20 },
    }
    -- ein gespeicherter Entwurf der gefuehrten Einrichtung geht bei der Zuordnung weiter (Kennung und Gleise stehen schon fest)
    if session.wiz.guided then
      session.dir = { claim = existing.node.claim }
      local note = ensure_check().recover()
      session.known_signals = nil
      goto_screen("4.zuordnung")
      select_next_open(v, 0)
      v.hint = note or "Entwurf geladen: Signale zuordnen und pruefen."
    elseif existing and existing.node.claimed == true and (existing.node.area or existing.node.junction) and existing.status ~= "aktiv" and #existing.node.roles == 1
      and (STATION_ROLES[existing.node.roles[1]] or existing.node.roles[1] == "knoten") then
      -- Bahnhof/Depot-Entwurf mit Kennung aus dem Verzeichnis: bei den Geraeten weitermachen
      session.dir = { claim = existing.node.claim }
      goto_screen("3.geraete")
      v.hint = "Entwurf geladen: Geraete und Gleise zuordnen, dann pruefen."
    end
  end

  local function fields(v) return v.page_state("einrichtung").fields end
  local function list_state(v, id)
    local st = v.page_state("einrichtung")
    st.lists = st.lists or {}
    st.lists[id] = st.lists[id] or { index = 1 }
    return st.lists[id]
  end

  -- Felder des aktuellen Bildschirms in den Assistenten uebernehmen
  local function commit(v)
    local f = fields(v)
    local screen = session.screen
    if screen == "1.netz" then
      session.wiz.set_network(f.netz.value, nil, f.schluessel.value)
    elseif screen == "1.zentrale" then
      session.wiz.set_network(nil, f.zentrale.value, nil)
    elseif screen == "2.name" then
      session.wiz.set_name(f.name.value)
    end
  end

  local function header(v, rect, title, subtitle)
    local w = session.wiz
    W.label(v, rect.x + 1, rect.y, string.format("Schritt %d von %d: %s", w.step, #wizardlib.STEPS, GUIDED_TITLE[session.screen] or wizardlib.STEPS[w.step]), "hell")
    if subtitle then W.label(v, rect.x + 1, rect.y + 1, subtitle, "dim", rect.w - 2) end
  end

  local function body_rect(rect, top)
    return { x = rect.x, y = rect.y + top, w = rect.w, h = rect.h - top }
  end

  local function device_items(kinds, selected_only)
    local items, map = {}, {}
    for _, d in ipairs(session.wiz.scan) do
      if kinds[d.kind] then
        local chosen = session.wiz.device_selected(d.name)
        local missing = {}
        if d.kind == "station" or d.kind == "signal" or d.kind == "observer" then missing = detect.missing(d.kind, d) end
        items[#items + 1] = {
          text = (chosen and "[x] " or "[ ] ") .. d.name,
          detail = d.kind .. (#missing > 0 and (", fehlt: " .. table.concat(missing, ",")) or ""),
          kind = (#missing > 0) and "attention" or "dim",
        }
        map[#items] = d
      end
    end
    return items, map
  end

  local function config_devices_of(kind)
    local out = {}
    local ids = {}
    for id, d in pairs(session.wiz.config.devices) do if d.kind == kind then ids[#ids + 1] = id end end
    table.sort(ids)
    for _, id in ipairs(ids) do out[#out + 1] = { id = id, device = session.wiz.config.devices[id].device } end
    return out
  end

  local function track_label(id)
    local t = session.wiz.config.tracks[id]
    return t.name
  end

  -- Bildschirme -----------------------------------------------------------------------------------------------------------------------------
  local screens = {}

  screens["1.modus"] = {
    render = function(v, rect)
      header(v, rect, nil, "Erste Leitstelle erstellen oder einem Netz beitreten?")
      local items = {}
      session.pick.modes = {}
      if not services.role_available or services.role_available("zentrale") then
        items[#items+1] = { text = (session.wiz.mode == "create" and "(o) " or "( ) ") .. "Erste Leitstelle dieses Netzes erstellen" }
        session.pick.modes[#items] = "create"
      end
      items[#items+1] = { text = (session.wiz.mode == "join" and "(o) " or "( ) ") .. "Diesem bestehenden Netz beitreten" }
      session.pick.modes[#items] = "join"
      W.list(v, "modus", body_rect(rect, 3), items, list_state(v, "modus"), { row_h = v.layout.mode == "gross" and 3 or 1 })
    end,
    action = function(v, id)
      local n = id:match("^sel:modus:(%d+)$")
      if n then session.wiz.set_mode((session.pick.modes or {})[tonumber(n)] or "join") return true end
    end,
  }

  screens["1.netzwahl"] = {
    render = function(v, rect)
      header(v, rect, nil, "Welchem Netz soll dieser Computer beitreten?")
      local st = services.search_status and services.search_status() or { kind = "halt", text = "", networks = {} }
      W.label(v, rect.x + 1, rect.y + 2, st.text or "", st.kind or "dim", rect.w - 2)
      local items = {}
      session.pick.nets = {}
      local chosen = session.net_choice
      for _, net in ipairs(st.networks or {}) do
        local on = type(chosen) == "table" and chosen.zentrale == net.zentrale
        items[#items + 1] = { text = (on and "(o) " or "( ) ") .. net.netz, detail = "Leitstelle " .. net.zentrale }
        session.pick.nets[#items] = net
      end
      items[#items + 1] = { text = (chosen == "manuell" and "(o) " or "( ) ") .. "Netz von Hand eingeben" }
      session.pick.nets[#items] = "manuell"
      W.list(v, "netzwahl", body_rect(rect, 4), items, list_state(v, "netzwahl"), { row_h = v.layout.mode == "gross" and 3 or 1 })
    end,
    action = function(v, id)
      local n = id:match("^sel:netzwahl:(%d+)$")
      if n then
        session.net_choice = (session.pick.nets or {})[tonumber(n)]
        return true
      end
      if id == "act:neu_suchen" then
        session.net_choice = nil
        services.search_networks()
        return true
      end
    end,
    actions = function(v) return { { id = "neu_suchen", label = "Neu suchen", kind = "secondary" } } end,
  }

  screens["1.netz"] = {
    render = function(v, rect)
      header(v, rect, nil, "Wie heisst das Netz? (Buchstaben, Ziffern, Leerzeichen, - und _)")
      local f = fields(v)
      W.field(v, "netz", rect.x + 1, rect.y + 3, math.min(rect.w - 2, 36), "Netzname", f.netz)
      W.field(v, "schluessel", rect.x + 1, rect.y + 6, math.min(rect.w - 2, 36), "Netzwerkschluessel (freiwillig)", f.schluessel)
      if rect.h > 10 then W.label(v, rect.x + 1, rect.y + 9, "Der Schluessel haelt nur Versehen fern, er ist keine Verschluesselung.", "dim", rect.w - 2) end
    end,
  }

  screens["1.zentrale"] = {
    render = function(v, rect)
      header(v, rect, nil, "Welche Leitstelle fuehrt dieses Netz?")
      W.field(v, "zentrale", rect.x + 1, rect.y + 3, math.min(rect.w - 2, 36), "Node-Kennung der Leitstelle (z.B. hauptstelle)", fields(v).zentrale)
    end,
  }

  screens["2.rollen"] = {
    render = function(v, rect)
      header(v, rect, nil, "Rollen waehlen (mehrere moeglich).")
      local items = {}
      session.pick.roles = session.wiz.available_roles()
      for _, role in ipairs(session.pick.roles) do
        local on = false
        for _, r in ipairs(session.wiz.roles) do if r == role then on = true end end
        items[#items + 1] = { text = (on and "[x] " or "[ ] ") .. model.ROLE_TEXT[role], detail = role }
      end
      W.list(v, "rollen", body_rect(rect, 3), items, list_state(v, "rollen"), { row_h = v.layout.mode == "gross" and 3 or 1 })
    end,
    action = function(v, id)
      local n = id:match("^sel:rollen:(%d+)$")
      if n then
        local role = (session.pick.roles or {})[tonumber(n)]
        local ok, why, effect = session.wiz.toggle_role(role, session.pending_role == role)
        if why == "bestaetigen" then
          session.pending_role = role
          v.hint = "Abwaehlen entfernt " .. effect.devices .. " Geraet(e) und " .. effect.tracks .. " Gleis(e). Zum Bestaetigen erneut antippen."
        else
          session.pending_role = nil
          v.hint = (ok and effect and (effect.devices > 0 or effect.tracks > 0)) and "Rolle entfernt; Tests muessen erneuert werden." or ""
        end
        return true
      end
    end,
  }

  screens["2.name"] = {
    render = function(v, rect)
      header(v, rect, nil, "Wie heisst dieser Node? (z.B. Westbahnhof)")
      W.field(v, "name", rect.x + 1, rect.y + 3, math.min(rect.w - 2, 36), "Name", fields(v).name)
      local c = session.wiz.config
      if c.node.name ~= "" then W.label(v, rect.x + 1, rect.y + 6, "Kennung im Netz: " .. model.slug(c.node.name), "dim", rect.w - 2) end
    end,
  }

  screens["3.geraete"] = {
    render = function(v, rect)
      header(v, rect, nil, "Passende Geraete fuer diese Node auswaehlen.")
      local items, map = device_items(session.wiz.allowed_devices())
      session.pick.devices = map
      local wireless, wired = {}, {}
      for _, d in ipairs(session.wiz.scan) do
        if d.kind == "modem" then
          local ok = d.methods.isWireless and services.modem_is_wireless and services.modem_is_wireless(d.name)
          if ok then wireless[#wireless + 1] = d.name else wired[#wired + 1] = d.name end
        end
      end
      local modem_line = "Funk: " .. (#wireless > 0 and table.concat(wireless, ",") or "KEIN FUNKMODEM") .. "   Kabel: " .. (#wired > 0 and table.concat(wired, ",") or "-")
      W.label(v, rect.x + 1, rect.y + 2, modem_line, #wireless > 0 and "dim" or "attention", rect.w - 2)
      W.list(v, "geraete", body_rect(rect, 3), items, list_state(v, "geraete"), { empty = "Keine passenden Geraete gefunden." })
    end,
    action = function(v, id)
      local n = id:match("^sel:geraete:(%d+)$")
      if n then
        local d = session.pick.devices and session.pick.devices[tonumber(n)]
        if d then session.wiz.toggle_device(d.name) end
        return true
      end
      if id == "act:neu_scannen" then session.wiz.rescan() v.hint = "Geraete neu gelesen." return true end
    end,
    actions = function(v) return { { id = "neu_scannen", label = "Neu lesen", kind = "secondary" } } end,
  }

  screens["4.gleise"] = {
    render = function(v, rect)
      header(v, rect, nil, "Gleise dieses Nodes. Ein Geraet gehoert zu hoechstens einem Gleis.")
      local items = {}
      session.pick.tracks = {}
      for _, id in ipairs(session.wiz.tracks()) do
        local t = session.wiz.config.tracks[id]
        local parts = {}
        if t.station then parts[#parts + 1] = "Bahnhof" end
        if #t.signals > 0 then parts[#parts + 1] = #t.signals .. " Signal(e)" end
        if #t.observers > 0 then parts[#parts + 1] = #t.observers .. " Beobachter" end
        if t.release then parts[#parts + 1] = "Ausgang" end
        items[#items + 1] = { text = t.name, detail = (#parts > 0 and table.concat(parts, ", ") or "leer") .. " - " .. t.status, kind = (t.status == "aktiv") and "ok" or "wait" }
        session.pick.tracks[#items] = id
      end
      W.list(v, "gleise", body_rect(rect, 3), items, list_state(v, "gleise"), { empty = session.wiz.config.node.claimed and "Keine Gleise uebernommen." or "Noch kein Gleis. 'Neues Gleis' legt eines an." })
      local problems = session.wiz.warnings()
      if #problems > 0 and rect.h > 8 then v.hint = problems[1].text end
    end,
    action = function(v, id)
      local selected = session.pick.tracks and session.pick.tracks[list_state(v, "gleise").index]
      if id == "act:neues_gleis" then
        local count = #session.wiz.tracks() + 1
        local tid = session.wiz.add_track("Gleis " .. count)
        session.track = tid
        fields(v).gleisname.value = session.wiz.config.tracks[tid].name
        push("4.g.name")
        return true
      elseif id == "act:bearbeiten" and selected then
        session.track = selected
        fields(v).gleisname.value = session.wiz.config.tracks[selected].name
        -- Gleise aus dem Verzeichnis haben Name und Richtung schon; es geht gleich zu den Geraeten
        push(session.wiz.config.node.claimed and first_device_screen() or "4.g.name")
        return true
      elseif id == "act:kopieren" and selected then
        local src = session.wiz.config.tracks[selected]
        local tid = session.wiz.copy_track(selected, src.name .. " Kopie")
        session.track = tid
        fields(v).gleisname.value = session.wiz.config.tracks[tid].name
        push("4.g.name")
        v.hint = "Kopie: Geraete und Ausgang neu zuordnen."
        return true
      elseif id == "act:entfernen" and selected then
        session.wiz.remove_track(selected)
        return true
      end
    end,
    actions = function(v)
      local has_selection = session.pick.tracks and session.pick.tracks[list_state(v, "gleise").index] ~= nil
      local reason = "Erst ein Gleis in der Liste waehlen."
      if session.wiz.config.node.claimed then
        -- die Gleise stammen aus dem Netzverzeichnis: hier werden nur Geraete zugeordnet (Name und Richtung ueber die Leitstelle)
        return { { id = "bearbeiten", label = "Zuordnen", enabled = has_selection, reason = reason } }
      end
      return {
        { id = "neues_gleis", label = "Neu" },
        { id = "bearbeiten", label = "Bearbeiten", kind = "secondary", enabled = has_selection, reason = reason },
        { id = "kopieren", label = "Kopieren", kind = "secondary", enabled = has_selection, reason = reason },
        { id = "entfernen", label = "Entfernen", kind = "danger", enabled = has_selection, reason = reason },
      }
    end,
  }

  screens["4.g.name"] = {
    render = function(v, rect)
      local t = session.wiz.config.tracks[session.track]
      header(v, rect, nil, "Gleis bearbeiten: " .. (t and t.name or "?"))
      W.field(v, "gleisname", rect.x + 1, rect.y + 3, math.min(rect.w - 2, 36), "Gleisname", fields(v).gleisname)
      if t then W.label(v, rect.x + 1, rect.y + 6, "Richtung: " .. t.direction .. "   (Taste 'Weiter' fuehrt durch die Einstellungen)", "dim", rect.w - 2) end
    end,
    next = function(v)
      session.wiz.rename_track(session.track, fields(v).gleisname.value)
      push("4.g.richtung")
      return true
    end,
  }

  -- erster rollenabhaengiger Bildschirm eines Gleises (nach Name und Richtung)
  function first_device_screen()
    local c = session.wiz.config
    if model.has_role(c, "knoten") and c.node.claimed then
      -- Anschluss und Rolle stehen aus dem Verzeichnis fest: Einfahrten bekommen Signal und Beobachter, Ausfahrten den Beobachter
      local track = c.tracks[session.track]
      return (track and track.junction and track.junction.role == "ein") and "4.g.signale" or "4.g.beobachter"
    end
    if model.has_role(c, "knoten") then return "4.g.anschluss"
    elseif model.has_role(c, "passagierbahnhof") or model.has_role(c, "gueterbahnhof") or model.has_role(c, "depot") then return "4.g.bahnhof"
    elseif model.has_role(c, "signal") then return "4.g.signale" end
    return "4.g.ausgang"
  end

  screens["4.g.richtung"] = {
    render = function(v, rect)
      local t = session.wiz.config.tracks[session.track]
      header(v, rect, nil, "In welche Richtung wird das Gleis befahren? " .. t.name)
      local items = {}
      for _, d in ipairs(DIRECTIONS) do items[#items + 1] = { text = (t.direction == d.id and "(o) " or "( ) ") .. d.text } end
      W.list(v, "richtung", body_rect(rect, 3), items, list_state(v, "richtung"), { row_h = v.layout.mode == "gross" and 3 or 1 })
    end,
    action = function(v, id)
      local n = id:match("^sel:richtung:(%d+)$")
      if n then session.wiz.set_direction(session.track, DIRECTIONS[tonumber(n)].id) return true end
    end,
    next = function(v)
      push(first_device_screen())
      return true
    end,
  }

  -- Knoten: gehoert dieses Gleis zu einer Einfahrt (Signal haelt Zuege) oder zu einer Ausfahrt (Beobachter meldet die Raeumung)?
  screens["4.g.anschluss"] = {
    render = function(v, rect)
      local t = session.wiz.config.tracks[session.track]
      header(v, rect, nil, "Gehoert Gleis " .. t.name .. " zu einer Einfahrt oder Ausfahrt des Knotens?")
      local j = session.wiz.config.junction
      local names = {}
      for name in pairs(j.connections) do names[#names + 1] = name end
      table.sort(names)
      local items = { { text = ((not t.junction) and "(o) " or "( ) ") .. "keinem Anschluss (normales Gleis)" } }
      session.pick.anschluss = { false }
      for _, name in ipairs(names) do
        for _, role in ipairs({ "ein", "aus" }) do
          local on = t.junction and t.junction.connection == name and t.junction.role == role
          items[#items + 1] = { text = (on and "(o) " or "( ) ") .. name .. (role == "ein" and ": Einfahrt (Signal)" or ": Ausfahrt (Beobachter)") }
          session.pick.anschluss[#items] = { connection = name, role = role }
        end
      end
      W.list(v, "anschluss", body_rect(rect, 3), items, list_state(v, "anschluss"), { row_h = v.layout.mode == "gross" and 3 or 1 })
    end,
    action = function(v, id)
      local n = id:match("^sel:anschluss:(%d+)$")
      if n then
        local choice = session.pick.anschluss and session.pick.anschluss[tonumber(n)]
        session.wiz.set_junction_link(session.track, choice or nil)
        return true
      end
    end,
    next = function(v)
      local c = session.wiz.config
      if model.has_role(c, "passagierbahnhof") or model.has_role(c, "gueterbahnhof") or model.has_role(c, "depot") then
        push("4.g.bahnhof")
      else
        push("4.g.signale")
      end
      return true
    end,
  }

  local function device_choice_screen(id, kind, field, subtitle, single)
    return {
      render = function(v, rect)
        local t = session.wiz.config.tracks[session.track]
        header(v, rect, nil, subtitle .. " " .. t.name)
        local items = {}
        session.pick[id] = {}
        for _, d in ipairs(config_devices_of(kind)) do
          local on
          if single then on = (t.station == d.id) else
            on = false
            for _, ref in ipairs(t[field]) do if ref == d.id then on = true end end
          end
          items[#items + 1] = { text = (on and "[x] " or "[ ] ") .. d.device }
          session.pick[id][#items] = d.id
        end
        W.list(v, id, body_rect(rect, 3), items, list_state(v, id), { row_h = 1, empty = "Kein passendes Geraet in Schritt 3 gewaehlt." })
      end,
      action = function(v, act)
        local n = act:match("^sel:" .. id .. ":(%d+)$")
        if n then
          local device_id = session.pick[id] and session.pick[id][tonumber(n)]
          if device_id then
            local ok, why = session.wiz.toggle_track_device(session.track, field, device_id)
            if not ok then v.hint = why end
          end
          return true
        end
      end,
    }
  end

  screens["4.g.bahnhof"] = device_choice_screen("bahnhof", "station", "station", "Welcher Create-Bahnhof gehoert zu Gleis", true)
  screens["4.g.bahnhof"].next = function(v)
    if #config_devices_of("signal") > 0 then push("4.g.signale")
    elseif #config_devices_of("observer") > 0 then push("4.g.beobachter")
    elseif model.profile(session.wiz.config).release then push("4.g.ausgang")
    else while session.screen ~= "4.gleise" and pop() do end end
    return true
  end
  screens["4.g.signale"] = device_choice_screen("signale", "signal", "signals", "Welche Signale gehoeren zu Gleis")
  screens["4.g.signale"].next = function(v)
    if #config_devices_of("observer") > 0 then push("4.g.beobachter")
    elseif model.profile(session.wiz.config).release then push("4.g.ausgang")
    else while session.screen ~= "4.gleise" and pop() do end end
    return true
  end
  screens["4.g.beobachter"] = device_choice_screen("beobachter", "observer", "observers", "Welche Beobachter gehoeren zu Gleis")
  screens["4.g.beobachter"].next = function(v)
    local c = session.wiz.config
    if model.has_role(c, "passagierbahnhof") or model.has_role(c, "gueterbahnhof") then
      push("4.g.ausgang")
    else
      while session.screen ~= "4.gleise" and pop() do end
    end
    return true
  end

  screens["4.g.ausgang"] = {
    render = function(v, rect)
      local t = session.wiz.config.tracks[session.track]
      header(v, rect, nil, "Welcher Ausgang gibt Gleis " .. t.name .. " frei? Jeder Ausgang nur einmal.")
      local items = {}
      session.pick.outputs = {}
      for _, o in ipairs(model.outputs(session.wiz.scan)) do
        local on = t.release and t.release.side == o.side and t.release.relay == o.relay
        items[#items + 1] = { text = (on and "(o) " or "( ) ") .. o.label }
        session.pick.outputs[#items] = o
      end
      W.list(v, "ausgang", body_rect(rect, 3), items, list_state(v, "ausgang"), { row_h = v.layout.mode == "gross" and 3 or 1 })
    end,
    action = function(v, id)
      local n = id:match("^sel:ausgang:(%d+)$")
      if n then
        local o = session.pick.outputs and session.pick.outputs[tonumber(n)]
        if o then
          local t = session.wiz.config.tracks[session.track]
          if t.release and t.release.side == o.side and t.release.relay == o.relay then
            session.wiz.set_release(session.track, nil)
          else
            local ok, why = session.wiz.set_release(session.track, { side = o.side, relay = o.relay })
            if not ok then v.hint = why end
          end
        end
        return true
      end
    end,
    next = function(v)
      -- zurueck zur Gleisliste
      while session.screen ~= "4.gleise" and pop() do end
      return true
    end,
  }

  screens["4.knoten"] = {
    render = function(v, rect)
      header(v, rect, nil, "Anschluesse und Verbindungen des Knotenpunkts")
      local j = session.wiz.config.junction
      local names = {}
      for name in pairs(j.connections) do names[#names + 1] = name end
      table.sort(names)
      session.pick.connections = names
      local items = {}
      for _, name in ipairs(names) do items[#items + 1] = { text = name } end
      W.field(v, "anschluss", rect.x + 1, rect.y + 2, math.min(rect.w - 2, 30), "Neuer Anschluss (z.B. West)", fields(v).anschluss)
      local move_text = {}
      for i, m in ipairs(j.moves) do move_text[#move_text + 1] = i .. ": " .. m.from .. "->" .. m.to end
      W.label(v, rect.x + 1, rect.y + 5, "Verbindungen: " .. (#move_text > 0 and table.concat(move_text, "  ") or "keine"), "dim", rect.w - 2)
      W.list(v, "anschluesse", body_rect(rect, 6), items, list_state(v, "anschluesse"), { row_h = 1, empty = "Noch kein Anschluss." })
    end,
    action = function(v, id)
      if id == "input:anschluss" or id == "act:anschluss_neu" then
        local value = fields(v).anschluss.value
        local ok, why = session.wiz.add_connection(value)
        if ok then
          fields(v).anschluss.value = ""
          local index = 1
          for name in pairs(session.wiz.config.junction.connections) do if name < value then index=index+1 end end
          list_state(v,"anschluesse").index=index
        else v.hint = why end
        return true
      end
      local names = session.pick.connections or {}
      local selected = names[list_state(v, "anschluesse").index]
      if id == "act:anschluss_weg" and selected then session.wiz.remove_connection(selected) return true end
      if id == "act:verbindung" then
        session.pick.from, session.pick.to = nil, nil
        push("4.k.von")
        return true
      end
      if id == "act:konflikt" then
        session.pick.a, session.pick.b = nil, nil
        push("4.k.konflikt")
        return true
      end
      local n = id:match("^sel:anschluesse:(%d+)$")
      if n then return true end
    end,
    actions = function(v)
      local names = session.pick.connections or {}
      local has_selection = names[list_state(v, "anschluesse").index] ~= nil
      local j = session.wiz.config.junction
      local count = 0
      for _ in pairs(j.connections) do count = count + 1 end
      return {
        { id = "anschluss_neu", label = "Hinzufuegen" },
        { id = "anschluss_weg", label = "Entfernen", kind = "danger", enabled = has_selection, reason = "Erst einen Anschluss waehlen." },
        { id = "verbindung", label = "Verbindung", kind = "secondary", enabled = count >= 2, reason = "Zuerst mindestens zwei Anschluesse anlegen." },
        { id = "konflikt", label = "Konflikt", kind = "secondary", enabled = #j.moves >= 2, reason = "Zuerst mindestens zwei Verbindungen anlegen." },
      }
    end,
  }

  local function connection_pick_screen(id, label, store_key, on_done)
    return {
      render = function(v, rect)
        header(v, rect, nil, label)
        local items = {}
        local j = session.wiz.config.junction
        local names = {}
        for name in pairs(j.connections) do names[#names + 1] = name end
        table.sort(names)
        session.pick[id] = names
        for _, name in ipairs(names) do items[#items + 1] = { text = name } end
        W.list(v, id, body_rect(rect, 3), items, list_state(v, id), { row_h = v.layout.mode == "gross" and 3 or 1 })
      end,
      action = function(v, act)
        local n = act:match("^sel:" .. id .. ":(%d+)$")
        if n then
          session.pick[store_key] = session.pick[id][tonumber(n)]
          on_done(v)
          return true
        end
      end,
    }
  end
  screens["4.k.von"] = connection_pick_screen("von", "Von welchem Anschluss faehrt der Zug ein?", "from", function(v)
    goto_screen("4.k.nach")
  end)
  screens["4.k.nach"] = connection_pick_screen("nach", "Zu welchem Anschluss faehrt er aus?", "to", function(v)
    local ok, why = session.wiz.add_move(session.pick.from, session.pick.to)
    v.hint = ok and "Verbindung eingetragen." or why
    pop()
  end)

  screens["4.k.konflikt"] = {
    render = function(v, rect)
      header(v, rect, nil, "Welche zwei Verbindungen schliessen sich aus? (nacheinander antippen)")
      local j = session.wiz.config.junction
      local items = {}
      for i, m in ipairs(j.moves) do
        local chosen = (session.pick.a == i or session.pick.b == i)
        items[#items + 1] = { text = (chosen and "[x] " or "[ ] ") .. i .. ": " .. m.from .. " -> " .. m.to }
      end
      W.list(v, "konflikt", body_rect(rect, 3), items, list_state(v, "konflikt"), { row_h = v.layout.mode == "gross" and 3 or 1 })
    end,
    action = function(v, id)
      local n = id:match("^sel:konflikt:(%d+)$")
      if n then
        n = tonumber(n)
        if not session.pick.a then
          session.pick.a = n
        elseif session.pick.a ~= n then
          local ok, why = session.wiz.add_conflict(session.pick.a, n)
          v.hint = ok and "Konflikt eingetragen." or why
          session.pick.a, session.pick.b = nil, nil
          pop()
        end
        return true
      end
    end,
  }

  screens["4.anmeldung"] = {
    render = function(v, rect)
      header(v, rect, nil, "Welche Station dient der Zuganmeldung?")
      local items = {}
      session.pick.registration = {}
      for _, d in ipairs(config_devices_of("station")) do
        local on = session.wiz.config.registration_station == d.id
        items[#items + 1] = { text = (on and "(o) " or "( ) ") .. d.device }
        session.pick.registration[#items] = d.id
      end
      W.list(v, "anmeldung", body_rect(rect, 3), items, list_state(v, "anmeldung"), { row_h = 1, empty = "Zuerst in Schritt 3 einen Bahnhof waehlen." })
    end,
    action = function(v, id)
      local n = id:match("^sel:anmeldung:(%d+)$")
      if n then
        local device_id = session.pick.registration and session.pick.registration[tonumber(n)]
        if device_id then session.wiz.set_registration(device_id) end
        return true
      end
    end,
  }

  local function summarize_tests(result)
    local text = result.ok .. " ok, " .. result.failed .. " Fehler"
    if result.stopped then text = text .. ". GESTOPPT nach " .. result.stopped .. " (Zustand unklar): " .. result.open .. " Pruefung(en) nicht gelaufen." end
    return text
  end

  screens["5.test"] = {
    render = function(v, rect)
      header(v, rect, nil, "Pruefungen: lesende laufen sofort, schaltende nach Bestaetigung.")
      local items = {}
      session.pick.tests = {}
      for _, test in ipairs(session.wiz.tests()) do
        local state, text = session.wiz.test_state(test.id)
        local kind = (state == "ok") and "ok" or (state == "fehler") and "halt" or "wait"
        items[#items + 1] = { text = test.title, detail = state .. (test.kind == "schalten" and " (schaltet)" or "") .. (text and state == "fehler" and (": " .. text) or ""), kind = kind }
        session.pick.tests[#items] = test
      end
      W.list(v, "tests", body_rect(rect, 3), items, list_state(v, "tests"), { empty = "Keine Pruefungen noetig." })
    end,
    action = function(v, id)
      local selected = session.pick.tests and session.pick.tests[list_state(v, "tests").index]
      if id == "act:ausfuehren" and selected then
        if selected.kind == "schalten" then
          session.test_pending = selected
          push("5.bestaetigen")
        else
          local ok, text = session.wiz.run_test(selected.id, false)
          v.hint = (ok and "ok: " or "Fehler: ") .. tostring(text)
        end
        return true
      elseif id == "act:alle_lesen" then
        local ran = 0
        for _, test in ipairs(session.wiz.tests()) do
          if test.kind == "lesen" then session.wiz.run_test(test.id, false) ran = ran + 1 end
        end
        v.hint = ran .. " lesende Pruefungen ausgefuehrt."
        return true
      elseif id == "act:alle_pruefen" then
        -- gemeinsamer Start (Konzept 13.1): die Wirkung aller schaltenden Pruefungen wird zusammen gezeigt und einmal bestaetigt
        local open = session.wiz.run_open_tests(false)
        if open.open > 0 then
          push("5.alle_bestaetigen")
        else
          v.hint = summarize_tests(open)
        end
        return true
      end
    end,
    actions = function(v)
      local selected = session.pick.tests and session.pick.tests[list_state(v, "tests").index]
      return {
        { id = "alle_pruefen", label = "Alle pruefen" },
        { id = "ausfuehren", label = "Einzeln", kind = "secondary", enabled = selected ~= nil, reason = "Erst eine Pruefung waehlen." },
        { id = "alle_lesen", label = "Lesende", kind = "secondary" },
      }
    end,
  }

  screens["5.alle_bestaetigen"] = {
    hide_nav_buttons = true,
    render = function(v, rect)
      header(v, rect, nil, "Alle offenen Pruefungen starten")
      local y = rect.y + 2
      local lines = { "Folgende Pruefungen schalten kurz und stellen den Ausgangszustand wieder her:" }
      for _, test in ipairs(session.wiz.tests()) do
        if test.kind == "schalten" and session.wiz.test_state(test.id, nil, test) ~= "ok" then lines[#lines + 1] = "- " .. test.title end
      end
      lines[#lines + 1] = "Der Testbereich muss vorbereitet sein: kein Zug darf auf eine Freigabe warten, kein Signal darf einen Zug schuetzen."
      for _, line in ipairs(lines) do
        for _, part in ipairs(W.wrap(line, rect.w - 2)) do
          if y <= rect.y + rect.h - 1 then W.label(v, rect.x + 1, y, part, "text", rect.w - 2) end
          y = y + 1
        end
      end
    end,
    action = function(v, id)
      if id == "act:alle_starten" then
        local result = session.wiz.run_open_tests(true)
        pop()
        v.hint = summarize_tests(result)
        return true
      elseif id == "act:alle_abbruch" then
        pop()
        v.hint = "Pruefungen nicht gestartet."
        return true
      end
    end,
    actions = function(v)
      return {
        { id = "alle_starten", label = "Vorbereitung erledigt: alle starten" },
        { id = "alle_abbruch", label = "Abbrechen", kind = "secondary" },
      }
    end,
  }

  screens["5.bestaetigen"] = {
    render = function(v, rect)
      local test = session.test_pending
      header(v, rect, nil, "Schaltende Pruefung bestaetigen")
      if not test then return end
      W.label(v, rect.x + 1, rect.y + 3, test.title, "hell", rect.w - 2)
      for i, line in ipairs(W.wrap(test.explain, rect.w - 2)) do
        if rect.y + 4 + i <= rect.y + rect.h - 1 then W.label(v, rect.x + 1, rect.y + 4 + i, line, "text", rect.w - 2) end
      end
    end,
    action = function(v, id)
      if id == "act:start_test" then
        local test = session.test_pending
        local ok, text = session.wiz.run_test(test.id, true)
        session.test_pending = nil
        pop()
        v.hint = (ok and "ok: " or "Fehler: ") .. tostring(text)
        return true
      elseif id == "act:test_abbruch" then
        session.test_pending = nil
        pop()
        v.hint = "Pruefung nicht ausgefuehrt."
        return true
      end
    end,
    actions = function(v)
      return {
        { id = "start_test", label = "Vorbereitung erledigt: starten" },
        { id = "test_abbruch", label = "Abbrechen", kind = "secondary" },
      }
    end,
    hide_nav_buttons = true,
  }

  -- gefuehrte Einrichtung: Bildschirme ------------------------------------------------------------------------------------------------------
  function ensure_check()
    local w = session.wiz
    if w.pruefung then return w.pruefung end
    w.pruefung = pruefunglib.new({
      env = services.env,
      config = function() return session.wiz.config end,
      now = services.now,
      clock = services.env.raw_clock,
      scan = function() return services.scan() end,
      -- der Entwurf wird vor jeder Testsperre gespeichert (Marke fuer den Wiederanlauf)
      persist = function() return services.store.save(services.config_path, session.wiz.config) end,
    })
    return w.pruefung
  end

  local function dir_status() return services.directory_status and services.directory_status() or nil end

  local function direction_text(direction)
    if direction == "beide" then return "beide Richtungen" end
    return "Richtung " .. tostring(direction)
  end

  local function choose_area(area)
    local d = session.dir
    d.chosen, d.area, d.selected, d.want = area, nil, nil, "area"
    services.directory_tracks(session.wiz.central_id, area.id)
  end

  local PATTERNS = { "gegenlaeufig", "gleich", "beide" }
  local PATTERN_TEXT = { gegenlaeufig = "gegenlaeufig (Haelfte je Richtung)", gleich = "alle in eine Richtung (zum 2. Anschluss)", beide = "Richtung offen (beide)" }

  screens["2.bereich"] = {
    render = function(v, rect)
      header(v, rect, nil, "In welchem Bereich arbeitet diese Node?")
      local d = session.dir
      local st = dir_status()
      if st and st.kind ~= "ok" then W.label(v, rect.x + 1, rect.y + 2, st.text or "", st.kind, rect.w - 2) end
      local items = {}
      session.pick.areas = {}
      for _, a in ipairs(d.areas or {}) do
        local on = d.chosen and d.chosen.id == a.id
        items[#items + 1] = { text = (on and "(o) " or "( ) ") .. a.name, detail = a.ends[1] .. " - " .. a.ends[2] .. ", " .. a.tracks .. " Gleis(e)" .. (a.state == "im bau" and ", IM BAU" or ""), kind = (a.state == "im bau") and "wait" or nil }
        session.pick.areas[#items] = a
      end
      local empty = (st and st.kind == "ok" and d.areas) and "Das Netz hat noch keinen Bereich. In der Leitstelle auf der Seite Bereiche anlegen, dann 'Neu laden'." or ""
      W.list(v, "bereich", body_rect(rect, 4), items, list_state(v, "bereich"), { empty = empty })
    end,
    action = function(v, id)
      local n = id:match("^sel:bereich:(%d+)$")
      local d = session.dir
      if n then
        local area = (session.pick.areas or {})[tonumber(n)]
        if area then choose_area(area) end
        return true
      elseif id == "act:neuer_bereich" then
        local f = fields(v)
        f.bname.value, f.bende1.value, f.bende2.value, f.bzahl.value = "", "", "", "2"
        d.neu = { pattern = "gegenlaeufig" }
        push("2.b.neu")
        return true
      elseif id == "act:neu_laden" then
        d.areas, d.chosen, d.area, d.want = nil, nil, nil, "areas"
        services.directory_areas(session.wiz.central_id)
        return true
      elseif id == "act:von_hand" then
        session.manual = true
        session.stack = {}
        goto_screen("2.name")
        return true
      end
    end,
    actions = function(v)
      return {
        { id = "neuer_bereich", label = "Neu" },
        { id = "neu_laden", label = "Neu laden", kind = "secondary" },
        { id = "von_hand", label = "Von Hand", kind = "secondary" },
      }
    end,
    next = function(v)
      local d = session.dir
      if not d.selected then
        d.selected = {}
        for _, t in ipairs(d.area.tracks) do d.selected[t.id] = true end
      end
      push("3.gleise")
      return true
    end,
  }

  -- Bereich von der Node aus anlegen (Konzept 10.2): die Leitstelle speichert ihn; bei Wiederholung derselben Angaben entsteht er nicht doppelt
  screens["2.b.neu"] = {
    no_forward = true,
    render = function(v, rect)
      local d = session.dir
      header(v, rect, nil, "Neuen Bereich im Netz anlegen")
      local f = fields(v)
      local w = math.min(rect.w - 2, 36)
      W.field(v, "bname", rect.x + 1, rect.y + 2, w, "Name des Bereichs (z.B. West-Ost)", f.bname)
      W.field(v, "bende1", rect.x + 1, rect.y + 4, w, "Anschluss 1 (z.B. Westbahnhof)", f.bende1)
      W.field(v, "bende2", rect.x + 1, rect.y + 6, w, "Anschluss 2 (z.B. Ostbahnhof)", f.bende2)
      W.field(v, "bzahl", rect.x + 1, rect.y + 8, 12, "Gleise", f.bzahl)
      W.label(v, rect.x + 1, rect.y + 11, "Vorlage: " .. (PATTERN_TEXT[d.neu and d.neu.pattern or "gegenlaeufig"] or "?"), "text", rect.w - 2)
      local st = dir_status()
      if d.creating and st and st.kind ~= "ok" then W.label(v, rect.x + 1, rect.y + 13, st.text or "", st.kind, rect.w - 2) end
    end,
    actions = function(v)
      local busy = session.dir.creating ~= nil
      return {
        { id = "b_vorlage", label = "Vorlage", kind = "secondary", enabled = not busy, reason = "Die Leitstelle arbeitet noch." },
        { id = "b_anlegen", label = "Anlegen", enabled = not busy, reason = "Die Leitstelle arbeitet noch." },
      }
    end,
    action = function(v, id)
      local d = session.dir
      if d.creating then return false end
      if id == "act:b_vorlage" then
        for i, p in ipairs(PATTERNS) do
          if p == d.neu.pattern then d.neu.pattern = PATTERNS[i % #PATTERNS + 1] return true end
        end
        d.neu.pattern = PATTERNS[1]
        return true
      elseif id == "act:b_anlegen" then
        local f = fields(v)
        local function trim(x) return (x:match("^%s*(.-)%s*$")) end
        local spec = { name = trim(f.bname.value), ends = { trim(f.bende1.value), trim(f.bende2.value) }, count = tonumber(trim(f.bzahl.value)), pattern = d.neu.pattern }
        if spec.name == "" then v.hint = "Der Name des Bereichs fehlt." return true end
        if spec.ends[1] == "" or spec.ends[2] == "" then v.hint = "Beide Anschlussnamen fehlen." return true end
        if not spec.count then v.hint = "Die Gleisanzahl fehlt (Zahl)." return true end
        -- gleiche Angaben, gleiche Kennung: ein erneuter Versuch legt nichts doppelt an; geaenderte Angaben bekommen eine neue
        local key = table.concat({ spec.name, spec.ends[1], spec.ends[2], tostring(spec.count), spec.pattern }, "|")
        if d.neu.key ~= key then d.neu.key, d.neu.token = key, services.new_claim() end
        services.directory_reset()
        d.creating = { token = d.neu.token }
        services.directory_area_create(session.wiz.central_id, d.neu.token, spec)
        v.hint = "Frage die Leitstelle ..."
        return true
      end
    end,
  }

  -- Knoten waehlen (Konzept 7): nur vollstaendig bestaetigte Knoten lassen sich uebernehmen
  screens["2.knoten"] = {
    render = function(v, rect)
      header(v, rect, nil, "Welchen Knoten betreut diese Node?")
      local d = session.dir
      local st = dir_status()
      if st and st.kind ~= "ok" then W.label(v, rect.x + 1, rect.y + 2, st.text or "", st.kind, rect.w - 2) end
      local items = {}
      session.pick.junctions = {}
      for _, j in ipairs(d.junctions or {}) do
        local on = d.junction_choice and d.junction_choice.id == j.id
        items[#items + 1] = {
          text = (on and "(o) " or "( ) ") .. j.name,
          detail = j.connections .. " Anschluesse" .. (j.open > 0 and (", " .. j.open .. " UNBESTAETIGT") or ""),
          kind = j.open > 0 and "wait" or nil,
        }
        session.pick.junctions[#items] = j
      end
      local empty = (st and st.kind == "ok" and d.junctions) and "Das Netz hat noch keinen Knoten. In der Leitstelle auf der Seite Knoten anlegen und bestaetigen, dann 'Neu laden'." or ""
      W.list(v, "knoten_wahl", body_rect(rect, 4), items, list_state(v, "knoten_wahl"), { empty = empty })
    end,
    action = function(v, id)
      local d = session.dir
      local n = id:match("^sel:knoten_wahl:(%d+)$")
      if n then
        local j = (session.pick.junctions or {})[tonumber(n)]
        if j then
          d.junction_choice, d.junction, d.want = j, nil, "junction"
          services.directory_junction(session.wiz.central_id, j.id)
        end
        return true
      elseif id == "act:knoten_laden" then
        d.junctions, d.junction_choice, d.junction, d.want = nil, nil, nil, "junctions"
        services.directory_junctions(session.wiz.central_id)
        return true
      elseif id == "act:von_hand" then
        session.manual = true
        session.stack = {}
        goto_screen("2.name")
        return true
      end
    end,
    actions = function(v)
      return {
        { id = "knoten_laden", label = "Neu laden", kind = "secondary" },
        { id = "von_hand", label = "Von Hand", kind = "secondary" },
      }
    end,
    next = function(v)
      push("3.k.pruefen")
      return true
    end,
  }

  screens["3.k.pruefen"] = {
    render = function(v, rect)
      local d = session.dir
      header(v, rect, nil, "Knoten " .. (d.junction and d.junction.name or "?") .. ": diese Angaben werden uebernommen")
      local t, why = model.junction_from_directory(d.junction or { connections = {}, routes = {} })
      local lines = {}
      if not t then
        lines[#lines + 1] = { why, "halt" }
      else
        local names = {}
        for name in pairs(t.connections) do names[#names + 1] = name end
        table.sort(names)
        lines[#lines + 1] = { #names .. " Anschluesse: " .. table.concat(names, ", "), "text" }
        local mv = {}
        for _, m in ipairs(t.moves) do mv[#mv + 1] = m.from .. ">" .. m.to end
        lines[#lines + 1] = { #t.moves .. " Verbindungen: " .. table.concat(mv, ", "), "text" }
        lines[#lines + 1] = { #t.conflicts .. " Konflikte zwischen Verbindungen", "text" }
        local ein, aus = 0, 0
        for _, tr in ipairs(t.tracks) do if tr.role == "ein" then ein = ein + 1 else aus = aus + 1 end end
        lines[#lines + 1] = { ein .. " Einfahrten (Signal und Beobachter), " .. aus .. " Ausfahrten (Beobachter)", "text" }
        if t.unused > 0 then lines[#lines + 1] = { t.unused .. " Gleisende(n) ohne Fahrweg bleiben unberuecksichtigt.", "dim" } end
        lines[#lines + 1] = { "Die Node sperrt jede Einfahrt zusaetzlich und gibt sie nur frei, wenn die Verbindungen frei sind.", "dim" }
      end
      local y = rect.y + 2
      for _, line in ipairs(lines) do
        for _, part in ipairs(W.wrap(line[1], rect.w - 2)) do
          if y <= rect.y + rect.h - 1 then W.label(v, rect.x + 1, y, part, line[2], rect.w - 2) end
          y = y + 1
        end
      end
      local st = dir_status()
      if d.claiming and st and st.kind ~= "ok" then W.label(v, rect.x + 1, rect.y + rect.h - 1, st.text or "", st.kind, rect.w - 2) end
    end,
    -- die Kennung kommt von der Leitstelle; erst mit ihrer Antwort geht es weiter (page.poll)
    next = function(v)
      local d = session.dir
      d.claim = d.claim or services.new_claim()
      d.claiming = { junction = d.junction }
      services.directory_reset()
      services.directory_claim(session.wiz.central_id, d.claim, "knoten", nil, nil, d.junction.id)
      v.hint = "Frage die Leitstelle nach der Kennung ..."
      return true
    end,
  }

  screens["3.gleise"] = {
    render = function(v, rect)
      local d = session.dir
      header(v, rect, nil, "Gleise in " .. (d.area and d.area.name or "?") .. ": welche betreut diese Node?")
      local st = dir_status()
      if st and st.kind ~= "ok" then W.label(v, rect.x + 1, rect.y + 2, st.text or "", st.kind, rect.w - 2) end
      local items = {}
      session.pick.gleise = {}
      for _, t in ipairs(d.area and d.area.tracks or {}) do
        items[#items + 1] = { text = (d.selected and d.selected[t.id] and "[x] " or "[ ] ") .. t.name, detail = direction_text(t.direction) }
        session.pick.gleise[#items] = t
      end
      W.list(v, "gleise_auswahl", body_rect(rect, 4), items, list_state(v, "gleise_auswahl"), { empty = "Dieser Bereich hat keine Gleise." })
    end,
    action = function(v, id)
      local n = id:match("^sel:gleise_auswahl:(%d+)$")
      if n then
        local t = (session.pick.gleise or {})[tonumber(n)]
        local d = session.dir
        if t and d.selected and not d.claiming then d.selected[t.id] = (not d.selected[t.id]) or nil end
        return true
      end
    end,
    -- die Kennung kommt von der Leitstelle; erst mit ihrer Antwort geht es weiter (page.poll)
    next = function(v)
      local d = session.dir
      local chosen, info = {}, {}
      for _, t in ipairs(d.area.tracks) do
        if d.selected[t.id] then chosen[#chosen + 1] = t.id; info[#info + 1] = t end
      end
      if #chosen == 0 then v.hint = "Mindestens ein Gleis uebernehmen." return true end
      d.claim = d.claim or services.new_claim()
      d.claiming = { tracks = info }
      services.directory_claim(session.wiz.central_id, d.claim, session.wiz.roles[1] or "signal", d.area.id, chosen)
      v.hint = "Frage die Leitstelle nach der Kennung ..."
      return true
    end,
  }

  -- naechstes Gleis ohne Signal (nach der Zuordnung springt die Auswahl dorthin)
  function select_next_open(v, from)
    local rows = session.wiz.guided_rows()
    local state = list_state(v, "zuordnung")
    local start = from or state.index
    for offset = 1, #rows do
      local i = (start - 1 + offset) % #rows + 1
      if #rows[i].signals == 0 then state.index = i return end
    end
  end

  local function signal_states()
    session.pick.sigstate = {}
    for _, d in ipairs(session.wiz.guided_free_signals()) do
      local st = signallib.new(services.env, d.name).read()
      session.pick.sigstate[d.name] = st.available and tostring(st.state) or "nicht lesbar"
    end
  end

  screens["4.zuordnung"] = {
    render = function(v, rect)
      header(v, rect, nil, "Welches Signal gehoert zu welchem Gleis?")
      local items = {}
      session.pick.rows = {}
      for _, r in ipairs(session.wiz.guided_rows()) do
        local devices, open = {}, false
        for _, s in ipairs(r.signals) do
          devices[#devices + 1] = s.device .. (s.effect and "" or " (Richtung?)")
          if not s.effect then open = true end
        end
        items[#items + 1] = {
          text = r.name .. "  " .. direction_text(r.direction),
          detail = #devices > 0 and table.concat(devices, ", ") or "Signal fehlt",
          kind = (#devices > 0 and not open) and "ok" or "wait",
        }
        session.pick.rows[#items] = r
      end
      W.list(v, "zuordnung", body_rect(rect, 3), items, list_state(v, "zuordnung"), { empty = "Keine Gleise uebernommen." })
    end,
    actions = function(v)
      local row = session.pick.rows and session.pick.rows[list_state(v, "zuordnung").index]
      local free = #session.wiz.guided_free_signals()
      return {
        { id = "signal_waehlen", label = "Signal", enabled = row ~= nil and free > 0, reason = row == nil and "Erst ein Gleis waehlen." or "Es ist kein freies Signal angeschlossen." },
        { id = "signal_loesen", label = "Loesen", kind = "secondary", enabled = row ~= nil and #row.signals > 0, reason = "An diesem Gleis ist kein Signal zugeordnet." },
        { id = "signal_details", label = "Details", kind = "secondary", enabled = row ~= nil and #row.signals > 0, reason = "An diesem Gleis ist kein Signal zugeordnet." },
        { id = "gleis_aendern", label = "Gleis", kind = "secondary", enabled = row ~= nil, reason = "Erst ein Gleis waehlen." },
      }
    end,
    action = function(v, id)
      local row = session.pick.rows and session.pick.rows[list_state(v, "zuordnung").index]
      if id == "act:signal_waehlen" and row then
        session.track = row.track
        session.wiz.rescan()
        signal_states()
        push("4.z.signal")
        return true
      elseif id == "act:signal_loesen" and row then
        local ok, why = session.wiz.guided_unassign(row.track)
        if not ok then v.hint = why end
        return true
      elseif id == "act:signal_details" and row and #row.signals > 0 then
        session.track = row.track
        push("4.z.detail")
        return true
      elseif id == "act:gleis_aendern" and row then
        session.track = row.track
        session.dir.edit = { direction = row.direction }
        fields(v).gleisname.value = row.name
        push("4.z.gleis")
        return true
      end
    end,
    next = function(v)
      push("5.pruefen")
      return true
    end,
  }

  -- Name und Richtung eines Gleises auf der Node aendern (Konzept 12.4): die Leitstelle fuehrt die Aenderung aus (Verzeichnis), die Node zieht nach
  screens["4.z.gleis"] = {
    no_forward = true,
    render = function(v, rect)
      local row
      for _, r in ipairs(session.wiz.guided_rows()) do if r.track == session.track then row = r end end
      header(v, rect, nil, "Gleis aendern: " .. (row and row.name or "?"))
      W.field(v, "gleisname", rect.x + 1, rect.y + 3, math.min(rect.w - 2, 36), "Gleisname", fields(v).gleisname)
      local edit = session.dir.edit or {}
      W.label(v, rect.x + 1, rect.y + 7, "Richtung: " .. direction_text(edit.direction or (row and row.direction) or "beide"), "text", rect.w - 2)
      local st = dir_status()
      if session.dir.editing and st and st.kind ~= "ok" then W.label(v, rect.x + 1, rect.y + 9, st.text or "", st.kind, rect.w - 2) end
    end,
    actions = function(v)
      return {
        { id = "g_richtung", label = "Richtung", kind = "secondary", enabled = not session.dir.editing, reason = "Die Leitstelle arbeitet noch." },
        { id = "g_speichern", label = "Speichern", enabled = not session.dir.editing, reason = "Die Leitstelle arbeitet noch." },
      }
    end,
    action = function(v, id)
      local edit = session.dir.edit
      if not edit or session.dir.editing then return false end
      if id == "act:g_richtung" then
        local options = {}
        for _, e in ipairs(session.wiz.area_ends()) do options[#options + 1] = e end
        options[#options + 1] = "beide"
        for i, o in ipairs(options) do
          if o == edit.direction then edit.direction = options[i % #options + 1] return true end
        end
        edit.direction = options[1]
        return true
      elseif id == "act:g_speichern" then
        local row
        for _, r in ipairs(session.wiz.guided_rows()) do if r.track == session.track then row = r end end
        if not row then return true end
        local name = fields(v).gleisname.value:match("^%s*(.-)%s*$")
        local change = {}
        if name ~= row.name then change.name = name end
        if edit.direction ~= row.direction then change.direction = edit.direction end
        if next(change) == nil then v.hint = "Nichts geaendert." pop() return true end
        if name == "" then v.hint = "Der Gleisname fehlt." return true end
        services.directory_reset()
        session.dir.editing = { dir_id = row.dir_id }
        services.directory_track_change(session.wiz.central_id, session.dir.claim, row.dir_id, change, row.rev)
        v.hint = "Frage die Leitstelle ..."
        return true
      end
    end,
  }

  -- Funktion, Wirkrichtung und Standort der Signale eines Gleises (Konzept 5.4); Vorgabe: Streckensignal, Wirkrichtung = Gleisrichtung
  local function detail_rows()
    for _, r in ipairs(session.wiz.guided_rows()) do
      if r.track == session.track then return r end
    end
    return nil
  end

  screens["4.z.detail"] = {
    no_forward = true,
    render = function(v, rect)
      local row = detail_rows()
      header(v, rect, nil, "Signale von " .. (row and row.name or "?") .. ": Funktion, Wirkrichtung, Standort")
      local items = {}
      session.pick.detail = {}
      for _, sg in ipairs(row and row.signals or {}) do
        items[#items + 1] = {
          text = sg.device .. "  " .. (wizardlib.USE_TEXT[sg.use] or sg.use),
          detail = (sg.effect and ("wirkt Richtung " .. sg.effect) or "WIRKRICHTUNG FEHLT") .. ", Standort " .. (sg.place and (sg.place == "mitte" and "Mitte" or ("Ende " .. sg.place)) or "offen"),
          kind = sg.effect and "ok" or "wait",
        }
        session.pick.detail[#items] = sg
      end
      W.list(v, "detail", body_rect(rect, 3), items, list_state(v, "detail"), { empty = "Kein Signal an diesem Gleis." })
    end,
    actions = function(v)
      local sg = session.pick.detail and session.pick.detail[list_state(v, "detail").index]
      return {
        { id = "d_funktion", label = "Funktion", enabled = sg ~= nil, reason = "Erst ein Signal waehlen." },
        { id = "d_richtung", label = "Richtung", enabled = sg ~= nil, reason = "Erst ein Signal waehlen." },
        { id = "d_standort", label = "Standort", kind = "secondary", enabled = sg ~= nil, reason = "Erst ein Signal waehlen." },
      }
    end,
    action = function(v, id)
      local sg = session.pick.detail and session.pick.detail[list_state(v, "detail").index]
      local field = ({ ["act:d_funktion"] = "use", ["act:d_richtung"] = "effect", ["act:d_standort"] = "place" })[id]
      if field and sg then
        local ok, why = session.wiz.signal_cycle(sg.id, field)
        if not ok then v.hint = why end
        return true
      end
    end,
  }

  screens["4.z.signal"] = {
    render = function(v, rect)
      local track = session.wiz.config.tracks[session.track]
      header(v, rect, nil, "Welches Signal gehoert zu " .. (track and track.name or "?") .. "?")
      local items = {}
      session.pick.freie = {}
      for _, d in ipairs(session.wiz.guided_free_signals()) do
        local fresh = session.known_signals and not session.known_signals[d.name]
        items[#items + 1] = { text = d.name .. (fresh and "  (neu)" or ""), detail = (session.pick.sigstate and session.pick.sigstate[d.name]) or "" }
        session.pick.freie[#items] = d
      end
      W.list(v, "signal", body_rect(rect, 3), items, list_state(v, "signal"), { empty = "Kein freies Signal angeschlossen." })
    end,
    action = function(v, id)
      local n = id:match("^sel:signal:(%d+)$")
      if n then
        local d = (session.pick.freie or {})[tonumber(n)]
        if d then
          local ok, why = session.wiz.guided_assign(session.track, d.name)
          if not ok then v.hint = why return true end
          pop()
          select_next_open(v)
        end
        return true
      end
    end,
  }

  local function activate(v)
    local w = session.wiz
    local ok, why = w.step_ok(5)
    if not ok then v.hint = why return false end
    local status, problems, err = w.finish(services.store, services.config_path)
    if not status then v.hint = "Speichern fehlgeschlagen: " .. tostring(err) return false end
    if status ~= "aktiv" then
      v.hint = "Nicht aktiviert: " .. tostring(problems[1] and problems[1].text or "Pflichtangaben offen")
      return false
    end
    services.on_saved(w.config)
    services.notify("info", "Einrichtung gespeichert: aktiv (" .. w.config.node.id .. ")")
    v.hint = "Aktiviert: " .. w.config.node.name
    session.wiz, session.owner, session.checking = nil, nil, false
    return true
  end

  screens["5.pruefen"] = {
    no_forward = true,
    hide_nav_buttons = function() return session.checking end,
    render = function(v, rect)
      header(v, rect, nil, "Zuordnung bestaetigen, pruefen, aktivieren")
      local p = ensure_check()
      local st = p.state()
      local y = rect.y + 2
      if st.phase == "idle" then
        local c = session.wiz.config
        local lines = { c.node.id .. ": " .. #session.wiz.tracks() .. " Gleis(e), " .. #st.devices .. " Signal(e)" }
        local effect = p.effect()
        for _, line in ipairs(W.wrap(effect, rect.w - 2)) do lines[#lines + 1] = line end
        for _, line in ipairs(lines) do
          if y <= rect.y + rect.h - 1 then W.label(v, rect.x + 1, y, line, "text", rect.w - 2) end
          y = y + 1
        end
        local problems = p.required()
        if #problems > 0 and y <= rect.y + rect.h - 1 then W.label(v, rect.x + 1, y + 1, problems[1], "wait", rect.w - 2) end
        return
      end
      local text
      if st.phase == "laeuft" then
        text = "Pruefe " .. (st.current or "...") .. " (" .. st.done .. " von " .. st.total .. ")"
      elseif st.phase == "abgebrochen" then
        text = "Abgebrochen nach " .. st.done .. " von " .. st.total .. " Pruefungen."
      else
        text = st.ok and "Alle Pruefungen bestanden." or "Fertig, aber nicht alles bestanden:"
      end
      W.label(v, rect.x + 1, rect.y + 2, text, st.phase == "laeuft" and "wait" or (st.ok and "ok" or "attention"), rect.w - 2)
      local items = {}
      for _, d in ipairs(st.devices) do
        local r = d.result
        local detail, kind
        if r.lesen.state == "ok" and r.sperre.state == "ok" then detail, kind = "gelesen, Sperre getestet", "ok"
        elseif r.lesen.state == "fehler" then detail, kind = r.lesen.text or "nicht lesbar", "halt"
        elseif r.sperre.state == "fehler" or r.sperre.state == "gesperrt" then detail, kind = r.sperre.text or "Sperre nicht bestaetigt", "halt"
        else detail, kind = "offen", "wait" end
        items[#items + 1] = { text = d.track .. "  " .. d.device, detail = detail, kind = kind }
      end
      W.list(v, "pruefliste", body_rect(rect, 4), items, list_state(v, "pruefliste"), { empty = "Keine Signale." })
    end,
    actions = function(v)
      local p = ensure_check()
      local st = p.state()
      if st.phase == "laeuft" then
        return { { id = "pruefung_stopp", label = "Stoppen", kind = "danger" } }
      end
      local problems = p.required()
      return { { id = "pruefen", label = st.phase == "idle" and "Pruefen+Aktivieren" or "Erneut pruefen", enabled = #problems == 0, reason = problems[1] } }
    end,
    action = function(v, id)
      local p = ensure_check()
      if id == "act:pruefen" then
        local ok, why = p.start(true)
        if not ok then v.hint = why return true end
        session.checking = true
        v.hint = "Pruefung laeuft."
        return true
      elseif id == "act:pruefung_stopp" then
        p.abort()
        session.checking = false
        v.hint = "Pruefung gestoppt; es bleibt keine Testsperre zurueck."
        return true
      end
    end,
  }

  screens["6.fertig"] = {
    render = function(v, rect)
      header(v, rect, nil, "Zusammenfassung")
      local w = session.wiz
      local c = w.config
      local roles = {}
      for _, r in ipairs(c.node.roles) do roles[#roles + 1] = model.ROLE_TEXT[r] end
      local lines = {
        "Netz: " .. c.network.name .. (c.network.central_id and ("   Leitstelle: " .. c.network.central_id) or "   (diese Node ist die Leitstelle)"),
        "Node: " .. c.node.name .. " (" .. c.node.id .. ")  Rolle: " .. table.concat(roles, ", "),
      }
      local tracks = #w.tracks()
      if tracks > 0 then lines[#lines + 1] = "Gleise: " .. tracks end
      local problems = w.warnings()
      local tests_ok = w.all_tests_ok()
      lines[#lines + 1] = "Pruefungen: " .. (tests_ok and "alle bestanden" or "offen")
      lines[#lines + 1] = (#problems == 0 and tests_ok) and "Bereit zum Aktivieren." or "Wird als ENTWURF gespeichert; die Betriebsfunktion bleibt inaktiv."
      local y = rect.y + 2
      for _, line in ipairs(lines) do
        if y <= rect.y + rect.h - 1 then W.label(v, rect.x + 1, y, line, (line:find("ENTWURF", 1, true)) and "attention" or "text", rect.w - 2) end
        y = y + 1
      end
      for _, p in ipairs(problems) do
        if y <= rect.y + rect.h - 1 then W.label(v, rect.x + 1, y, "- " .. p.text, "wait", rect.w - 2) end
        y = y + 1
      end
    end,
    action = function(v, id)
      if id == "act:speichern" then
        local ok, why = session.wiz.step_ok(5)       -- liest die Geraete vorher frisch
        if not ok then v.hint = why return true end
        local status, problems, err = session.wiz.finish(services.store, services.config_path)
        if not status then
          v.hint = "Speichern fehlgeschlagen: " .. tostring(err)
          return true
        end
        services.on_saved(session.wiz.config)
        services.notify(status == "aktiv" and "info" or "warnung", "Einrichtung gespeichert: " .. status)
        v.hint = "Gespeichert: " .. status
        session.wiz, session.owner = nil, nil
        return true
      end
    end,
    actions = function(v)
      local ok = session.wiz and #session.wiz.warnings() == 0 and session.wiz.all_tests_ok()
      return { { id = "speichern", label = "Aktivieren", enabled = ok, reason = "Pflichtangaben und Pruefungen muessen vollstaendig sein." } }
    end,
  }

  -- Seite -----------------------------------------------------------------------------------------------------------------------------------
  local function screen_def() return screens[session.screen] end

  -- Ersatzcomputer (29.2): die Konfiguration einer stillgelegten Node von der Leitstelle holen und uebernehmen
  local function rfields(v)
    local st = v.page_state("einrichtung")
    st.rfields = st.rfields or { central = { value = "", max = 30 }, node = { value = "", max = 30 } }
    return st.rfields
  end

  function page.render(v, rect)
    if session.replace and not session.wiz then
      W.label(v, rect.x + 1, rect.y, "Ersatzcomputer: vorhandene Node uebernehmen", "hell", rect.w - 2)
      local f = rfields(v)
      W.field(v, "r_central", rect.x + 1, rect.y + 2, math.min(rect.w - 2, 36), "Kennung der Leitstelle", f.central)
      W.field(v, "r_node", rect.x + 1, rect.y + 5, math.min(rect.w - 2, 36), "Kennung der zu ersetzenden Node", f.node)
      local st = services.fetch_status and services.fetch_status()
      if st then W.label(v, rect.x + 1, rect.y + 9, st.text, st.kind, rect.w - 2) end
      return
    end
    if not session.wiz then
      W.label(v, rect.x + 1, rect.y, "Einrichtung", "hell")
      local config = services.config()
      local text = config
        and ("Dieser Node ist eingerichtet: " .. config.node.name .. " (" .. config.status .. "). Die Einrichtung kann geaendert werden.")
        or "Dieser Computer ist noch nicht eingerichtet. Der Assistent fuehrt in sechs Schritten durch Anlage, Rolle, Geraete, Gleise, Test und Abschluss."
      for i, line in ipairs(W.wrap(text, rect.w - 2)) do W.label(v, rect.x + 1, rect.y + 1 + i, line, "text", rect.w - 2) end
      return
    end
    if session.owner ~= v then
      W.label(v, rect.x + 1, rect.y, "Einrichtung wird bearbeitet.", "attention")
      W.label(v, rect.x + 1, rect.y + 2, "Eine andere Bedienoberflaeche fuehrt gerade den Assistenten.", "text", rect.w - 2)
      return
    end
    local def = screen_def()
    if v.layout.mode == "gross" then
      local S = require("ui.palette").SLOT
      local x = rect.x + rect.w - 26
      v.canvas.fill(x, rect.y, 26, rect.h, S.navigation)
      W.label(v, x + 2, rect.y + 1, "DEINE EINRICHTUNG", "hell", 22)
      local w = session.wiz
      local lines = { w.name ~= "" and w.name or "Name noch offen", "Netz: " .. w.network_name }
      for _, role in ipairs(w.roles) do lines[#lines+1] = model.ROLE_TEXT[role] end
      lines[#lines+1] = ""
      lines[#lines+1] = "Schritt " .. w.step .. " von 6"
      lines[#lines+1] = "Entwurf jederzeit speichern."
      lines[#lines+1] = "Aktiv erst nach allen Pflichtpruefungen."
      local y=rect.y+3
      for _, text in ipairs(lines) do
        for _, part in ipairs(W.wrap(text,22)) do
          if y < rect.y+rect.h then W.label(v,x+2,y,part,"text",22); y=y+1 end
        end
        y=y+1
      end
      rect = { x=rect.x, y=rect.y, w=rect.w-28, h=rect.h }
    end
    if def then def.render(v, rect) end
  end

  local function can_advance(v)
    commit(v)
    local w, screen = session.wiz, session.screen
    local track = session.track and w.config.tracks[session.track]
    if screen == "1.netzwahl" and not session.net_choice then return false, "Bitte ein Netz waehlen oder \"von Hand eingeben\"." end
    if screen == "1.netz" and not w.network_name:match("%S") then return false, "Der Netzname fehlt." end
    if screen == "1.zentrale" and not w.central_id:match("%S") then return false, "Die Kennung der Leitstelle fehlt." end
    if screen == "2.rollen" then
      if #w.roles == 0 then return false, "Bitte mindestens eine Rolle waehlen." end
      if w.mode == "create" and not model.has_role(w.config, "zentrale") then return false, "Die erste Node braucht die Rolle Leitstelle." end
      if w.mode == "join" and model.has_role(w.config, "zentrale") then return false, "Eine zweite Leitstelle ist nicht vorgesehen." end
    end
    if screen == "2.bereich" and not session.dir.area then return false, "Bitte einen Bereich waehlen." end
    if screen == "2.knoten" then
      local d = session.dir
      if not d.junction_choice then return false, "Bitte einen Knoten waehlen." end
      if d.junction_choice.open > 0 then return false, "Der Knoten hat unbestaetigte Fahrwege oder Konflikte: erst in der Leitstelle bestaetigen." end
      if not d.junction then return false, "Der Knoten wird noch geladen." end
      local _, why = model.junction_from_directory(d.junction)
      if why then return false, why end
    end
    if screen == "3.k.pruefen" then
      if session.dir.claiming then return false, "Frage die Leitstelle nach der Kennung ..." end
      local _, why = model.junction_from_directory(session.dir.junction or { connections = {}, routes = {} })
      if why then return false, why end
    end
    if screen == "3.gleise" then
      if session.dir.claiming then return false, "Frage die Leitstelle nach der Kennung ..." end
      local any = false
      for _ in pairs(session.dir.selected or {}) do any = true end
      if not any then return false, "Mindestens ein Gleis uebernehmen." end
    end
    if screen == "4.zuordnung" then
      for _, r in ipairs(w.guided_rows()) do
        if #r.signals == 0 then return false, r.name .. ": Das Signal fehlt noch." end
      end
      if #w.guided_rows() == 0 then return false, "Keine Gleise uebernommen." end
      local open = w.signal_problems()
      if #open > 0 then return false, open[1].device .. " (" .. open[1].track_name .. "): Wirkrichtung fehlt (Details)." end
    end
    if screen == "2.name" then return w.step_ok(2, true) end
    if screen == "3.geraete" then return w.step_ok(3, true) end
    if screen == "4.g.name" and not fields(v).gleisname.value:match("%S") then return false, "Der Gleisname fehlt." end
    if track then
      if screen == "4.g.bahnhof" and not track.station then return false, "Bitte eine Train Station zuordnen." end
      if screen == "4.g.signale" and (model.has_role(w.config, "signal") or track.junction and track.junction.role == "ein") and #track.signals == 0 then return false, "Bitte ein Signal zuordnen." end
      if screen == "4.g.beobachter" and track.junction and #track.observers == 0 then return false, "Der Meldepunkt braucht einen Beobachter." end
      if screen == "4.g.ausgang" and not track.release then return false, "Bitte einen Freigabeausgang zuordnen." end
    end
    if screen == "4.gleise" or screen == "4.anmeldung" then return w.step_ok(4, true) end
    if screen == "4.knoten" then
      local j=w.config.junction; local n=0; for _ in pairs(j.connections) do n=n+1 end
      if n<2 or #j.moves==0 then return false, "Zwei Anschluesse und eine Verbindung sind erforderlich." end
    end
    if screen == "5.test" then return w.step_ok(5, true) end
    return true
  end

  function page.hint(v)
    if session.wiz and session.owner == v then
      local ok, why = can_advance(v)
      if not ok then return why end
    end
    return ""
  end

  function page.navigation(v)
    if not session.wiz or session.owner ~= v then return nil end
    local items = {}
    for i, title in ipairs(wizardlib.STEPS) do
      items[i] = { title = i .. "  " .. title, active = session.wiz.step == i }
    end
    return items
  end

  function page.actions(v)
    if session.replace and not session.wiz then
      local st = services.fetch_status and services.fetch_status()
      return {
        { id = "r_holen", label = "Holen" },
        { id = "r_uebernehmen", label = "Uebernehmen", enabled = st ~= nil and st.config ~= nil, reason = "Erst die Konfiguration holen." },
        { id = "r_abbruch", label = "Abbrechen", kind = "danger", side = "rechts" },
      }
    end
    if not session.wiz then
      local config = services.config()
      local list = { { id = "start", label = config and "Einrichtung aendern" or "Einrichtung starten" } }
      if not config and services.fetch_config then list[#list + 1] = { id = "ersatz", label = "Ersatz", kind = "secondary" } end
      return list
    end
    if session.owner ~= v then return {} end
    local def = screen_def()
    local list = {}
    if def and def.actions then for _, a in ipairs(def.actions(v)) do list[#list + 1] = a end end
    local hide = def and ((type(def.hide_nav_buttons) == "function" and def.hide_nav_buttons(v)) or def.hide_nav_buttons == true)
    if not hide then
      list[#list + 1] = { id = "zurueck", label = "Zurueck", kind = "secondary", side = "rechts" }
      if session.screen ~= "6.fertig" and not (def and def.no_forward) then
        local ok, why = can_advance(v)
        list[#list + 1] = { id = "weiter", label = "Weiter", side = "rechts", enabled = ok, reason = why }
      end
    end
    local active = session.wiz and session.wiz.was_active
    list[#list + 1] = { id = "entwurf", label = "Entwurf", kind = "secondary", enabled = not active, reason = "Laufende Node: Aenderungen gelten erst mit Aktivieren; Abbrechen verwirft sie." }
    list[#list + 1] = { id = "abbrechen", label = session.cancel_armed and "Wirklich?" or "Abbrechen", kind = "danger", side = "rechts" }
    return list
  end

  local function advance(v)
    local def = screen_def()
    commit(v)
    local allowed, reason = can_advance(v)
    if not allowed then v.hint = reason return true end
    if session.screen == "1.netzwahl" and type(session.net_choice) == "table" then
      session.wiz.set_network(session.net_choice.netz, session.net_choice.zentrale, nil)
    end
    if session.screen == "1.netz" and session.wiz.network_name == "" then v.hint = "Der Netzname fehlt." return true end
    if session.screen == "1.zentrale" and session.wiz.central_id == "" then v.hint = "Die Kennung der Leitstelle fehlt." return true end
    if def and def.next then return def.next(v) end
    local seq = sequence()
    local index = index_of(seq, session.screen)
    if not index then return false end
    local current_step = step_of(session.screen)
    local target = seq[index + 1]
    if not target then return true end
    -- Hauptschritte 1 und 2 muessen vollstaendig sein
    if step_of(target) ~= current_step then
      local ok, why = session.wiz.step_ok(current_step)
      if not ok then v.hint = why return true end
    elseif session.screen == "2.rollen" then
      local ok, why = session.wiz.step_ok(2)
      if #session.wiz.roles == 0 then v.hint = "Bitte mindestens eine Rolle waehlen." return true end
    end
    if session.screen == "2.name" then
      local ok, why = session.wiz.step_ok(2)
      if not ok then v.hint = why return true end
    end
    session.stack = {}
    goto_screen(target)
    if step_of(target) == 3 then session.wiz.rescan() end
    return true
  end

  local function retreat(v)
    if pop() then return true end
    local seq = sequence()
    local index = index_of(seq, session.screen)
    if index and index > 1 then goto_screen(seq[index - 1]) end
    return true
  end

  function page.on_action(v, id)
    if session.replace and not session.wiz then
      local f = rfields(v)
      if id == "act:r_holen" then
        if f.central.value == "" or f.node.value == "" then v.hint = "Beide Kennungen sind noetig." return true end
        services.fetch_config(f.central.value, f.node.value)
        return true
      elseif id == "act:r_uebernehmen" then
        local st = services.fetch_status and services.fetch_status()
        if st and st.config then
          session.replace = nil
          start(v, st.config)
          goto_screen("6.fertig")
          v.hint = "Konfiguration uebernommen: Geraete pruefen, dann speichern."
        end
        return true
      elseif id == "act:r_abbruch" then
        session.replace = nil
        return true
      elseif id:match("^input:") then
        return true
      end
      return false
    end
    if not session.wiz then
      if id == "act:start" then
        start(v, services.config())
        return true
      elseif id == "act:ersatz" then
        session.replace = true
        return true
      end
      return false
    end
    if session.owner ~= v then return false end
    if id == "act:entwurf" then
      if session.wiz.was_active then v.hint = "Laufende Node: Aenderungen gelten erst mit Aktivieren; Abbrechen verwirft sie." return true end
      commit(v)
      local status, _, err = session.wiz.finish(services.store, services.config_path, true)
      if not status then v.hint = "Speichern fehlgeschlagen: " .. tostring(err) return true end
      services.on_saved(session.wiz.config)
      session.wiz, session.owner = nil, nil
      v.hint = "Entwurf gespeichert; die Node bleibt inaktiv."
      return true
    end
    if id == "act:weiter" then return advance(v) end
    if id == "act:zurueck" or id == "back" then
      commit(v)
      return retreat(v)
    end
    if id == "act:abbrechen" then
      if session.cancel_armed then
        session.wiz, session.owner, session.stack = nil, nil, {}
        v.hint = "Verworfen; gespeicherte Einrichtung bleibt."
      else
        session.cancel_armed = true
        v.hint = "Nochmal druecken verwirft die Eingaben."
      end
      return true
    end
    local def = screen_def()
    if def and def.action and def.action(v, id) then return true end
    if id:match("^input:") then
      commit(v)
      return true
    end
    return false
  end

  -- Antworten der Leitstelle verarbeiten (ruft die Knotenlaufzeit nach jeder Antwort und im Sekundentakt)
  function page.poll()
    local v = session.owner
    if not session.wiz or not v then return end
    local d = session.dir
    local st = dir_status()
    if not st then return end
    if st.kind == "ok" then
      if st.junctions and d.want == "junctions" then d.junctions, d.want = st.junctions, nil end
      if st.junction and d.want == "junction" then d.junction, d.want = st.junction, nil end
      if st.areas and d.want == "areas" then
        d.areas, d.want = st.areas, nil
        if d.preselect then
          for _, a in ipairs(d.areas) do if a.id == d.preselect then choose_area(a) end end
          d.preselect = nil
        end
      end
      if st.area and d.want == "area" then d.area, d.want = st.area, nil end
      if st.node and d.claiming then
        local claiming = d.claiming
        d.claiming = nil
        local role = session.wiz.roles[1]
        if role == "knoten" then
          local ok, why = session.wiz.knoten_begin({ junction = claiming.junction, claim = d.claim, node = st.node })
          if not ok then v.hint = why return end
          v.hint = "Kennung " .. st.node.id .. " von der Leitstelle."
          push("3.geraete")
          return
        end
        session.wiz.guided_begin({ area = { id = d.area.id, name = d.area.name, ends = d.area.ends }, claim = d.claim, node = st.node, tracks = claiming.tracks, role = role })
        v.hint = "Kennung " .. st.node.id .. " von der Leitstelle."
        if role == "signal" then
          ensure_check()
          session.known_signals = {}
          for _, dev in ipairs(session.wiz.guided_free_signals()) do session.known_signals[dev.name] = true end
          push("4.zuordnung")
          select_next_open(v, 0)
        else
          push("3.geraete")
        end
      end
    elseif st.kind == "halt" and d.claiming then
      d.claiming = nil
      v.hint = st.text
    end
    if d.creating then
      if st.kind == "ok" and st.created then
        local created = st.created
        d.creating, d.areas, d.chosen, d.area, d.want, d.preselect = nil, nil, nil, nil, "areas", created.id
        v.hint = "Bereich " .. created.name .. " angelegt."
        if session.screen == "2.b.neu" then pop() end
        services.directory_areas(session.wiz.central_id)
        return
      elseif st.kind == "halt" then
        d.creating = nil
        v.hint = st.text
      end
    end
    if d.editing then
      if st.kind == "ok" and st.track and st.track.id == d.editing.dir_id then
        d.editing = nil
        local moved = session.wiz.guided_track_update(st.track)
        v.hint = "Gleis geaendert" .. ((moved or 0) > 0 and (": " .. moved .. " Signal(e) neu bewerten (Details).") or ".")
        if session.screen == "4.z.gleis" then pop() end
      elseif st.kind == "halt" then
        d.editing = nil
        v.hint = st.text
      end
    end
  end

  -- Sekundentakt: Antworten abholen, die Abschlusspruefung schrittweise weiterfuehren
  function page.tick()
    if not session.wiz or not session.owner then return end
    page.poll()
    if session.checking and session.wiz and session.wiz.pruefung then
      local p = session.wiz.pruefung
      local phase = p.step(0.8)
      if services.mark_dirty then services.mark_dirty() end
      if phase == "fertig" then
        session.checking = false
        if p.all_ok() then
          activate(session.owner)
        else
          session.owner.hint = "Nicht alles bestanden: Zuordnung oder Sperre pruefen, dann erneut pruefen."
        end
      elseif phase == "abgebrochen" then
        session.checking = false
      end
    end
  end

  -- fuer Tests und die Knotenlaufzeit
  function page.session() return session end

  return page
end

return M
