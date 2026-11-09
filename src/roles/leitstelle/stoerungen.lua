--[[
Purpose: Seite Stoerungen der Leitstelle: Stoerungen und Wartung (Halten und Fortsetzen), Pruefung der Umgebung, fremde Zuege aus der Liste nehmen.
API: require("roles.leitstelle.stoerungen")(ctx) -> Seite { id, title, render, actions, on_action, ... } (zentrale.lua sammelt sie in role.pages)
Notes: ctx kommt aus roles/zentrale.lua und gibt der Seite Zugriff auf die Leitstelle (role) und ihre Zustaende (Nodes, Sperren, Muster, Betrieb ...). Die Seite zeichnet und bedient, die Regeln liegen in role und in domain/.
]]

local W = require("ui.widgets")
local label = require("core.label")

return function(ctx)
  local role = ctx.role
  local operation = ctx.operation
  local held = ctx.held

  -- Stoerungen und Wartung -------------------------------------------------------------------------------------------------------------------
  local hold_arm = {}
  local page = {
    id = "stoerungen", title = "Stoerungen",
    render = function(v, rect)
      local state = v.page_state("stoerungen")
      state.list = state.list or { index = 1 }
      state.rows = {}
      local items = {}
      for _, f in ipairs(role.faults()) do items[#items + 1] = { text = f.who, detail = f.text, kind = f.kind } end
      -- fremde Zuege (nicht angemeldet): reale Beobachtungen, keine Zuordnung
      for _, row in ipairs(role.unknown_list()) do
        items[#items + 1] = { text = "Fremd: " .. row.name, detail = (row.present and "steht " or "war ") .. "an " .. tostring(row.station or row.track) .. " (" .. tostring(row.node) .. ")", kind = row.present and "attention" or "dim" }
        state.rows[#items] = row
      end
      local drain = role.drain_state()
      W.list(v, "stoerungen", { x = rect.x, y = rect.y, w = rect.w, h = rect.h - 1 }, items, state.list, { empty = "Keine Stoerung und keine fremden Zuege bekannt." })
      W.label(v, rect.x + 1, rect.y + rect.h - 1, "Auftraege: " .. drain.active .. " offen, " .. drain.committed .. " mit Freigabe/unterwegs", "dim", rect.w - 2)
    end,
    actions = function(v)
      local is_held = held()
      local state = v.page_state("stoerungen")
      local row = state.rows and state.rows[(state.list or { index = 1 }).index]
      return {
        { id = "halten", label = is_held and (hold_arm.resume and "Wirklich?" or "Fortsetzen") or "Halten", kind = is_held and "primary" or "danger" },
        { id = "pruefen", label = "Pruefen", kind = "secondary" },
        { id = "vergessen", label = "Vergessen", kind = "secondary", enabled = row ~= nil and not row.present, reason = "Nur ein fremder Zug, der nicht mehr am Gleis steht." },
      }
    end,
    on_action = function(v, id)
      if id == "act:halten" then
        if operation.hold then
          if not hold_arm.resume then
            hold_arm.resume = true
            v.hint = "Nochmal druecken: neue Abfahrten werden wieder freigegeben."
          else
            hold_arm.resume = false
            local ok, err = role.set_hold(false)
            v.hint = ok and "Betrieb fortgesetzt." or err
          end
        else
          local ok, err = role.set_hold(true, "vom Bediener")
          v.hint = ok and "Neue Abfahrten sind zurueckgehalten; Fahrten unterwegs laufen weiter." or err
        end
        return true
      elseif id == "act:pruefen" then
        v.hint = "Zustandsabfrage an " .. role.refresh_all() .. " Nodes gesendet."
        return true
      elseif id == "act:vergessen" then
        local state = v.page_state("stoerungen")
        local row = state.rows and state.rows[state.list.index]
        if row then
          local ok, why = role.forget_unknown(row.name)
          v.hint = ok and "Aus der Liste genommen; Belegungen bleiben ueber ihre eigenen Meldungen bestehen." or why
        end
        return true
      end
    end,
  }

  return page
end
