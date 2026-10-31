--[[
Purpose: Seite "Einrichtung" der Oberflaeche: fuehrt den Assistenten (setup/wizard) in sechs Hauptschritten. Jeder Schritt besteht aus kleinen Bildschirmen (eine Liste oder ein bis zwei Felder), damit er auch auf der kompakten Flaeche (51x19) passt. Ablauf: Anlage, Rolle, Geraete, Gleise, Test, Fertig. Es bearbeitet immer nur eine Ansicht die Einrichtung; andere zeigen "Einrichtung wird bearbeitet" (Konzept 28.4).
API: setup_page.new(services) -> Seite fuer ui/view; services = { scan(), env, now, store, config_path, config() -> aktuelle Konfiguration oder nil, on_saved(config), notify(level, text) }
Notes: Technische Anschlussnamen sind hier sichtbar (Schritt 3 und 4), im Betrieb ersetzen Gleisnamen sie. Schaltende Pruefungen verlangen eine Bestaetigung auf einem eigenen Bildschirm, der Geraet, erwartete Wirkung und den noetigen Ausgangszustand nennt. Mit "Abbrechen" (zweimal) werden die Eingaben verworfen; die gespeicherte Einrichtung bleibt unveraendert.
]]

local wizardlib = require("setup.wizard")
local model = require("setup.model")
local detect = require("dev.detect")
local W = require("ui.widgets")

local M = {}

local DIRECTIONS = { { id = "hin", text = "hin (eine Richtung)" }, { id = "rueck", text = "rueck (Gegenrichtung)" }, { id = "beide", text = "beide Richtungen" } }

