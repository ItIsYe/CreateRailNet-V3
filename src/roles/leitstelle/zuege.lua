--[[
Purpose: Seite Zuege der Leitstelle: die angemeldeten Zuege mit Zustand und Aufenthalt, Anzeigename und Create-Name aendern, einen Zug abmelden (zweimal tippen).
API: require("roles.leitstelle.zuege")(ctx) -> Seite { id, title, render, actions, on_action, ... } (zentrale.lua sammelt sie in role.pages)
Notes: ctx kommt aus roles/zentrale.lua und gibt der Seite Zugriff auf die Leitstelle (role) und ihre Zustaende (Nodes, Sperren, Muster, Betrieb ...). Die Seite zeichnet und bedient, die Regeln liegen in role und in domain/.
]]

local W = require("ui.widgets")
local label = require("core.label")

return function(ctx)
  local role = ctx.role
  local arm = {}

  local page = {
    id = "zuege", title = "Zuege",
    render = function(v, rect)
      local state = v.page_state("zuege")
      state.list = state.list or { index = 1 }
      state.fields = state.fields or { name = { value = "", max = 30 }, create = { value = "", max = 30 } }
      if state.screen == "aendern" then
        W.label(v, rect.x + 1, rect.y, "Zug " .. tostring(state.edit) .. " aendern", "hell", rect.w - 2)
        W.field(v, "zname", rect.x + 1, rect.y + 2, math.min(34, rect.w - 2), "Anzeigename", state.fields.name)
        W.field(v, "zcreate", rect.x + 1, rect.y + 5, math.min(34, rect.w - 2), "Create-Zugname (so heisst der Zug in Create)", state.fields.create)
        return
      end
      local items = {}
      state.trains = {}
      for i, train in ipairs(role.register.list()) do
        local pos = train.position
        local where = pos and (pos.kind == "am_bahnhof" and ("am Bahnhof " .. tostring(pos.where)) or pos.kind) or "unbekannt"
        items[#items + 1] = { text = train.id .. " " .. train.display_name, detail = train.state .. ", " .. train.mode .. ", " .. where }
        state.trains[i] = train
      end
      W.list(v, "zuege", rect, items, state.list, { empty = "Noch kein Zug angemeldet (Rolle Anmeldung)." })
    end,
    actions = function(v)
      local state = v.page_state("zuege")
      if state.screen == "aendern" then
        return {
          { id = "z_speichern", label = "Speichern", side = "rechts" },
          { id = "z_zurueck", label = "Zurueck", kind = "secondary", side = "rechts" },
        }
      end
      local train = state.trains and state.trains[(state.list or { index = 1 }).index]
      return {
        { id = "z_aendern", label = "Aendern", kind = "secondary", enabled = train ~= nil, reason = "Erst einen Zug waehlen." },
        { id = "abmelden", label = arm.unregister and "Wirklich?" or "Abmelden", kind = "danger", enabled = train ~= nil, reason = "Erst einen Zug waehlen." },
      }
    end,
    on_action = function(v, id)
      local state = v.page_state("zuege")
      if id == "act:z_aendern" then
        local train = state.trains and state.trains[state.list.index]
        if not train then return true end
        state.fields = state.fields or { name = { value = "", max = 30 }, create = { value = "", max = 30 } }
        state.fields.name.value, state.fields.create.value = train.display_name or "", train.create_name or ""
        state.edit, state.screen = train.id, "aendern"
        return true
      elseif id == "act:z_zurueck" then
        state.screen = nil
        return true
      elseif id == "act:z_speichern" then
        local train = role.register.get(state.edit)
        if not train then state.screen = nil return true end
        local new_create = state.fields.create.value:match("^%s*(.-)%s*$")
        if new_create ~= train.create_name then
          for _, order in ipairs(role.orders.active()) do
            if order.train == train.id then
              v.hint = "Der Zug hat den aktiven Auftrag " .. order.id .. ": erst beenden oder abbrechen."
              return true
            end
          end
          local ok, err = role.register.rename_create(train.id, new_create)
          if not ok then v.hint = err return true end
        end
        local new_name = state.fields.name.value:match("^%s*(.-)%s*$")
        if new_name ~= "" and new_name ~= train.display_name then
          local ok, err = role.register.rename_display(train.id, new_name)
          if not ok then v.hint = err return true end
        end
        v.hint = "Gespeichert."
        state.screen = nil
        return true
      end
      if id == "act:abmelden" then
        local state = v.page_state("zuege")
        local train = state.trains and state.trains[state.list.index]
        if not train then return true end
        for _, order in ipairs(role.orders.active()) do
          if order.train == train.id then
            v.hint = "Der Zug hat den aktiven Auftrag " .. order.id .. "."
            arm.unregister = false
            return true
          end
        end
        if not arm.unregister then
          arm.unregister = true
          v.hint = "Nochmal druecken: nur die Zustaendigkeit endet, nicht der Zug."
        else
          arm.unregister = false
          role.register.unregister(train.id)
          v.hint = "Abgemeldet; der Zug und seine Belegung bleiben bestehen."
        end
        return true
      end
    end,
  }

  return page
end
