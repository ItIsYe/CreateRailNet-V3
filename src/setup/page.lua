--[[
Purpose: Seite "Einrichtung" der Oberflaeche: fuehrt den Assistenten (setup/wizard) in sechs Hauptschritten. Jeder Schritt besteht aus kleinen Bildschirmen (eine Liste oder ein bis zwei Felder), damit er auch auf der kompakten Flaeche (51x19) passt. Ablauf: Anlage, Rolle, Geraete, Gleise, Test, Fertig. Es bearbeitet immer nur eine Ansicht die Einrichtung; andere zeigen "Einrichtung wird bearbeitet" (Konzept 28.4).
API: setup_page.new(services) -> Seite fuer ui/view; services = { scan(), env, now, store, config_path, config() -> aktuelle Konfiguration oder nil, on_saved(config), notify(level, text) }
Notes: Technische Anschlussnamen sind hier sichtbar (Schritt 3 und 4), im Betrieb ersetzen Gleisnamen sie. Schaltende Pruefungen verlangen eine Bestaetigung auf einem eigenen Bildschirm, der Geraet, erwartete Wirkung und den noetigen Ausgangszustand nennt. Mit "Abbrechen" (zweimal) werden die Eingaben verworfen; die gespeicherte Einrichtung bleibt unveraendert.
]]

local wizardlib = require("setup.wizard")
local model = require("setup.model")
local detect = require("dev.detect")
local label = require("core.label")
local W = require("ui.widgets")

local M = {}

local DIRECTIONS = { { id = "hin", text = "hin (eine Richtung)" }, { id = "rueck", text = "rueck (Gegenrichtung)" }, { id = "beide", text = "beide Richtungen" } }