function M.new(services)
  local page = { id = "einrichtung", title = "Einrichtung" }

  -- gemeinsamer Zustand aller Ansichten: wer bearbeitet gerade?
  local session = { owner = nil, wiz = nil, screen = nil, stack = {}, track = nil, cancel_armed = false, test_pending = nil, pick = {} }

  local function sequence()
    local seq = { "1.modus" }
    if session.wiz.mode == "join" and services.search_networks then
      -- Beitreten: erst die Netze in Reichweite zur Auswahl; Name und Leitstelle von Hand nur, wenn keines passt
      seq[#seq + 1] = "1.netzwahl"
      if not (type(session.net_choice) == "table") then seq[#seq + 1] = "1.netz"; seq[#seq + 1] = "1.zentrale" end
    else
      seq[#seq + 1] = "1.netz"
      if session.wiz.mode == "join" then seq[#seq + 1] = "1.zentrale" end
    end
    seq[#seq + 1] = "2.rollen"
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
    if screen == "1.netzwahl" then
      session.net_choice = nil
      services.search_networks()
    elseif screen == "5.test" or screen == "6.fertig" then
      -- Pruefungen laufen von selbst; schaltende nur, wenn der Zustand beweist, dass nichts betroffen ist, sonst warten sie auf die Bestaetigung
      local ran, passed, waiting = session.wiz.auto_tests(true)
      if session.owner and ran + waiting > 0 then
        session.owner.hint = ran .. " Pruefung(en) automatisch, " .. passed .. " bestanden" .. (waiting > 0 and (", " .. waiting .. " warten auf Bestaetigung") or "") .. "."
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
    goto_screen("1.modus")
    -- Felder aus dem Zustand vorbelegen
    local st = v.page_state("einrichtung")
    st.fields = {
      netz = { value = session.wiz.network_name, max = 30 },
      schluessel = { value = session.wiz.key, max = 30 },
      zentrale = { value = session.wiz.central_id, max = 30 },
      name = { value = session.wiz.name, max = 30 },
      gleisname = { value = "", max = 30 },
      anschluss = { value = "", max = 20 },
    }
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
    W.label(v, rect.x + 1, rect.y, string.format("Schritt %d von %d: %s", w.step, #wizardlib.STEPS, wizardlib.STEPS[w.step]), "hell")
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
      if rect.h > 9 then W.label(v, rect.x + 1, rect.y + 8, "Oder alles automatisch einrichten (Knopf unten).", "dim", rect.w - 2) end
    end,
    action = function(v, id)
      if id == "act:auto" then
        commit(v)
        local ok, why = session.wiz.step_ok(2)
        if not ok then v.hint = why return true end
        return page.auto_setup(v)
      end
    end,
    actions = function(v) return { { id = "auto", label = "Automatisch einrichten", kind = "secondary" } } end,
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
      if id == "act:alle_passenden" then
        local added = session.wiz.select_suitable()
        v.hint = added > 0 and (added .. " Geraet(e) gewaehlt.") or "Keine weiteren passenden Geraete."
        return true
      end
    end,
    actions = function(v) return { { id = "alle_passenden", label = "Alle passenden", kind = "secondary" }, { id = "neu_scannen", label = "Neu lesen", kind = "secondary" } } end,
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
      W.list(v, "gleise", body_rect(rect, 3), items, list_state(v, "gleise"), { empty = "Noch kein Gleis. 'Neues Gleis' legt eines an." })
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
        push("4.g.name")
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
      elseif id == "act:auto_gleise" then
        local ok, notes, count = session.wiz.auto_tracks()
        if not ok then v.hint = notes return true end
        v.hint = count .. " Gleis(e) angelegt" .. (#notes > 0 and (": " .. table.concat(notes, "; ")) or ".")
        return true
      end
    end,
    actions = function(v)
      local has_selection = session.pick.tracks and session.pick.tracks[list_state(v, "gleise").index] ~= nil
      local reason = "Erst ein Gleis in der Liste waehlen."
      return {
        { id = "neues_gleis", label = "Neu" },
        { id = "auto_gleise", label = "Automatisch", kind = "secondary", enabled = #session.wiz.tracks() == 0, reason = "Die Automatik legt nur neue Gleise an (Liste ist nicht leer)." },
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
      local c = session.wiz.config
      if model.has_role(c, "knoten") then
        push("4.g.anschluss")
      elseif model.has_role(c, "passagierbahnhof") or model.has_role(c, "gueterbahnhof") or model.has_role(c, "depot") then
        push("4.g.bahnhof")
      elseif model.has_role(c, "signal") then
        push("4.g.signale")
      else
        push("4.g.ausgang")
      end
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

  screens["5.test"] = {
    render = function(v, rect)
      header(v, rect, nil, "Pruefungen laufen automatisch; was nicht sicher ist, wartet auf Sie.")
      local items = {}
      session.pick.tests = {}
      for _, test in ipairs(session.wiz.tests()) do
        local state, text = session.wiz.test_state(test.id)
        local kind = (state == "ok") and "ok" or (state == "fehler") and "halt" or "wait"
        local waiting = session.wiz.auto_waiting and session.wiz.auto_waiting[test.id]
        local detail = state .. (test.kind == "schalten" and " (schaltet)" or "") .. (text and state == "fehler" and (": " .. text) or "")
        if state == "offen" and waiting then detail = "wartet: " .. waiting end
        items[#items + 1] = { text = test.title, detail = detail, kind = kind }
        session.pick.tests[#items] = test
      end
      W.list(v, "tests", body_rect(rect, 3), items, list_state(v, "tests"), { empty = "Keine Pruefungen noetig." })
      -- die Auswahl nennt den Grund, wenn eine schaltende Pruefung auf die Bestaetigung wartet
      local picked = session.pick.tests[list_state(v, "tests").index]
      local why = picked and session.wiz.auto_waiting and session.wiz.auto_waiting[picked.id]
      if why and session.wiz.test_state(picked.id) == "offen" then v.hint = "Wartet auf Bestaetigung: " .. why .. ". Ausfuehren schaltet erst nach der Vorbereitung." end
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
      elseif id == "act:alle_pruefen" then
        local ran, passed, waiting = session.wiz.auto_tests(false)
        v.hint = ran .. " Pruefung(en) ausgefuehrt, " .. passed .. " bestanden" .. (waiting > 0 and (", " .. waiting .. " warten auf Bestaetigung") or "") .. "."
        return true
      end
    end,
    actions = function(v)
      local selected = session.pick.tests and session.pick.tests[list_state(v, "tests").index]
      return {
        { id = "ausfuehren", label = "Ausfuehren", enabled = selected ~= nil, reason = "Erst eine Pruefung waehlen." },
        { id = "alle_pruefen", label = "Neu pruefen", kind = "secondary" },
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
      for _, tid in ipairs(w.tracks()) do
        local t = c.tracks[tid]
        if t.release then lines[#lines + 1] = "Freigabe " .. t.name .. ": " .. (t.release.relay or "Computer") .. " " .. t.release.side end
      end
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
        session.wiz.rescan()
        session.wiz.auto_tests(true)                  -- offene Pruefungen laufen vor dem Aktivieren von selbst
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

  -- Automatisch einrichten (freiwillig, ab Schritt 2): Geraete waehlen, Gleise anlegen, Pruefungen laufen lassen und dorthin springen, wo noch etwas von Hand noetig ist
  function page.auto_setup(v)
    local w = session.wiz
    w.rescan()
    local added = w.select_suitable()
    local made, notes = w.auto_tracks()
    local function go(screen, hint)
      session.stack = {}
      goto_screen(screen)
      v.hint = hint
      return true
    end
    local ok3, why3 = w.step_ok(3, true)
    if not ok3 then return go("3.geraete", why3) end
    if model.has_role(w.config, "knoten") then return go("4.knoten", "Knotenpunkt: Anschluesse, Verbindungen und Gleise bitte von Hand einrichten.") end
    local extra = type(notes) == "table" and #notes > 0 and (" " .. table.concat(notes, "; ")) or ""
    if not made and model.profile(w.config).tracks and #w.tracks() == 0 then return go("4.gleise", tostring(notes)) end
    local ok4, why4 = w.step_ok(4, true)
    if not ok4 then return go("4.gleise", why4 .. extra) end
    local ran, passed, waiting = w.auto_tests(true)
    local ok5 = w.step_ok(5, true)
    if ok5 then return go("6.fertig", "Automatisch eingerichtet. Bitte ansehen, dann aktivieren." .. extra) end
    return go("5.test", ran .. " Pruefung(en) automatisch, " .. waiting .. " warten auf Bestaetigung oder sind fehlgeschlagen." .. extra)
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
    if not (def and def.hide_nav_buttons) then
      list[#list + 1] = { id = "zurueck", label = "Zurueck", kind = "secondary", side = "rechts" }
      if session.screen ~= "6.fertig" then
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

  -- fuer Tests und die Knotenlaufzeit
  function page.session() return session end

  return page
end

return M
