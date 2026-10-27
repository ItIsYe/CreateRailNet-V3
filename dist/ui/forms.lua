--[[
Purpose: Seitenbaustein "Liste mit Anlegen": links die Liste der vorhandenen Eintraege mit Aktionen, rechts (nach "Neu") ein Formular mit Eingabefeldern, drei je Bildschirmseite, mit Weiter, Zurueck und Speichern. Ein Eintrag wird nur gespeichert, wenn die Fachlogik ihn annimmt; deren Fehlertext erscheint als Hinweis.
API: forms.page{ id, title, empty, items = fn(v) -> items, records, fields = { { id, label, max, default } }, on_save = fn(values) -> ok, fehler, extra = { { id, label, kind, enabled = fn(record) -> bool, reason, run = fn(v, record) -> hinweis } }, new_label, edit = fn(record) -> werte } -> Seite
Notes: Die Seite hat nur eine Zustandstabelle (v.page_state(id)); Felder tragen { value, max } wie im Assistenten. Mit "edit" kann ein vorhandener Eintrag zum Bearbeiten in das Formular geladen werden.
]]

local W = require("ui.widgets")

local M = {}

local PER_SCREEN = 3

function M.page(spec)
  local page = { id = spec.id, title = spec.title }

  local function state_of(v)
    local st = v.page_state(spec.id)
    st.list = st.list or { index = 1 }
    st.screen = st.screen or "liste"
    if not st.fields then
      st.fields = {}
      for _, f in ipairs(spec.fields) do st.fields[f.id] = { value = f.default or "", max = f.max or 40 } end
    end
    return st
  end

  local function screens() return math.ceil(#spec.fields / PER_SCREEN) end

  function page.render(v, rect)
    local st = state_of(v)
    if st.screen == "liste" then
      local items, records = spec.items(v)
      st.records = records
      W.list(v, spec.id, rect, items, st.list, { empty = spec.empty })
    else
      local n = st.screen
      W.label(v, rect.x + 1, rect.y, spec.title .. " - " .. (st.editing and "bearbeiten" or "neu") .. " (" .. n .. "/" .. screens() .. ")", "hell", rect.w - 2)
      for i = 1, PER_SCREEN do
        local f = spec.fields[(n - 1) * PER_SCREEN + i]
        if f then W.field(v, f.id, rect.x + 1, rect.y + 1 + (i - 1) * 3, math.min(f.width or 40, rect.w - 2), f.label, st.fields[f.id]) end
      end
    end
  end

  function page.actions(v)
    local st = state_of(v)
    if st.screen == "liste" then
      local record = st.records and st.records[st.list.index]
      local list = { { id = "neu", label = spec.new_label or "Neu", kind = "primary" } }
      if spec.edit then list[#list + 1] = { id = "bearbeiten", label = "Aendern", kind = "secondary", enabled = record ~= nil, reason = "Erst einen Eintrag waehlen." } end
      for _, extra in ipairs(spec.extra or {}) do
        list[#list + 1] = {
          id = extra.id, label = type(extra.label) == "function" and extra.label(record) or extra.label, kind = extra.kind or "secondary",
          enabled = record ~= nil and (not extra.enabled or extra.enabled(record)), reason = extra.reason or "Erst einen Eintrag waehlen.",
        }
      end
      return list
    end
    return {
      { id = st.screen == screens() and "f_speichern" or "f_weiter", label = st.screen == screens() and "Speichern" or "Weiter", side = "rechts" },
      { id = "f_zurueck", label = "Zurueck", kind = "secondary", side = "rechts" },
    }
  end

  function page.on_action(v, id)
    local st = state_of(v)
    local function reset()
      for _, f in ipairs(spec.fields) do st.fields[f.id].value = f.default or "" end
    end
    if id == "act:neu" then
      reset()
      st.editing, st.screen = false, 1
      return true
    elseif id == "act:bearbeiten" then
      local record = st.records and st.records[st.list.index]
      if record and spec.edit then
        reset()
        for k, value in pairs(spec.edit(record)) do if st.fields[k] then st.fields[k].value = tostring(value) end end
        st.editing, st.screen = true, 1
      end
      return true
    elseif id == "act:f_weiter" then
      st.screen = st.screen + 1
      return true
    elseif id == "act:f_zurueck" then
      if st.screen == 1 then st.screen = "liste" else st.screen = st.screen - 1 end
      return true
    elseif id == "act:f_speichern" then
      local values = {}
      for _, f in ipairs(spec.fields) do values[f.id] = st.fields[f.id].value end
      local ok, err = spec.on_save(values)
      if ok then
        v.hint = "Gespeichert."
        st.screen = "liste"
      else
        v.hint = tostring(err)
      end
      return true
    end
    for _, extra in ipairs(spec.extra or {}) do
      if id == "act:" .. extra.id then
        local record = st.records and st.records[st.list.index]
        if record then
          local text = extra.run(v, record)
          if text then v.hint = text end
        end
        return true
      end
    end
  end

  return page
end

return M
