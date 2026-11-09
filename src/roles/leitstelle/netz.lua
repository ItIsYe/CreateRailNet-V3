--[[
Purpose: Seite Netz der Leitstelle: die Nodes des Netzes mit Zustand, Gleisen und Sicherung samt reservierten Kennungen; Stilllegen, Aktivieren, Verwerfen und Entfernen (jeweils zweimal tippen).
API: require("roles.leitstelle.netz")(ctx) -> Seite { id, title, render, actions, on_action, ... } (zentrale.lua sammelt sie in role.pages)
Notes: ctx kommt aus roles/zentrale.lua und gibt der Seite Zugriff auf die Leitstelle (role) und ihre Zustaende (Nodes, Sperren, Muster, Betrieb ...). Die Seite zeichnet und bedient, die Regeln liegen in role und in domain/.
]]

local W = require("ui.widgets")
local label = require("core.label")

return function(ctx)
  local role = ctx.role
  local nodes = ctx.nodes
  local retired = ctx.retired
  local track_state = ctx.track_state
  local reachable = ctx.reachable
  local arm = {}

  local page = {
    id = "netz", title = "Netz",
    render = function(v, rect)
      local state = v.page_state("netz")
      state.list = state.list or { index = 1 }
      local items = {}
      local ids = {}
      state.ids = {}
      for id in pairs(nodes) do ids[#ids + 1] = id end
      table.sort(ids)
      for _, id in ipairs(ids) do
        local info = nodes[id]
        local ok = reachable(id)
        local tracks = {}
        for _, tr in ipairs(info.tracks or {}) do
          local st = track_state[id .. ":" .. tr.id]
          tracks[#tracks + 1] = tr.name .. (st and st.present and (":" .. tostring(st.train)) or "")
        end
        items[#items + 1] = { text = id .. " " .. (info.name or ""), detail = (retired[id] and "STILLGELEGT" or (ok and "erreichbar" or "NICHT ERREICHBAR")) .. ", " .. #tracks .. " Gleise" .. (#tracks > 0 and (": " .. table.concat(tracks, ",")) or ""), kind = retired[id] and "dim" or (ok and "ok" or "halt") }
        state.ids = state.ids or {}
        state.ids[#items] = id
      end
      -- vom Verzeichnis vergebene Kennungen, die sich noch nie gemeldet haben (Einrichtung laeuft oder wurde abgebrochen)
      state.reserved = {}
      for _, entry in ipairs(role.netz.nodes()) do
        if entry.state == "reserviert" and not nodes[entry.id] then
          items[#items + 1] = { text = entry.id .. " " .. entry.name, detail = "RESERVIERT, hat sich noch nicht gemeldet", kind = "wait" }
          state.ids[#items] = entry.id
          state.reserved[entry.id] = true
        end
      end
      W.list(v, "netz", rect, items, state.list, { empty = "Noch kein Node hat sich gemeldet." })
    end,
    actions = function(v)
      local state = v.page_state("netz")
      local id = state.ids and state.ids[(state.list or { index = 1 }).index]
      if id and state.reserved and state.reserved[id] then
        return { { id = "stilllegen", label = arm.discard == id and "Wirklich?" or "Verwerfen", kind = "danger" } }
      end
      local can_forget = id ~= nil and (retired[id] or not reachable(id))
      return {
        { id = "stilllegen", label = id and retired[id] and "Aktivieren" or (arm.retire and "Wirklich?" or "Stilllegen"), kind = "danger", enabled = id ~= nil, reason = "Erst einen Node waehlen." },
        { id = "entfernen", label = arm.forget == id and "Wirklich?" or "Entfernen", kind = "danger", enabled = can_forget,
          reason = id and "Der Node laeuft noch: erst stilllegen." or "Erst einen Node waehlen." },
      }
    end,
    on_action = function(v, action)
      if action ~= "act:stilllegen" and action ~= "act:entfernen" then return end
      local state = v.page_state("netz")
      local id = state.ids and state.ids[state.list.index]
      if not id then return true end
      if action == "act:entfernen" then
        arm.retire, arm.discard = false, nil
        if arm.forget ~= id then
          arm.forget = id
          v.hint = "Nochmal druecken: " .. id .. " entfernen."
        else
          arm.forget = nil
          local ok, err = role.forget_node(id)
          v.hint = ok and ("Node " .. id .. " entfernt.") or err
        end
        return true
      end
      arm.forget = nil
      if state.reserved and state.reserved[id] then
        -- eine nie aktivierte Anforderung: verwerfen (die Kennung bleibt vergeben)
        if arm.discard ~= id then
          arm.discard = id
          v.hint = "Nochmal druecken: die Anforderung " .. id .. " wird verworfen (die Kennung wird nicht wieder vergeben)."
        else
          arm.discard = nil
          local ok, err = role.netz.discard_node(id)
          v.hint = ok and ("Anforderung " .. id .. " verworfen.") or err
        end
        return true
      end
      if retired[id] then
        local ok, err = role.unretire(id)
        v.hint = ok and ("Node " .. id .. " ist wieder aktiv.") or err
      elseif not arm.retire then
        arm.retire = true
        v.hint = "Nochmal druecken: " .. id .. " wird stillgelegt (nur fuer den Ersatz durch einen anderen Computer). Meldungen von ihr werden nicht mehr beachtet."
      else
        arm.retire = false
        local ok, err = role.retire(id)
        v.hint = ok and ("Node " .. id .. " ist stillgelegt.") or err
      end
      return true
    end,
  }

  return page
end
