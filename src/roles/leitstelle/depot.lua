--[[
Purpose: Seite Depot der Leitstelle: Zuege abstellen, aktivieren, ausschleusen und aufnehmen, die Betriebsart wechseln.
API: require("roles.leitstelle.depot")(ctx) -> Seite { id, title, render, actions, on_action, ... } (zentrale.lua sammelt sie in role.pages)
Notes: ctx kommt aus roles/zentrale.lua und gibt der Seite Zugriff auf die Leitstelle (role) und ihre Zustaende (Nodes, Sperren, Muster, Betrieb ...). Die Seite zeichnet und bedient, die Regeln liegen in role und in domain/.
]]

local W = require("ui.widgets")
local label = require("core.label")

return function(ctx)
  local role = ctx.role
  local active_order_of = ctx.active_order_of

  -- Depot: abstellen, aktivieren, ausschleusen, aufnehmen, Betriebsart ---------------------------------------------------------------------
  local ZSTATE = { registriert = "registriert", gesteuert = "gesteuert", uebergabe = "Uebergabe offen", abgestellt = "abgestellt", ausgeschleust = "ausgeschleust" }
  local depot_arm = {}
  local page = {
    id = "depot", title = "Depot",
    render = function(v, rect)
      local state = v.page_state("depot")
      state.list = state.list or { index = 1 }
      state.screen = state.screen or "liste"
      state.target = state.target or { value = "", max = 40 }
      if state.screen == "abstellen" then
        W.label(v, rect.x + 1, rect.y, "Zug abstellen: " .. tostring(state.train_id), "hell", rect.w - 2)
        W.field(v, "ziel", rect.x + 1, rect.y + 2, math.min(40, rect.w - 2), "Abstellstation (Bahnhof oder Gleis-Name)", state.target)
        W.label(v, rect.x + 1, rect.y + 5, "Der Zug faehrt als normaler Auftrag dorthin und wartet dort.", "dim", rect.w - 2)
        return
      end
      local items = {}
      state.trains = {}
      for i, train in ipairs(role.register.list()) do
        local pos = train.position
        local where = pos and (pos.kind == "am_bahnhof" and ("am Bahnhof " .. tostring(pos.where)) or pos.kind) or "unbekannt"
        local order = active_order_of(train.id)
        local kind = train.state == "gesteuert" and "text" or (train.state == "abgestellt" and "dim" or "attention")
        items[#items + 1] = { text = train.id .. " " .. train.display_name, detail = (ZSTATE[train.state] or train.state) .. ", " .. tostring(train.mode) .. ", " .. where .. (order and (", Auftrag " .. order.id) or ""), kind = kind }
        state.trains[i] = train
      end
      local list_rect = { x = rect.x, y = rect.y, w = rect.w, h = rect.h - 1 }
      W.list(v, "depot", list_rect, items, state.list, { empty = "Noch kein Zug angemeldet." })
      if role.depot_status then W.label(v, rect.x + 1, rect.y + rect.h - 1, role.depot_status.text, role.depot_status.kind, rect.w - 2) end
    end,
    actions = function(v)
      local state = v.page_state("depot")
      if state.screen == "abstellen" then
        return { { id = "dp_los", label = "Abstellen", side = "rechts" }, { id = "dp_zurueck", label = "Zurueck", kind = "secondary", side = "rechts" } }
      end
      local train = state.trains and state.trains[(state.list or { index = 1 }).index]
      local list = {}
      local s = train and train.state
      local busy = train and active_order_of(train.id) ~= nil
      if s == "gesteuert" then
        list[#list + 1] = { id = "dp_abstellen", label = "Abstellen", enabled = not busy, reason = "Der Zug hat einen laufenden Auftrag." }
        list[#list + 1] = { id = "dp_ausschleusen", label = depot_arm.eject and "Wirklich?" or "Ausschleusen", kind = "danger", enabled = not busy, reason = "Der Zug hat einen laufenden Auftrag." }
        list[#list + 1] = { id = "dp_art", label = "Art", kind = "secondary", enabled = not busy, reason = "Waehrend eines Auftrags wechselt die Betriebsart nicht." }
      elseif s == "abgestellt" then
        list[#list + 1] = { id = "dp_aktivieren", label = "Aktivieren" }
        list[#list + 1] = { id = "dp_ausschleusen", label = depot_arm.eject and "Wirklich?" or "Ausschleusen", kind = "danger" }
      elseif train then
        list[#list + 1] = { id = "dp_aufnehmen", label = depot_arm.take and "Wirklich?" or "Aufnehmen", kind = "primary" }
      else
        list[#list + 1] = { id = "dp_aufnehmen", label = "Aufnehmen", enabled = false, reason = "Erst einen Zug waehlen." }
      end
      return list
    end,
    on_action = function(v, id)
      local state = v.page_state("depot")
      local train = state.trains and state.trains[state.list.index]
      local function say(ok, err) v.hint = ok and (role.depot_status and role.depot_status.text) or err return true end
      if id == "act:dp_abstellen" and train then
        state.screen, state.train_id, state.target.value = "abstellen", train.id, ""
        return true
      elseif id == "act:dp_zurueck" then
        state.screen = "liste"
        return true
      elseif id == "act:dp_los" then
        local order, why = role.park(state.train_id, state.target.value)
        if order then state.screen = "liste" end
        v.hint = why
        return true
      elseif id == "act:dp_aktivieren" and train then
        local ok, why = role.activate(train.id)
        return say(ok, why)
      elseif id == "act:dp_art" and train then
        local ok, why = role.cycle_mode(train.id)
        return say(ok, why)
      elseif id == "act:dp_ausschleusen" and train then
        if not depot_arm.eject then
          depot_arm.eject = true
          v.hint = "Nochmal druecken, wenn der Fahrbetrieb des Zuges geklaert ist (Fahrplan, Freigabe). Der Create-Fahrplan bleibt im Zug."
        else
          depot_arm.eject = false
          local ok, why = role.eject(train.id)
          say(ok, why)
        end
        return true
      elseif id == "act:dp_aufnehmen" and train then
        if not depot_arm.take then
          depot_arm.take = true
          v.hint = "Nochmal druecken: der Zug steht am Haltepunkt, der Fahrbetrieb ist geklaert, der Warteauftrag darf erteilt werden."
        else
          depot_arm.take = false
          local ok, why = role.take_over(train.id)
          say(ok, why)
        end
        return true
      end
    end,
  }

  return page
end
