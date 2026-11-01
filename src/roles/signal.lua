--[[
Purpose: Signal- und Strecken-Node (Konzept 4.5, 14.3, 20.1): verwaltet beliebig viele Signale mit ihren Gleisen. Die zusaetzliche Rotsperre (setForcedRed) gehoert immer einem oder mehreren Besitzern (Knoten, Bediener, Leitstelle); physisch gesperrt bleibt ein Signal, solange mindestens ein Besitzer die Sperre haelt. Aufheben heisst nur, die eigene Sperre zu entfernen, nie "gruen" (die nativen Rotursachen bleiben). Zustand und Sperre werden getrennt gemeldet.
API: signal_role.new(node) -> role; role.signals; role.lock(id, besitzer, grund) -> ok, fehler; role.unlock(id, besitzer) -> ok, fehler; role.states() -> Liste; role.on_event(ev); role.on_message(m, status); role.tick(); role.recover(); role.pages
Notes: Nur eine bestaetigte Sperre (isForcedRed nach dem Setzen) gilt als gesetzt (M08). Nach einem Neustart wird nie pauschal alles freigegeben: eigene gespeicherte Sperren werden bei Abweichung erneut gesetzt, eine unbekannte physische Sperre wird nur gemeldet (fremde Sperre) und erst nach Bedienerentscheidung aufgehoben. Ein Signal im Zustand INVALID macht seinen Bereich "gestoert". Ein Computerstillstand hebt eine gesetzte Sperre nicht auf, ein Programmabsturz laesst sie stehen: die Wirkung ist je Verdrahtung zu pruefen (14.3).
]]

local signallib = require("dev.signal")
local ser = require("core.ser")
local W = require("ui.widgets")

local M = {}

local HEARTBEAT = 5
local HELLO_REPEAT = 10      -- bis die Leitstelle antwortet, alle 10 s; danach alle 120 s
local LOCK_FILE = "/crn_data/sperren.lua"

