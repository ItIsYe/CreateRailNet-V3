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
local GROUP = 30             -- Signale je Berichtsteil (Grundeinteilung; ein grosser Node meldet in Teilen, eine Sicht hat etwa 150 Zeichen)
local BUDGET = 5000          -- Zeichen Nutzlast je Nachricht; mit dem Umschlag (etwa 300) bleibt es unter der Grenze der Funkschicht von 6000
local MAX_PER_TICK = 6       -- Berichtsteile je Takt: ein Node mit hunderten Signalen ueberflutet die Leitstelle nicht
local LOCK_FILE = "/crn_data/sperren.lua"

function M.new(node)
  local role = { signals = {} }
  local config = node.config
  local env = node.env
  local now = function() return node.clock.now() end
  local persisted = node.store.load(LOCK_FILE) or { locks = {} }
  persisted.locks = persisted.locks or {}
  local last_beat, last_hello, hello_acked = now(), -9999, false
  local pending = {}       -- Nummer des Berichtsteils -> true: muss noch gesendet werden
  local cursor = 1         -- ab hier wird weitergesendet (rundum): ein Teil steht nicht dauernd an der ungluenstigsten Stelle
  local views = {}         -- Position -> zuletzt gelesene Sicht
  local confirm = {}
  local started_at = now()

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
        local sg = { id = did, track = tid, track_name = spec.name, device = config.devices[did].device, last = {} }
        sg.dev = signallib.new(env, sg.device)
        sg.pos = #role.signals + 1
        role.signals[did] = sg
        role.signals[#role.signals + 1] = sg
      end
    end
  end

  -- Berichtsteile: jedes Signal gehoert zu einer festen Gruppe; geaendert wird nur gemeldet, was sich geaendert hat
  local function group_count() return math.max(1, math.ceil(#role.signals / GROUP)) end
  local function mark(id)
    local sg = role.signals[id]
    if sg then pending[math.floor((sg.pos - 1) / GROUP) + 1] = true end
  end
  local function full_round()
    for g = 1, group_count() do pending[g] = true end
    last_beat = now()
  end
  full_round()

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
    mark(id)
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
    mark(id)
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
    mark(id)
    return result.confirmed or nil, not result.confirmed and "Das Aufheben wurde nicht bestaetigt." or nil
  end

  -- Berichte -------------------------------------------------------------------------------------------------------------------------------
  -- Eine Nachricht darf nur etwa 6000 Zeichen tragen: ein Node mit hunderten Signalen meldet deshalb in Teilen. Jeder Teil nennt seine
  -- Startposition (first) und die Gesamtzahl (total); die Leitstelle setzt ihn an diese Stelle. Ein verlorener Teil heilt mit dem naechsten
  -- vollstaendigen Durchlauf (alle HEARTBEAT Sekunden), ein doppelter oder vertauschter Teil schadet nicht.
  local function split_send(first, last, fill, send)
    local part = {}
    for i = first, last do part[#part + 1] = fill(i) end
    if last > first and #ser.encode(part) > BUDGET then
      local mid = math.floor((first + last) / 2)
      split_send(first, mid, fill, send)
      split_send(mid + 1, last, fill, send)
      return
    end
    send(first, part)
  end

  local function send_state_part(first, last)
    split_send(first, last, function(i) return views[i] or read(role.signals[i]) end, function(from, part)
      node.send_to(central(), "meldung", { kind = "signale", node = config.node.id, first = from, total = #role.signals, signals = part, t = now() })
    end)
  end

  local function send_pending()
    local count, sent, start = group_count(), 0, cursor
    for k = 0, count - 1 do
      local g = (start - 1 + k) % count + 1
      if pending[g] then
        if sent >= MAX_PER_TICK then return end          -- der Rest folgt im naechsten Takt
        pending[g] = nil
        cursor = g % count + 1
        send_state_part((g - 1) * GROUP + 1, math.min(#role.signals, g * GROUP))
        sent = sent + 1
      end
    end
  end

  function role.hello()
    local list = {}
    for _, sg in ipairs(role.signals) do list[#list + 1] = { id = sg.id, track = sg.track_name, device = sg.device } end
    for first = 1, math.max(1, #list), GROUP do
      split_send(first, math.min(#list, first + GROUP - 1), function(i) return list[i] end, function(from, part)
        local payload = { kind = "hallo_signale", node = config.node.id, first = from, total = #list, signals = part }
        if from == 1 then
          payload.name, payload.roles, payload.revision, payload.active = config.node.name, config.node.roles, config.revision, config.status == "aktiv"
        end
        node.send_to(central(), "meldung", payload)
      end)
    end
    last_hello = now()
  end

  function role.on_event(ev)
    if ev.kind == "signal" then mark(ev.id) end
  end

  function role.on_message(m, status)
    if status ~= "ok" then return end
    if m.messageType == "bestaetigung" and m.payload.kind == "antwort" and m.payload.antwort_auf == "hallo_signale" then
      hello_acked = true
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

  -- Abgleich ---------------------------------------------------------------------------------------------------------------------------------
  local seen = {}
  function role.tick()
    local t = now()
    if t - last_hello >= (hello_acked and 120 or HELLO_REPEAT) then role.hello() end
    for i, sg in ipairs(role.signals) do
      local view = read(sg)
      views[i] = view
      local key = tostring(view.available) .. tostring(view.state) .. tostring(view.forced) .. table.concat(view.owners, ",") .. tostring(view.foreign) .. tostring(view.missing)
      if seen[sg.id] ~= key then
        seen[sg.id] = key
        mark(sg.id)
        if view.invalid then node.notify("fehler", "Signal " .. sg.track_name .. " (" .. sg.device .. ") meldet INVALID: der Bereich gilt als gestoert.") end
        if view.foreign then node.notify("warnung", "Signal " .. sg.track_name .. ": Es ist gesperrt, ohne dass diese Anlage die Sperre kennt (fremde Sperre). Sie wird nicht aufgehoben.") end
      end
      -- eigene Sperre fehlt (z.B. nach Ausfall): schuetzend erneut setzen
      if view.missing and t >= (sg.retry_at or 0) then
        sg.retry_at = t + 10
        local jid = node.journal.begin("sperre.setzen", { signal = sg.id, owner = "abgleich" })
        local result = sg.dev.hold()
        node.journal.finish(jid, { confirmed = result.confirmed })
        mark(sg.id)
      end
    end
    if t - last_beat >= HEARTBEAT then full_round() end
    send_pending()
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
      W.list(v, "signale", rect, items, state.list, { empty = "Keine Signale eingerichtet." })
    end,
    actions = function(v)
      local state = v.page_state("signale")
      local view = state.items and state.items[(state.list or { index = 1 }).index]
      local own = view and view.owners and #view.owners > 0
      return {
        { id = "sperre", label = "Sperre", enabled = view ~= nil, reason = "Erst ein Signal waehlen." },
        { id = "aufheben", label = confirm.armed and "Wirklich?" or "Aufheben", kind = "danger", enabled = view ~= nil and (own or view.foreign),
          reason = "Keine Sperre vorhanden." },
      }
    end,
    on_action = function(v, id)
      local state = v.page_state("signale")
      local view = state.items and state.items[state.list.index]
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