function M.new(services)
  local page = { id = "einrichtung", title = "Einrichtung" }

  -- gemeinsamer Zustand aller Ansichten: wer bearbeitet gerade?
  local session = { owner = nil, wiz = nil, screen = nil, stack = {}, track = nil, cancel_armed = false, test_pending = nil, pick = {}, dir = {} }

  -- Titel der Bildschirme der Einrichtung
  local GUIDED_TITLE = {
    ["1.modus"] = "Netz erstellen oder beitreten", ["1.netzwahl"] = "Netz waehlen", ["1.netz"] = "Name des Netzes", ["1.zentrale"] = "Kennung der Leitstelle",
    ["2.rollen"] = "Rolle waehlen", ["2.name"] = "Name der Node", ["2.kennung"] = "Kennung anfordern",
    ["2.station"] = "Betriebsstelle waehlen",
    ["3.geraete"] = "Geraete waehlen",
    ["4.gleise"] = "Gleise einrichten", ["4.g.name"] = "Name des Gleises", ["4.g.richtung"] = "Richtung",
    ["4.g.bahnhof"] = "Bahnhof zuordnen", ["4.g.beobachter"] = "Beobachter zuordnen",
    ["4.anmeldung"] = "Anmeldestation",
    ["5.test"] = "Pruefungen", ["5.alle_bestaetigen"] = "Pruefungen bestaetigen", ["5.bestaetigen"] = "Pruefung bestaetigen",
    ["6.fertig"] = "Zusammenfassung",
  }

  local first_device_screen                       -- weiter unten bei den Gleisbildschirmen

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

  -- Bahnhof und Depot holen Kennung, Name und Label von der Leitstelle; Geraete, Gleise und Pruefungen richtet der Assistent ein
  -- Rollen, die sich auf einem Computer kombinieren lassen (Bahnhof, Depot, dazu die Anmeldung)
  local STATION_ROLES = { passagierbahnhof = true, gueterbahnhof = true, depot = true }
  local CLAIM_ROLES = { passagierbahnhof = true, gueterbahnhof = true, depot = true, anmeldung = true }
  local function roles_in(allowed, need_one_of)
    local w = session.wiz
    if not w or #w.roles == 0 then return false end
    local found = false
    for _, r in ipairs(w.roles) do
      if not allowed[r] then return false end
      if need_one_of[r] then found = true end
    end
    return found
  end
  local function station_mode()
    local w = session.wiz
    return w ~= nil and w.mode == "join" and not session.manual and services.directory_claim ~= nil
      and roles_in(CLAIM_ROLES, { passagierbahnhof = true, gueterbahnhof = true, depot = true })
  end
  -- Anmeldung allein: gehoert zu einer Betriebsstelle des Netzes
  local function anmeldung_mode()
    local w = session.wiz
    return w ~= nil and w.mode == "join" and #w.roles == 1 and w.roles[1] == "anmeldung" and not session.manual and services.directory_stations ~= nil
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
    if station_mode() then
      for _, id in ipairs({ "2.kennung", "3.geraete", "4.gleise" }) do seq[#seq + 1] = id end
      for _, r in ipairs(session.wiz.roles) do if r == "anmeldung" then seq[#seq + 1] = "4.anmeldung" break end end
      seq[#seq + 1] = "5.test"; seq[#seq + 1] = "6.fertig"
      return seq
    end
    if anmeldung_mode() then
      for _, id in ipairs({ "2.station", "3.geraete", "4.anmeldung", "5.test", "6.fertig" }) do seq[#seq + 1] = id end
      return seq
    end
    seq[#seq + 1] = "2.name"
    seq[#seq + 1] = "3.geraete"
    local c = session.wiz.config
    if model.has_role(c, "passagierbahnhof") or model.has_role(c, "gueterbahnhof") or model.has_role(c, "depot") then
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
    if screen == "5.test" then
      for _, test in ipairs(session.wiz.tests()) do
        if test.kind == "lesen" and session.wiz.test_state(test.id, nil, test) ~= "ok" then session.wiz.run_test(test.id, false) end
      end
    end
    if screen == "1.netzwahl" then
      -- Eine vorhandene Einrichtung behaelt ihr Netz als Auswahl und sucht nicht neu
      session.net_choice = session.current_net
      if not session.current_net then services.search_networks() end
    elseif screen == "2.station" then
      session.dir = session.dir or {}
      if not session.dir.stations then
        session.dir.want = "stations"
        services.directory_stations(session.wiz.central_id)
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
    session.current_net = nil
    -- Eine schon eingerichtete Node gehoert zu einem Netz: das ist die Vorauswahl (kein Suchen, sonst kaeme sie nicht weiter)
    if existing and existing.network and type(existing.network.central_id) == "string" and existing.network.central_id ~= "" and type(existing.network.name) == "string" and existing.network.name ~= "" then
      session.current_net = { netz = existing.network.name, zentrale = existing.network.central_id }
      session.net_choice = session.current_net
    end
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

  -- subtitle: eine Zeile; lines = 2 nur auf Seiten, deren Inhalt erst ab Zeile 3 beginnt (Listen): dort wird umgebrochen statt abgeschnitten
  local function header(v, rect, title, subtitle, lines)
    local w = session.wiz
    -- kompakt steht der Schritt in der Leiste darueber; auf dem grossen Monitor nennt die Ueberschrift ihn
    local heading = GUIDED_TITLE[session.screen] or wizardlib.STEPS[w.step]
    if v.layout.mode == "gross" then heading = string.format("Schritt %d von %d: %s", w.step, #wizardlib.STEPS, heading) end
    W.label(v, rect.x + 1, rect.y, heading, "hell", rect.w - 2)
    if subtitle then
      local parts, max = W.wrap(subtitle, rect.w - 2), lines or 1
      for i = 1, math.min(#parts, max) do
        local text = parts[i]
        if i == max and #parts > max then text = W.fit(table.concat(parts, " ", i), rect.w - 2) end
        W.label(v, rect.x + 1, rect.y + i, text, "dim", rect.w - 2)
      end
    end
  end

  -- Statustext (zum Beispiel "Die Leitstelle antwortet nicht ...") umgebrochen auf hoechstens max Zeilen ab y: die Meldung ist oft der wichtigste Text des Bildschirms
  local function put_status(v, rect, y, st, max)
    for i, line in ipairs(W.wrap(st.text or "", rect.w - 2)) do
      if i > (max or 2) then break end
      W.label(v, rect.x + 1, y + i - 1, line, st.kind or "dim", rect.w - 2)
    end
  end

  local function body_rect(rect, top)
    return { x = rect.x, y = rect.y + top, w = rect.w, h = rect.h - top }
  end

  -- Zeilenhoehe einer Liste: Titel und Einzelheit stehen auf einer Zeile, wenn beides hineinpasst, sonst auf zwei (nichts wird abgeschnitten)
  local function row_h_for(v, items, rect)
    if v.layout.mode == "gross" then return 3 end
    for _, item in ipairs(items) do
      if item.detail and #item.text + #item.detail + 4 > rect.w - 2 then return 2 end
    end
    return 1
  end

  local function device_items(kinds, selected_only)
    local items, map = {}, {}
    for _, d in ipairs(session.wiz.scan) do
      if kinds[d.kind] then
        local chosen = session.wiz.device_selected(d.name)
        local missing = {}
        if d.kind == "station" or d.kind == "observer" then missing = detect.missing(d.kind, d) end
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
      header(v, rect, nil, "Was soll dieser Computer tun?")
      local items = {}
      session.pick.modes = {}
      if not services.role_available or services.role_available("zentrale") then
        items[#items+1] = { text = (session.wiz.mode == "create" and "(o) " or "( ) ") .. "Erste Leitstelle dieses Netzes erstellen" }
        session.pick.modes[#items] = "create"
      end
      -- Beitreten braucht eine andere Rolle als die Leitstelle; ist nur sie installiert, gibt es nur das Erstellen
      local other = not services.role_available
      for _, role in ipairs(model.ROLES) do if role ~= "zentrale" and services.role_available and services.role_available(role) then other = true end end
      if other then
        items[#items+1] = { text = (session.wiz.mode == "join" and "(o) " or "( ) ") .. "Diesem bestehenden Netz beitreten" }
        session.pick.modes[#items] = "join"
      end
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
      if session.current_net then st = { kind = "ok", text = "Dieser Computer gehoert schon zu diesem Netz.", networks = { session.current_net } } end
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
    actions = function(v)
      if session.current_net then return {} end
      return { { id = "neu_suchen", label = "Neu suchen", kind = "secondary" } }
    end,
  }

  screens["1.netz"] = {
    render = function(v, rect)
      header(v, rect, nil, "Wie heisst das Netz?")
      W.label(v, rect.x + 1, rect.y + 2, W.fit("Buchstaben, Ziffern, Leerzeichen, - und _", rect.w - 2), "dim", rect.w - 2)
      local f = fields(v)
      W.field(v, "netz", rect.x + 1, rect.y + 3, math.min(rect.w - 2, 36), "Netzname", f.netz)
      W.field(v, "schluessel", rect.x + 1, rect.y + 6, math.min(rect.w - 2, 36), "Netzwerkschluessel (freiwillig)", f.schluessel)
      if rect.h > 11 then
        for i, line in ipairs(W.wrap("Der Schluessel haelt nur Versehen fern, er ist keine Verschluesselung.", rect.w - 2)) do
          if i <= 2 then W.label(v, rect.x + 1, rect.y + 8 + i, line, "dim", rect.w - 2) end
        end
      end
    end,
  }

  screens["1.zentrale"] = {
    render = function(v, rect)
      header(v, rect, nil, "Welche Leitstelle fuehrt dieses Netz?")
      W.field(v, "zentrale", rect.x + 1, rect.y + 3, math.min(rect.w - 2, 36), "Kennung der Leitstelle (z.B. hauptstelle)", fields(v).zentrale)
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
      header(v, rect, nil, "Wie soll dieser Node heissen? (z.B. Westbahnhof)")
      local f = fields(v)
      if f.name.value == "" then f.name.value = session.wiz.suggest_name() end
      W.field(v, "name", rect.x + 1, rect.y + 3, math.min(rect.w - 2, 36), "Name", f.name)
      local c = session.wiz.config
      W.label(v, rect.x + 1, rect.y + 6, "Kennung im Netz: " .. model.slug(c.node.name), "dim", rect.w - 2)
      W.label(v, rect.x + 1, rect.y + 7, "Der Name ist nur Anzeige und laesst sich leeren.", "dim", rect.w - 2)
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
      local area = body_rect(rect, 3)
      W.list(v, "geraete", area, items, list_state(v, "geraete"), { row_h = row_h_for(v, items, area), empty = "Keine passenden Geraete gefunden." })
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
      header(v, rect, nil, "Gleis waehlen und die Geraete dazu zuordnen.")
      local items = {}
      session.pick.tracks = {}
      for _, id in ipairs(session.wiz.tracks()) do
        local t = session.wiz.config.tracks[id]
        local parts = {}
        if t.station then parts[#parts + 1] = "Bahnhof" end
        if #t.observers > 0 then parts[#parts + 1] = #t.observers .. " Beobachter" end
        items[#items + 1] = { text = t.name, detail = #parts > 0 and table.concat(parts, ", ") or "noch leer", kind = #parts > 0 and "ok" or "wait" }
        session.pick.tracks[#items] = id
      end
      local area = body_rect(rect, 3)
      W.list(v, "gleise", area, items, list_state(v, "gleise"), { row_h = row_h_for(v, items, area), empty = "Noch kein Gleis. 'Neu' legt eines an." })
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
        v.hint = "Kopie: Geraete neu zuordnen."
        return true
      elseif id == "act:entfernen" and selected then
        session.wiz.remove_track(selected)
        return true
      end
    end,
    actions = function(v)
      local has_selection = session.pick.tracks and session.pick.tracks[list_state(v, "gleise").index] ~= nil
      local reason = "Erst ein Gleis in der Liste waehlen."
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
      header(v, rect, nil, "Bearbeiten: " .. (t and label.track(t.name) or "?"))
      W.field(v, "gleisname", rect.x + 1, rect.y + 3, math.min(rect.w - 2, 36), "Gleisname", fields(v).gleisname)
      if t then
        W.label(v, rect.x + 1, rect.y + 6, "Richtung: " .. t.direction, "dim", rect.w - 2)
        W.label(v, rect.x + 1, rect.y + 7, "Weiter fuehrt durch die Einstellungen.", "dim", rect.w - 2)
      end
    end,
    next = function(v)
      session.wiz.rename_track(session.track, fields(v).gleisname.value)
      push("4.g.richtung")
      return true
    end,
  }

  -- erster rollenabhaengiger Bildschirm eines Gleises (nach Name und Richtung)
  function first_device_screen()
    return "4.g.bahnhof"
  end

  screens["4.g.richtung"] = {
    render = function(v, rect)
      local t = session.wiz.config.tracks[session.track]
      header(v, rect, nil, "In welche Richtung wird " .. label.track(t.name) .. " befahren?", 2)
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

  local function device_choice_screen(id, kind, field, subtitle, single)
    return {
      render = function(v, rect)
        local t = session.wiz.config.tracks[session.track]
        header(v, rect, nil, subtitle .. " " .. label.track(t.name), 2)
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

  screens["4.g.bahnhof"] = device_choice_screen("bahnhof", "station", "station", "Welcher Create-Bahnhof gehoert zu", true)
  screens["4.g.bahnhof"].next = function(v)
    if #config_devices_of("observer") > 0 then push("4.g.beobachter")
    else while session.screen ~= "4.gleise" and pop() do end end
    return true
  end
  screens["4.g.beobachter"] = device_choice_screen("beobachter", "observer", "observers", "Welche Beobachter gehoeren zu")
  screens["4.g.beobachter"].next = function(v)
    while session.screen ~= "4.gleise" and pop() do end
    return true
  end

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
      header(v, rect, nil, "Lesen sofort, Schalten erst nach Bestaetigung.")
      local items = {}
      session.pick.tests = {}
      for _, test in ipairs(session.wiz.tests()) do
        local state, text = session.wiz.test_state(test.id)
        local kind = (state == "ok") and "ok" or (state == "fehler") and "halt" or "wait"
        items[#items + 1] = { text = test.title, detail = state .. (test.kind == "schalten" and " (schaltet)" or "") .. (text and state == "fehler" and (": " .. text) or ""), kind = kind }
        session.pick.tests[#items] = test
      end
      local area = body_rect(rect, 3)
      W.list(v, "tests", area, items, list_state(v, "tests"), { row_h = row_h_for(v, items, area), empty = "Keine Pruefungen noetig." })
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

  local function dir_status() return services.directory_status and services.directory_status() or nil end
  -- Anforderung dieses Computers im Verzeichnis: immer dieselbe Kennung (Datei, kein Entwurf); eine einmalige Kennung fuer einzelne Vorgaenge
  local function node_claim() return services.claim and services.claim() or services.new_claim() end

  -- Betriebsstelle fuer die Anmeldung waehlen (Konzept 9.1): die Anmeldung gehoert zu einer Betriebsstelle und hat keine Gleise
  screens["2.station"] = {
    render = function(v, rect)
      header(v, rect, nil, "Bei welcher Betriebsstelle melden sich Zuege an?")
      local d = session.dir
      local st = dir_status()
      if st and st.kind ~= "ok" then put_status(v, rect, rect.y + 2, st, 2) end
      local items = {}
      session.pick.stations = {}
      for _, s in ipairs(d.stations or {}) do
        local on = d.station_choice and d.station_choice.id == s.id
        items[#items + 1] = { text = (on and "(o) " or "( ) ") .. s.name, detail = s.kind }
        session.pick.stations[#items] = s
      end
      local empty = (st and st.kind == "ok" and d.stations) and "Das Netz hat noch keine Betriebsstelle. In der Leitstelle auf der Seite Betriebsstellen anlegen, dann 'Neu laden'." or ""
      local area = body_rect(rect, 4)
      W.list(v, "station_wahl", area, items, list_state(v, "station_wahl"), { row_h = row_h_for(v, items, area), empty = empty })
    end,
    action = function(v, id)
      local d = session.dir
      local n = id:match("^sel:station_wahl:(%d+)$")
      if n then
        local s = (session.pick.stations or {})[tonumber(n)]
        if s then d.station_choice = s end
        return true
      elseif id == "act:station_laden" then
        d.stations, d.station_choice, d.want = nil, nil, "stations"
        services.directory_stations(session.wiz.central_id)
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
        { id = "station_laden", label = "Neu laden", kind = "secondary" },
        { id = "von_hand", label = "Von Hand", kind = "secondary" },
      }
    end,
    -- die Kennung kommt von der Leitstelle; erst mit ihrer Antwort geht es weiter (page.poll)
    next = function(v)
      local d = session.dir
      if d.claiming then v.hint = "Frage die Leitstelle nach der Kennung ..." return true end
      d.claim = d.claim or node_claim()
      d.claiming = { station = d.station_choice }
      services.directory_reset()
      services.directory_claim(session.wiz.central_id, d.claim, "anmeldung", session.wiz.legacy_id(), { station = d.station_choice.id })
      v.hint = "Frage die Leitstelle nach der Kennung ..."
      return true
    end,
  }

  -- Kennung von der Leitstelle holen (Bahnhof, Depot): die Leitstelle vergibt Kennung, Namen und Label; die Strecke selbst regelt Create
  screens["2.kennung"] = {
    render = function(v, rect)
      header(v, rect, nil, "Die Leitstelle vergibt Kennung und Namen.")
      local d = session.dir
      local y = rect.y + 2
      local text = "Mit Weiter wird die Kennung angefordert (zum Beispiel N0003). Gleise und Geraete richtet der naechste Schritt ein; Signale und Weichen regelt Create."
      for i, part in ipairs(W.wrap(text, rect.w - 2)) do
        if i > 4 then break end
        W.label(v, rect.x + 1, y + i - 1, part, "text", rect.w - 2)
      end
      local st = dir_status()
      if st and (d.claiming or st.kind ~= "ok") then put_status(v, rect, y + 5, st, 2) end
    end,
    action = function(v, id)
      if id == "act:von_hand" then
        session.manual = true
        session.stack = {}
        goto_screen("2.name")
        return true
      end
    end,
    actions = function(v)
      return { { id = "von_hand", label = "Von Hand", kind = "secondary" } }
    end,
    -- die Kennung kommt von der Leitstelle; erst mit ihrer Antwort geht es weiter (page.poll)
    next = function(v)
      local d = session.dir
      if d.claiming then v.hint = "Frage die Leitstelle nach der Kennung ..." return true end
      d.claim = d.claim or node_claim()
      d.claiming = { roles = session.wiz.roles }
      services.directory_reset()
      services.directory_claim(session.wiz.central_id, d.claim, session.wiz.roles[1] or "passagierbahnhof", session.wiz.legacy_id(), { roles = session.wiz.roles })
      v.hint = "Frage die Leitstelle nach der Kennung ..."
      return true
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

  screens["6.fertig"] = {
    render = function(v, rect)
      header(v, rect, nil, nil)
      local w = session.wiz
      local c = w.config
      local roles = {}
      for _, r in ipairs(c.node.roles) do roles[#roles + 1] = model.ROLE_TEXT[r] end
      local lines = {
        "Netz: " .. c.network.name .. (c.network.central_id and ("   Leitstelle: " .. c.network.central_id) or "   (diese Node ist die Leitstelle)"),
        "Node: " .. ((c.node.name == "" or c.node.name:find(c.node.id, 1, true)) and (c.node.name ~= "" and c.node.name or c.node.id) or (c.node.name .. " (" .. c.node.id .. ")")),
        "Rolle: " .. table.concat(roles, ", "),
      }
      local tracks = #w.tracks()
      if tracks > 0 then lines[#lines + 1] = "Gleise: " .. tracks end
      local problems = w.warnings()
      local tests_ok = w.all_tests_ok()
      lines[#lines + 1] = "Pruefungen: " .. (tests_ok and "alle bestanden" or "offen")
      lines[#lines + 1] = (#problems == 0 and tests_ok) and "Bereit zum Aktivieren." or "Noch nicht bereit: Aktivieren geht erst nach allen Pruefungen."
      local y = rect.y + 2
      local function put(text, kind)
        for _, part in ipairs(W.wrap(text, rect.w - 2)) do
          if y <= rect.y + rect.h - 1 then W.label(v, rect.x + 1, y, part, kind, rect.w - 2) end
          y = y + 1
        end
      end
      for _, line in ipairs(lines) do put(line, (line:find("Noch nicht bereit", 1, true)) and "attention" or "text") end
      for _, p in ipairs(problems) do put("- " .. p.text, "wait") end
    end,
    action = function(v, id)
      if id == "act:speichern" then
        local ok, why = session.wiz.step_ok(5)       -- liest die Geraete vorher frisch
        if not ok then v.hint = why return true end
        local status, problems, err = session.wiz.finish(services.store, services.config_path)
        if not status then
          v.hint = "Aktivieren nicht moeglich: " .. tostring(err)
          return true
        end
        services.on_saved(session.wiz.config)
        services.notify("info", "Einrichtung aktiviert.")
        v.hint = "Aktiviert."
        session.wiz, session.owner = nil, nil
        return true
      end
    end,
    actions = function(v)
      local ok = session.wiz and #session.wiz.warnings() == 0 and session.wiz.all_tests_ok()
      return { { id = "speichern", label = "Aktivieren", enabled = ok, reason = "Pflichtangaben und Pruefungen muessen vollstaendig sein.", nav = true } }
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
      W.field(v, "r_central", rect.x + 1, rect.y + 1, math.min(rect.w - 2, 36), "Kennung der Leitstelle", f.central)
      local st = services.fetch_status and services.fetch_status()
      if session.replace_want then st = dir_status() or st end
      if session.replace_list then
        -- Auswahl aus den Nodes mit Sicherung (Konzept 11.4): die gewaehlte Kennung wird uebernommen
        local items = {}
        for i, b in ipairs(session.replace_list) do
          local on = f.node.value == b.id
          items[i] = { text = (on and "(o) " or "( ) ") .. b.id .. " " .. b.name, detail = b.state == "aktiv" and "NOCH AKTIV" or b.state, kind = b.state == "aktiv" and "dim" or "ok" }
        end
        if st then W.label(v, rect.x + 1, rect.y + 4, st.text, st.kind, rect.w - 2) end
        W.list(v, "r_wahl", { x = rect.x, y = rect.y + 5, w = rect.w, h = math.max(3, rect.h - 5) }, items, list_state(v, "r_wahl"), { empty = "Keine Node mit Sicherung gefunden." })
        return
      end
      W.field(v, "r_node", rect.x + 1, rect.y + 4, math.min(rect.w - 2, 36), "Kennung der zu ersetzenden Node", f.node)
      if st then W.label(v, rect.x + 1, rect.y + 8, st.text, st.kind, rect.w - 2) end
      return
    end
    if not session.wiz then
      W.label(v, rect.x + 1, rect.y, "Einrichtung", "hell")
      local config = services.config()
      local text = config
        and ("Dieser Node ist eingerichtet: " .. (config.node.name ~= "" and config.node.name or config.node.id) .. ". Die Einrichtung kann geaendert werden.")
        or "Dieser Computer ist noch nicht eingerichtet. Der Assistent fuehrt in sechs Schritten durch Netz, Aufgabe, Geraete, Gleise, Test und Fertig."
      for i, line in ipairs(W.wrap(text, rect.w - 2)) do W.label(v, rect.x + 1, rect.y + 1 + i, line, "text", rect.w - 2) end
      return
    end
    if session.owner ~= v then
      W.label(v, rect.x + 1, rect.y, "Einrichtung wird bearbeitet.", "attention")
      for i, line in ipairs(W.wrap("Eine andere Bedienoberflaeche fuehrt gerade den Assistenten.", rect.w - 2)) do W.label(v, rect.x + 1, rect.y + 1 + i, line, "text", rect.w - 2) end
      return
    end
    local def = screen_def()
    if v.layout.mode == "gross" then
      local S = require("ui.palette").SLOT
      local x = rect.x + rect.w - 26
      v.canvas.fill(x, rect.y, 26, rect.h, S.navigation)
      W.label(v, x + 2, rect.y + 1, "DEINE EINRICHTUNG", "hell", 22)
      local w = session.wiz
      local lines = { w.name ~= "" and w.name or "Name folgt", "Netz: " .. w.network_name }
      for _, role in ipairs(w.roles) do lines[#lines+1] = model.ROLE_TEXT[role] end
      lines[#lines+1] = ""
      lines[#lines+1] = "Schritt " .. w.step .. " von 6"
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
    if screen == "2.station" then
      local d = session.dir
      if not d.station_choice then return false, "Bitte eine Betriebsstelle waehlen." end
      if d.claiming then return false, "Frage die Leitstelle nach der Kennung ..." end
    end
    if screen == "2.kennung" and session.dir.claiming then return false, "Frage die Leitstelle nach der Kennung ..." end
    if screen == "2.name" then return w.step_ok(2, true) end
    if screen == "3.geraete" then return w.step_ok(3, true) end
    if screen == "4.g.name" and not fields(v).gleisname.value:match("%S") then return false, "Der Gleisname fehlt." end
    if track then
      if screen == "4.g.bahnhof" and not track.station then return false, "Bitte eine Train Station zuordnen." end
    end
    if screen == "4.gleise" then return w.step_ok(4, true, { anmeldung_station = true }) end
    if screen == "4.anmeldung" then return w.step_ok(4, true) end
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
    for i, name in ipairs(wizardlib.STEPS) do
      local active = session.wiz.step == i
      items[i] = { title = i .. "  " .. name, num = tostring(i), name = name, active = active, done = i < session.wiz.step }
    end
    return items
  end

  function page.actions(v)
    if session.replace and not session.wiz then
      local st = services.fetch_status and services.fetch_status()
      return {
        { id = "r_liste", label = session.replace_list and "Eingeben" or "Liste", kind = "secondary" },
        { id = "r_holen", label = "Holen" },
        { id = "r_uebernehmen", label = "Uebernehmen", enabled = st ~= nil and st.config ~= nil, reason = "Erst die Konfiguration holen." },
        { id = "r_abbruch", label = "Abbrechen", kind = "danger", side = "rechts", far = true },
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
    local list, main = {}, {}
    if def and def.actions then
      for _, a in ipairs(def.actions(v)) do
        if a.nav then main[#main + 1] = a else list[#list + 1] = a end
      end
    end
    local hide = def and ((type(def.hide_nav_buttons) == "function" and def.hide_nav_buttons(v)) or def.hide_nav_buttons == true)
    if hide then
      for _, a in ipairs(main) do list[#list + 1] = a end
    else
      list[#list + 1] = { id = "zurueck", label = "Zurueck", kind = "secondary", side = "rechts", nav = true }
      for _, a in ipairs(main) do list[#list + 1] = a end
      if session.screen ~= "6.fertig" and not (def and def.no_forward) then
        local ok, why = can_advance(v)
        list[#list + 1] = { id = "weiter", label = "Weiter", side = "rechts", enabled = ok, reason = why, nav = true }
      end
    end
    list[#list + 1] = { id = "abbrechen", label = session.cancel_armed and "Wirklich?" or "Abbrechen", kind = "danger", side = "rechts", nav = true, far = true }
    return list
  end

  local function advance(v)
    local def = screen_def()
    commit(v)
    local allowed, reason = can_advance(v)
    if not allowed then v.hint = reason return true end
    -- "Erste Leitstelle erstellen" ist vorgewaehlt: die Rolle Leitstelle gehoert dazu, auch wenn die Wahl nicht angetippt wurde
    if session.screen == "1.modus" and session.wiz.mode == "create" then session.wiz.set_mode("create") end
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
      local pick = id:match("^sel:r_wahl:(%d+)$")
      if pick then
        local b = (session.replace_list or {})[tonumber(pick)]
        if b then f.node.value = b.id end
        return true
      elseif id == "act:r_liste" then
        if session.replace_list then
          session.replace_list, session.replace_want = nil, nil
        elseif f.central.value == "" then
          v.hint = "Erst die Kennung der Leitstelle eingeben."
        elseif services.directory_backups then
          session.replace_want = true
          services.directory_reset()
          services.directory_backups(f.central.value)
        end
        return true
      elseif id == "act:r_holen" then
        if f.central.value == "" or f.node.value == "" then v.hint = "Beide Kennungen sind noetig." return true end
        session.replace_want = nil
        services.fetch_config(f.central.value, f.node.value)
        return true
      elseif id == "act:r_uebernehmen" then
        local st = services.fetch_status and services.fetch_status()
        if st and st.config then
          session.replace, session.replace_list, session.replace_want = nil, nil, nil
          start(v, st.config)
          goto_screen("6.fertig")
          v.hint = "Konfiguration uebernommen: Geraete pruefen, dann speichern."
        end
        return true
      elseif id == "act:r_abbruch" then
        session.replace, session.replace_list, session.replace_want = nil, nil, nil
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
    if id == "act:weiter" then return advance(v) end
    if id == "act:zurueck" or id == "back" then
      commit(v)
      return retreat(v)
    end
    if id == "act:abbrechen" then
      if session.cancel_armed then
        session.wiz, session.owner, session.stack = nil, nil, {}
        v.hint = services.config() and "Verworfen; die laufende Einrichtung bleibt." or "Verworfen. Die Einrichtung kann neu begonnen werden."
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
    if session.replace and not session.wiz then
      local st = session.replace_want and dir_status()
      if st and st.kind == "ok" and st.backups then session.replace_list, session.replace_want = st.backups, nil end
      return
    end
    local v = session.owner
    if not session.wiz or not v then return end
    local d = session.dir
    local st = dir_status()
    if not st then return end
    if st.kind == "ok" then
      if st.stations and d.want == "stations" then d.stations, d.want = st.stations, nil end
      if st.node and d.claiming then
        local claiming = d.claiming
        d.claiming = nil
        local role = session.wiz.roles[1]
        if #session.wiz.roles == 1 and role == "anmeldung" then
          session.wiz.anmeldung_begin({ station = claiming.station, claim = d.claim, node = st.node })
          v.hint = "Kennung " .. st.node.id .. " von der Leitstelle."
          push("3.geraete")
          return
        end
        local began, why_begin = session.wiz.guided_begin({ claim = d.claim, node = st.node, roles = session.wiz.roles })
        if not began then v.hint = why_begin return end
        v.hint = "Kennung " .. st.node.id .. " von der Leitstelle."
        push("3.geraete")
      end
    elseif st.kind == "halt" and d.claiming then
      d.claiming = nil
      v.hint = st.text
      -- die Leitstelle hat die bisherige Anforderung dieses Computers verworfen: mit einer neuen Kennung kann es weitergehen
      if tostring(st.text):find("verworfen", 1, true) and services.new_claim then
        d.claim = services.new_claim()
        v.hint = "Anforderung war verworfen, neue gestellt: bitte Weiter."
      end
    end
  end

  -- Sekundentakt: Antworten der Leitstelle abholen
  function page.tick()
    if not session.wiz or not session.owner then return end
    page.poll()
  end

  -- fuer Tests und die Knotenlaufzeit
  function page.session() return session end

  return page
end

return M