function M.new(node)
  local role = { signals = {} }
  local config = node.config
  local env = node.env
  local now = function() return node.clock.now() end
  local persisted = node.store.load(LOCK_FILE) or { locks = {} }
  persisted.locks = persisted.locks or {}
  local last_beat, last_hello, hello_acked = -9999, -9999, false
  local dirty = true
  local confirm = {}
  local started_at = now()

  local SYNC_FIRST, SYNC_EVERY, SYNC_WAIT = 20, 600, 15
  local sync = { next_at = SYNC_FIRST, req = nil, state = "offen", diffs = {}, note = nil, t = nil }
  role.sync = sync
  local on_sync_reply                                   -- weiter unten beim Abgleich mit dem Netzverzeichnis

  local function save() return node.store.save(LOCK_FILE, persisted) end
  local function central() return node.central_id() end

  -- Signale aus der Konfiguration -----------------------------------------------------------------------------------------------------
  local track_ids = {}
  for id in pairs(config.tracks) do track_ids[#track_ids + 1] = id end
  table.sort(track_ids)
  for _, tid in ipairs(track_ids) do
    local spec = config.tracks[tid]
    for _, did in ipairs(spec.signals or {}) do
      if config.devices[did] then
        local info = config.devices[did].signal or {}
        local sg = { id = did, track = tid, track_name = spec.name, device = config.devices[did].device, last = {}, use = info.use, effect = info.effect, place = info.place }
        sg.dev = signallib.new(env, sg.device)
        role.signals[did] = sg
        role.signals[#role.signals + 1] = sg
      end
    end
  end

  local function owners_of(id)
    local entry = persisted.locks[id]
    local out = {}
    if entry then for owner in pairs(entry.owners) do out[#out + 1] = owner end end
    table.sort(out)
    return out
  end

  local function desired(id) return #owners_of(id) > 0 end

  -- Lesen ----------------------------------------------------------------------------------------------------------------------------------
  local function read(sg)
    local st = sg.dev.read()
    local view = {
      id = sg.id, track = sg.track, track_name = sg.track_name, available = st.available == true, state = st.state, forced = st.forced,
      blocking = st.blocking, owners = owners_of(sg.id), invalid = st.state == "INVALID" or nil,
    }
    -- eine physische Sperre ohne bekannten Besitzer ist eine fremde Sperre: nicht aufheben, nur zeigen
    if view.available and view.forced == true and #view.owners == 0 then view.foreign = true end
    if view.available and view.forced == false and #view.owners > 0 then view.missing = true end
    return view
  end

  function role.states()
    local out = {}
    for _, sg in ipairs(role.signals) do out[#out + 1] = read(sg) end
    return out
  end

  -- Sperren ----------------------------------------------------------------------------------------------------------------------------
  function role.lock(id, owner, reason)
    local sg = role.signals[id]
    if not sg then return nil, "Signal unbekannt" end
    local entry = persisted.locks[id] or { owners = {} }
    local had = entry.owners[owner]
    entry.owners[owner] = { reason = reason, t = now() }
    persisted.locks[id] = entry
    local ok, err = save()
    if not ok then
      entry.owners[owner] = had
      return nil, err
    end
    local jid = node.journal.begin("sperre.setzen", { signal = id, owner = owner, reason = reason })
    local result = sg.dev.hold()
    node.journal.finish(jid, { confirmed = result.confirmed, error = result.error })
    dirty = true
    if not result.confirmed then
      return nil, "Die Sperre wurde nicht bestaetigt" .. (result.error and (": " .. result.error) or ".")
    end
    return true
  end

  function role.unlock(id, owner)
    local sg = role.signals[id]
    if not sg then return nil, "Signal unbekannt" end
    local entry = persisted.locks[id]
    if not entry or not entry.owners[owner] then return true end          -- schon aufgehoben: wiederholbar
    entry.owners[owner] = nil
    local remaining = #owners_of(id)
    if remaining == 0 then persisted.locks[id] = nil end
    local ok, err = save()
    if not ok then
      persisted.locks[id] = persisted.locks[id] or entry
      entry.owners[owner] = { reason = "wiederhergestellt", t = now() }
      return nil, err
    end
    dirty = true
    if remaining > 0 then return true end                                   -- andere Besitzer halten das Signal weiter
    local jid = node.journal.begin("sperre.loesen", { signal = id, owner = owner })
    local result = sg.dev.release()
    node.journal.finish(jid, { confirmed = result.confirmed, error = result.error })
    if not result.confirmed then return nil, "Das Aufheben wurde nicht bestaetigt" .. (result.error and (": " .. result.error) or ".") end
    return true
  end

  -- eine unbekannte physische Sperre aufheben (nur auf ausdrueckliche Entscheidung des Bedieners)
  function role.release_foreign(id)
    local sg = role.signals[id]
    if not sg then return nil, "Signal unbekannt" end
    if desired(id) then return nil, "Das Signal hat eigene Besitzer der Sperre." end
    local jid = node.journal.begin("sperre.fremd_loesen", { signal = id })
    local result = sg.dev.release()
    node.journal.finish(jid, { confirmed = result.confirmed })
    dirty = true
    return result.confirmed or nil, not result.confirmed and "Das Aufheben wurde nicht bestaetigt." or nil
  end

  -- Berichte -------------------------------------------------------------------------------------------------------------------------------
  local function send_state()
    local list = role.states()
    node.send_to(central(), "meldung", { kind = "signale", node = config.node.id, signals = list, t = now() })
    last_beat, dirty = now(), false
  end

  function role.hello()
    local list = {}
    for _, sg in ipairs(role.signals) do list[#list + 1] = { id = sg.id, track = sg.track_name, device = sg.device, use = sg.use, effect = sg.effect, place = sg.place } end
    node.send_to(central(), "meldung", {
      kind = "hallo_signale", node = config.node.id, name = config.node.name, roles = config.node.roles, revision = config.revision,
      signals = list, active = config.status == "aktiv",
    })
    last_hello = now()
  end

  function role.on_event(ev)
    if ev.kind == "signal" and role.signals[ev.id] then dirty = true end
  end

  function role.on_message(m, status)
    if status ~= "ok" then return end
    if m.messageType == "bestaetigung" and m.payload.kind == "antwort" and m.payload.antwort_auf == "hallo_signale" then
      hello_acked = true
      return
    end
    if m.messageType == "bestaetigung" and m.payload.kind == "antwort" and m.payload.antwort_auf == "verzeichnis_gleise" then
      if sync.req and m.correlationId == sync.req and sync.state == "frage" then sync.req = nil; on_sync_reply(m.payload) end
      return
    end
    if m.messageType ~= "auftrag" or m.payload.kind ~= "sperre" then return end
    local p = m.payload
    if not role.signals[p.signal] then return node.reply(m, "abgelehnt", { grund = "Signal unbekannt" }) end
    local ok, err
    if p.action == "setzen" then ok, err = role.lock(p.signal, p.owner or "leitstelle", p.reason)
    elseif p.action == "loesen" then ok, err = role.unlock(p.signal, p.owner or "leitstelle")
    else return node.reply(m, "abgelehnt", { grund = "Unbekannte Aktion" }) end
    node.reply(m, ok and "ok" or "abgelehnt", { signal = p.signal, grund = err, owners = owners_of(p.signal) })
  end

  -- Abgleich mit dem Netzverzeichnis (Konzept 15): Namen und Richtungen der Gleise werden regelmaessig mit der Leitstelle verglichen. Eine Abweichung wird
  -- angezeigt und nur auf Wunsch uebernommen; ist die Leitstelle nicht erreichbar, bleibt die lokale Konfiguration unveraendert.

  local function claimed_area() return config.node.claimed and config.node.area or nil end

  function role.sync_request()
    if not claimed_area() then return nil, "Diese Node ist nicht ueber das Netzverzeichnis eingerichtet." end
    if sync.state == "frage" and now() - (sync.asked or 0) < SYNC_WAIT then return nil, "Die Frage laeuft noch." end
    local m = node.send_to(central(), "abfrage", { kind = "verzeichnis_gleise", area = claimed_area() })
    sync.req, sync.state, sync.asked = m and m.messageId or nil, "frage", now()
    sync.next_at = now() + SYNC_EVERY
    return true
  end

  local function valid_id(v) return type(v) == "string" and v:match("^A%d%d%d%d+$") ~= nil and #v <= 12 end
  local function valid_name(v) return type(v) == "string" and #v > 0 and #v <= 30 and v:match("^[%w _%-]+$") ~= nil end

  local function compare(area)
    local theirs = {}
    for _, t in ipairs(area.tracks) do theirs[t.id] = t end
    local diffs = {}
    for tid, track in pairs(config.tracks) do
      if track.dir then
        local c = theirs[track.dir.id]
        if not c then
          diffs[#diffs + 1] = { track = tid, id = track.dir.id, kind = "fehlt", name = track.name }
        else
          if c.name ~= track.name then diffs[#diffs + 1] = { track = tid, id = track.dir.id, kind = "name", from = track.name, to = c.name } end
          if c.direction ~= track.dir.direction then diffs[#diffs + 1] = { track = tid, id = track.dir.id, kind = "richtung", name = track.name, from = track.dir.direction, to = c.direction, rev = c.rev } end
          if c.name == track.name and c.direction == track.dir.direction and (c.rev or 0) ~= (track.dir.rev or 0) then
            track.dir.rev = c.rev                                   -- gleicher Inhalt, nur der Stand ist weiter: nachziehen
          end
        end
      end
    end
    table.sort(diffs, function(a, b) if a.id ~= b.id then return a.id < b.id end return a.kind < b.kind end)
    return diffs
  end

  local function describe(d)
    if d.kind == "fehlt" then return "Gleis " .. d.name .. " fehlt im Verzeichnis" end
    if d.kind == "name" then return "Gleis " .. d.from .. " heisst jetzt " .. d.to end
    return "Gleis " .. d.name .. ": Richtung " .. tostring(d.from) .. " -> " .. tostring(d.to)
  end
  role.describe_difference = describe

  function on_sync_reply(p)
    sync.t = now()
    if p.status ~= "ok" then sync.state, sync.note = "abgelehnt", tostring(type(p.grund) == "string" and p.grund:sub(1, 80) or "") return end
    local a = p.area
    local shape = type(a) == "table" and type(a.tracks) == "table" and #a.tracks <= 40
    if shape then
      for _, t in ipairs(a.tracks) do
        if type(t) ~= "table" or not valid_id(t.id) or not valid_name(t.name) or not valid_name(t.direction) then shape = false break end
      end
    end
    if not shape then sync.state, sync.note = "unlesbar", "Unerwartete Antwort der Leitstelle." return end
    sync.diffs = compare(a)
    sync.note = nil
    if #sync.diffs == 0 then sync.state = "gleich" return end
    sync.state = "abweichend"
    local signature = {}
    for _, d in ipairs(sync.diffs) do signature[#signature + 1] = d.id .. d.kind .. tostring(d.to) end
    signature = table.concat(signature, ",")
    if sync.notified ~= signature then
      sync.notified = signature
      node.notify("warnung", "Abweichung zum Netzverzeichnis: " .. describe(sync.diffs[1]) .. (#sync.diffs > 1 and (" (+" .. (#sync.diffs - 1) .. " weitere)") or "") .. ". Auf der Seite Signale uebernehmen.")
    end
  end

  -- Namen und Richtungen aus dem Verzeichnis uebernehmen; neu bewertet werden die Wirkrichtungen der Signale (Konzept 10.3)
  function role.sync_apply()
    local todo = {}
    for _, d in ipairs(sync.diffs) do if d.kind ~= "fehlt" then todo[#todo + 1] = d end end
    if #todo == 0 then return nil, "Nichts zu uebernehmen." end
    local before = ser.decode(ser.encode(config.tracks))
    local devices_before = ser.decode(ser.encode(config.devices))
    local revision = config.revision
    local function ends_ok(name)
      local seen = {}
      for _, tr in pairs(config.tracks) do if tr.dir and tr.dir.direction ~= "beide" then seen[tr.dir.direction] = true end end
      return seen[name] == true or (config.node.area_ends and (config.node.area_ends[1] == name or config.node.area_ends[2] == name))
    end
    for _, d in ipairs(todo) do
      local track = config.tracks[d.track]
      if track and track.dir then
        if d.kind == "name" then
          track.name = d.to
          for _, sg in ipairs(role.signals) do if sg.track == d.track then sg.track_name = d.to end end
        else
          track.dir.direction, track.dir.rev = d.to, d.rev or track.dir.rev
          local unique = (d.to ~= "beide") and d.to or nil
          for _, did in ipairs(track.signals or {}) do
            local info = config.devices[did] and config.devices[did].signal
            if info then
              if unique then info.effect, info.place = unique, unique
              elseif info.effect ~= nil and not ends_ok(info.effect) then info.effect, info.place = nil, nil end
              for _, sg in ipairs(role.signals) do if sg.id == did then sg.effect, sg.place = info.effect, info.place end end
            end
          end
        end
      end
    end
    config.revision = (config.revision or 0) + 1
    local ok, err = node.save_config()
    if not ok then
      config.tracks, config.devices, config.revision = before, devices_before, revision
      return nil, "Speichern fehlgeschlagen: " .. tostring(err)
    end
    local remaining = {}
    for _, d in ipairs(sync.diffs) do if d.kind == "fehlt" then remaining[#remaining + 1] = d end end
    sync.diffs = remaining
    sync.state = (#remaining == 0) and "gleich" or "abweichend"
    sync.notified = nil
    role.hello()
    dirty = true
    return #todo
  end

  -- Abgleich ---------------------------------------------------------------------------------------------------------------------------------
  local seen = {}
  function role.tick()
    local t = now()
    if claimed_area() then
      if sync.state == "frage" and t - (sync.asked or 0) >= SYNC_WAIT then sync.state, sync.note = "keine Antwort", "Die Leitstelle antwortet nicht; die lokale Einrichtung bleibt unveraendert." end
      if t >= sync.next_at and sync.state ~= "frage" then role.sync_request() end
    end
    if t - last_hello >= (hello_acked and 120 or HELLO_REPEAT) then role.hello() end
    for _, sg in ipairs(role.signals) do
      local view = read(sg)
      local key = tostring(view.available) .. tostring(view.state) .. tostring(view.forced) .. table.concat(view.owners, ",") .. tostring(view.foreign) .. tostring(view.missing)
      if seen[sg.id] ~= key then
        seen[sg.id] = key
        dirty = true
        if view.invalid then node.notify("fehler", "Signal " .. sg.track_name .. " (" .. sg.device .. ") meldet INVALID: der Bereich gilt als gestoert.") end
        if view.foreign then node.notify("warnung", "Signal " .. sg.track_name .. ": Es ist gesperrt, ohne dass diese Anlage die Sperre kennt (fremde Sperre). Sie wird nicht aufgehoben.") end
      end
      -- eigene Sperre fehlt (z.B. nach Ausfall): schuetzend erneut setzen
      if view.missing and t >= (sg.retry_at or 0) then
        sg.retry_at = t + 10
        local jid = node.journal.begin("sperre.setzen", { signal = sg.id, owner = "abgleich" })
        local result = sg.dev.hold()
        node.journal.finish(jid, { confirmed = result.confirmed })
        dirty = true
      end
    end
    if dirty or t - last_beat >= HEARTBEAT then send_state() end
  end

  -- Wiederanlauf: offene Absichten gegen den gelesenen Zustand abgleichen
  function role.recover()
    for _, entry in ipairs(node.journal.pending()) do
      local k = entry.kind
      if k == "sperre.setzen" or k == "sperre.loesen" or k == "sperre.fremd_loesen" then
        local sg = role.signals[entry.payload.signal]
        local result = { abgeglichen = true }
        if sg then
          local st = sg.dev.read()
          result.forced = st.forced
          if k == "sperre.loesen" and st.forced == true and not desired(sg.id) then
            local rel = sg.dev.release()                -- der Auftrag war unsere Absicht: zu Ende bringen
            result.completed = rel.confirmed
          end
        end
        node.journal.finish(entry.id, result)
      end
    end
  end

  -- Seite --------------------------------------------------------------------------------------------------------------------------------
  role.page = {
    id = "signale", title = "Signale",
    render = function(v, rect)
      local state = v.page_state("signale")
      state.list = state.list or { index = 1 }
      state.items = {}
      local items = {}
      for i, view in ipairs(role.states()) do
        local text = view.track_name .. "  " .. (view.available and tostring(view.state) or "nicht verfuegbar")
        local detail = {}
        if view.forced then detail[#detail + 1] = "gesperrt" end
        if #view.owners > 0 then detail[#detail + 1] = "Sperre von " .. table.concat(view.owners, ",") end
        if view.foreign then detail[#detail + 1] = "FREMDE SPERRE" end
        if view.missing then detail[#detail + 1] = "Sperre fehlt" end
        if view.invalid then detail[#detail + 1] = "GESTOERT" end
        local kind = (view.invalid or not view.available) and "halt" or (view.foreign or view.missing) and "attention" or (view.forced and "wait" or "ok")
        items[i] = { text = text, detail = #detail > 0 and table.concat(detail, ", ") or "keine zusaetzliche Sperre", kind = kind }
        state.items[i] = view
      end
      local has_sync = claimed_area() ~= nil
      W.list(v, "signale", has_sync and { x = rect.x, y = rect.y, w = rect.w, h = rect.h - 1 } or rect, items, state.list, { empty = "Keine Signale eingerichtet." })
      if has_sync then
        local text, kind
        if sync.state == "abweichend" then text, kind = "Abweichung: " .. describe(sync.diffs[1]) .. (#sync.diffs > 1 and (" (+" .. (#sync.diffs - 1) .. ")") or ""), "attention"
        elseif sync.state == "gleich" then text, kind = "Netzverzeichnis: Namen und Richtungen stimmen.", "ok"
        elseif sync.state == "frage" then text, kind = "Netzverzeichnis: frage die Leitstelle ...", "wait"
        elseif sync.state == "offen" then text, kind = "Netzverzeichnis: noch nicht abgeglichen.", "dim"
        else text, kind = "Netzverzeichnis: " .. tostring(sync.note or sync.state), "wait" end
        W.label(v, rect.x + 1, rect.y + rect.h - 1, text, kind, rect.w - 2)
      end
    end,
    actions = function(v)
      local state = v.page_state("signale")
      local view = state.items and state.items[(state.list or { index = 1 }).index]
      local own = view and view.owners and #view.owners > 0
      local list = {
        { id = "sperre", label = "Sperre", enabled = view ~= nil, reason = "Erst ein Signal waehlen." },
        { id = "aufheben", label = confirm.armed and "Wirklich?" or "Aufheben", kind = "danger", enabled = view ~= nil and (own or view.foreign),
          reason = "Keine Sperre vorhanden." },
      }
      if claimed_area() then
        list[#list + 1] = { id = "abgleich", label = (#sync.diffs > 0 and sync.state == "abweichend") and "Uebernehmen" or "Abgleich", kind = "secondary",
          enabled = sync.state ~= "frage", reason = "Die Frage an die Leitstelle laeuft." }
      end
      return list
    end,
    on_action = function(v, id)
      local state = v.page_state("signale")
      local view = state.items and state.items[state.list.index]
      if id == "act:abgleich" then
        if sync.state == "abweichend" then
          local n_changed, why = role.sync_apply()
          v.hint = n_changed and (n_changed .. " Aenderung(en) aus dem Verzeichnis uebernommen.") or why
        else
          local ok, why = role.sync_request()
          v.hint = ok and "Frage die Leitstelle ..." or why
        end
        return true
      end
      if not view then return true end
      if id == "act:sperre" then
        local ok, err = role.lock(view.id, "bediener", "vom Bediener")
        v.hint = ok and "Zusaetzliche Sperre gesetzt." or err
        return true
      elseif id == "act:aufheben" then
        if not confirm.armed then
          confirm.armed = true
          v.hint = "Nochmal druecken: nur die zusaetzliche Sperre wird aufgehoben, native Rotursachen bleiben."
        else
          confirm.armed = false
          local ok, err
          if view.foreign then ok, err = role.release_foreign(view.id) else ok, err = role.unlock(view.id, "bediener") end
          v.hint = ok and "Sperre aufgehoben (Besitzer: bediener)." or err
          if ok and #view.owners > 1 then v.hint = "Dein Teil der Sperre ist aufgehoben; andere Besitzer halten das Signal weiter." end
        end
        return true
      end
    end,
  }

  role.recover()
  -- gespeicherte Sperren, die physisch fehlen, setzt der erste Abgleich schuetzend neu; nichts wird freigegeben
  return role
end

return M
