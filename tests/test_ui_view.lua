--[[
Purpose: Ansicht und Bausteine (src/ui/view.lua, widgets.lua): Layout je Groesse, Navigation, Listen mit Seiten, Eingabefeld, gesperrte Tasten mit Grund, Tastatur, Beruehrung, Groessenaenderung, mehrere Ansichten, Monochrom.
]]

local t = dofile("tests/lib/t.lua")
local screenlib = dofile("tests/fakes/screen.lua")
local viewlib = require("ui.view")
local W = require("ui.widgets")

local KEY = { tab = 258, enter = 257, backspace = 259, up = 265, down = 264, escape = 256, pageDown = 267, pageUp = 266 }

local function make_pages(log)
  local items = {}
  for i = 1, 25 do items[i] = { text = "Signal " .. i, detail = (i % 2 == 0) and "rot" or "gruen" } end
  return {
    {
      id = "liste", title = "Signale",
      render = function(v, rect)
        local state = v.page_state("liste")
        state.list = state.list or { index = 1 }
        state.field = state.field or { value = "" }
        W.label(v, rect.x + 1, rect.y, "Signalliste", "hell")
        W.list(v, "signale", { x = rect.x, y = rect.y + 1, w = rect.w, h = rect.h - 4 }, items, state.list)
        W.field(v, "name", rect.x + 1, rect.y + rect.h - 3, math.min(30, rect.w - 2), "Name", state.field)
      end,
      actions = function(v)
        return {
          { id = "neu", label = "Neu" },
          { id = "loeschen", label = "Loeschen", kind = "danger", enabled = false, reason = "Erst ein Signal auswaehlen." },
        }
      end,
      on_action = function(v, id)
        log[#log + 1] = id
        return id ~= "back"
      end,
    },
    { id = "info", title = "Info", render = function(v, rect) W.label(v, rect.x + 1, rect.y, "Version 0.1.0") end },
    { id = "geheim", title = "Geheim", visible = function() return false end, render = function() end },
  }
end

local function ctx(log)
  return {
    title = function() return "Westbahnhof - Passagierbahnhof" end,
    status = function() return { text = "Bereit", kind = "ok" } end,
    on_action = function(v, id) log[#log + 1] = "ctx:" .. id end,
  }
end

local function new_view(w, h, opts)
  opts = opts or {}
  local log = {}
  local screen = screenlib.new(w, h, opts)
  local v = viewlib.new({ target = screen, name = opts.name, ctx = ctx(log), pages = make_pages(log) })
  v.render()
  return v, screen, log
end

local function contains_row(screen, text)
  for _, row in ipairs(screen.rows()) do if row:find(text, 1, true) then return true end end
  return false
end

return {
  { "grosses Layout: Kopf, Navigation, Liste, Feld, Aktionen", function()
    local v, screen = new_view(100, 40)
    t.eq(v.layout.mode, "gross")
    t.ok(contains_row(screen, "Westbahnhof - Passagierbahnhof"))
    t.ok(contains_row(screen, "Bereit"), "Betriebszustand als Text")
    t.ok(contains_row(screen, "Signale"), "Navigation")
    t.ok(contains_row(screen, "Info"))
    t.ok(not contains_row(screen, "Geheim"), "unsichtbare Seiten stehen nicht in der Navigation")
    t.ok(contains_row(screen, "> Signal 1"), "Auswahlmarkierung als Text")
    t.ok(contains_row(screen, "Seite 1/"))
    t.ok(contains_row(screen, "Neu"))
    t.ok(contains_row(screen, "Loeschen"))
    t.ok(contains_row(screen, "Name"))
  end },
  { "kompaktes Layout: Reiter in einer Zeile, Aktionen zwei Zeilen hoch", function()
    local v, screen = new_view(51, 19)
    t.eq(v.layout.mode, "kompakt")
    local rows = screen.rows()
    t.ok(rows[2]:find("Signale", 1, true) and rows[2]:find("Info", 1, true), "Reiter in Zeile 2: " .. rows[2])
    local a = v.touch.hit(3, v.layout.actions.y)
    t.eq(a.id, "act:neu")
    t.eq(v.touch.hit(3, v.layout.actions.y + 1).id, "act:neu", "zwei Zeilen hoch")
  end },
  { "zu kleine Flaeche: Statusansicht mit Hinweis, keine Beruehrung", function()
    local v, screen = new_view(40, 10)
    t.eq(v.layout.mode, "status")
    t.ok(contains_row(screen, "Bediencomputer verwenden"))
    t.ok(contains_row(screen, "Bereit"))
    t.eq(v.touch.hit(5, 5), nil)
    t.eq(v.handle({ "mouse_click", 1, 5, 5 }), false)
  end },
  { "Navigation per Beruehrung wechselt die Seite", function()
    local v, screen = new_view(100, 40)
    local info = v.touch.hit(3, 7)
    t.eq(info.id, "nav:info", "zweite Navigationstaste liegt in Zeile 7 bis 9")
    t.eq(v.handle({ "mouse_click", 1, 3, 7 }), true)
    v.render()
    t.eq(v.current_page().id, "info")
    t.ok(contains_row(screen, "Version 0.1.0"))
  end },
  { "Liste: Zeile antippen waehlt aus, Seiten wechseln, Auswahl bleibt sichtbar", function()
    local v, screen, log = new_view(51, 19)
    local row = v.touch.hit(5, v.layout.work.y + 3)
    t.ok(row.id:find("^sel:signale:"), row.id)
    v.handle({ "mouse_click", 1, 5, v.layout.work.y + 3 })
    v.render()
    t.eq(v.page_state("liste").list.index, 3)
    t.ok(contains_row(screen, "> Signal 3"))
    -- weiter blaettern
    local next_area
    for _, a in ipairs(v.touch.areas) do if a.id == "page:signale:next" then next_area = a end end
    t.ok(next_area, "Seitentaste vorhanden")
    v.handle({ "mouse_click", 1, next_area.x, next_area.y })
    v.render()
    t.ok(v.page_state("liste").list.index > 3)
    t.ok(contains_row(screen, "> Signal " .. v.page_state("liste").list.index), "Auswahl steht auf der sichtbaren Seite")
  end },
  { "gesperrte Taste sendet nichts und zeigt den Grund", function()
    local v, screen, log = new_view(100, 40)
    local area
    for _, a in ipairs(v.touch.areas) do if a.id == "act:loeschen" then area = a end end
    v.handle({ "mouse_click", 1, area.x + 1, area.y + 1 })
    v.render()
    t.eq(#log, 0)
    t.ok(contains_row(screen, "Erst ein Signal auswaehlen."))
  end },
  { "Aktion geht an die Seite, unbehandelte an den Kontext", function()
    local v, screen, log = new_view(100, 40)
    local area
    for _, a in ipairs(v.touch.areas) do if a.id == "act:neu" then area = a end end
    v.handle({ "mouse_click", 1, area.x + 1, area.y + 1 })
    t.eq(log[1], "act:neu")
    v.handle({ "key", KEY.escape })
    t.eq(log[2], "back")
    t.eq(log[3], "ctx:back", "die Seite behandelt 'back' nicht, also bekommt es der Kontext")
    v.set_page("info")
    v.handle({ "key", KEY.escape })
    t.eq(log[4], "ctx:back", "Seite ohne Behandlung: der Kontext bekommt es")
    v.set_page("liste")
    v.handle({ "key", KEY.tab })
    v.dispatch("act:neu")
    t.eq(log[5], "act:neu")
    t.eq(log[6], nil, "was die Seite behandelt, geht nicht noch an den Kontext")
  end },
  { "Tastatur: Tab wechselt den Fokus, Pfeile bewegen die Auswahl, Enter loest aus", function()
    local v, screen, log = new_view(100, 40)
    local first = v.focus_id
    v.handle({ "key", KEY.tab })
    v.render()
    t.ok(v.focus_id ~= first, "Fokus wandert")
    v.handle({ "key", KEY.down })
    v.handle({ "key", KEY.down })
    t.eq(v.page_state("liste").list.index, 3)
    v.handle({ "key", KEY.up })
    t.eq(v.page_state("liste").list.index, 2)
    v.handle({ "key", KEY.pageDown })
    v.render()
    t.ok(v.page_state("liste").list.index > 2)
    -- Enter auf dem Fokus
    v.focus_id = "act:neu"
    v.handle({ "key", KEY.enter })
    t.eq(log[#log], "act:neu")
  end },
  { "Eingabefeld: antippen, tippen, Rueckschritt, Enter", function()
    local v, screen, log = new_view(100, 40)
    local field
    for _, a in ipairs(v.touch.areas) do if a.id == "field:name" then field = a end end
    v.handle({ "mouse_click", 1, field.x + 1, field.y })
    v.render()
    t.eq(v.input_id, "name")
    for _, ch in ipairs({ "W", "e", "s", "t", "!" }) do v.handle({ "char", ch }) end
    v.handle({ "char", "x" })
    v.handle({ "key", KEY.backspace })
    v.render()
    t.eq(v.page_state("liste").field.value, "West", "'!' ist kein erlaubtes Zeichen, ein Rueckschritt entfernt das letzte")
    t.ok(contains_row(screen, "West_"), "Cursor sichtbar")
    v.handle({ "key", KEY.enter })
    t.eq(v.input_id, nil)
    t.eq(log[#log], "input:name")
    t.eq(v.handle({ "char", "a" }), false, "ohne Eingabefeld werden Zeichen nicht verschluckt")
  end },
  { "Feld mit altem Wert: erstes Zeichen oder Rueckschritt ersetzt ihn, danach wird normal geaendert", function()
    local v = new_view(100, 40)
    v.page_state("liste").field = { value = "Altwert" }
    v.render()
    v.dispatch("field:name")
    v.handle({ "key", KEY.backspace })
    t.eq(v.page_state("liste").field.value, "", "Rueckschritt auf frischem Feld loescht alles")
    v.dispatch("field:name")
    v.handle({ "char", "A" }); v.handle({ "char", "B" })
    t.eq(v.page_state("liste").field.value, "AB")
    v.handle({ "key", KEY.backspace })
    t.eq(v.page_state("liste").field.value, "A", "danach nur ein Zeichen")
  end },
  { "Aktionen der festen Gruppe stehen rechts", function()
    local log = {}
    local screen = screenlib.new(100, 40)
    local pages = { { id = "p", title = "P", render = function() end, actions = function()
      return { { id = "links", label = "Links" }, { id = "rechts", label = "Rechts", side = "rechts" } }
    end } }
    local v = viewlib.new({ target = screen, ctx = ctx(log), pages = pages })
    v.render()
    local links, rechts
    for _, a in ipairs(v.touch.areas) do
      if a.id == "act:links" then links = a end
      if a.id == "act:rechts" then rechts = a end
    end
    t.ok(links.x < 30, "links beginnt links")
    t.eq(rechts.x + rechts.w, v.layout.actions.x + v.layout.actions.w - 1, "rechts endet am rechten Rand")
  end },
  { "Eingabe wird mit Escape abgebrochen, Tab und Pfeile stoeren nicht", function()
    local v = new_view(100, 40)
    v.dispatch("field:name")
    v.handle({ "key", KEY.tab })
    t.eq(v.input_id, "name")
    v.handle({ "key", KEY.escape })
    t.eq(v.input_id, nil)
  end },
  { "Groessenaenderung: Layout und Klickbereiche neu, Eingaben bleiben", function()
    local log = {}
    local screen = screenlib.new(100, 40)
    local v = viewlib.new({ target = screen, ctx = ctx(log), pages = make_pages(log) })
    v.render()
    v.page_state("liste").list.index = 7
    v.page_state("liste").field.value = "Rest"
    t.eq(v.layout.mode, "gross")
    local big_actions = v.layout.actions.y
    -- der Monitor wird verkleinert
    local small = screenlib.new(51, 19)
    v.target = small
    v.render()
    t.eq(v.layout.mode, "kompakt")
    t.ok(v.layout.actions.y ~= big_actions)
    t.eq(v.page_state("liste").list.index, 7, "Auswahl bleibt")
    t.eq(v.page_state("liste").field.value, "Rest", "Eingabe bleibt")
    t.ok(contains_row(small, "Westbahnhof"))
    t.eq(v.touch.hit(3, v.layout.actions.y).id, "act:neu")
  end },
  { "mehrere Ansichten: Monitor-Beruehrung nur fuer den richtigen Monitor, Mausklick nur am Terminal", function()
    local log = {}
    local pages = make_pages(log)
    local term = screenlib.new(51, 19)
    local mon = screenlib.new(100, 40)
    local vt = viewlib.new({ target = term, ctx = ctx(log), pages = pages })
    local vm = viewlib.new({ target = mon, name = "monitor_0", ctx = ctx(log), pages = make_pages(log) })
    vt.render(); vm.render()
    t.eq(vm.handle({ "mouse_click", 1, 3, 7 }), false)
    t.eq(vt.handle({ "monitor_touch", "monitor_0", 3, 7 }), false)
    t.eq(vm.handle({ "monitor_touch", "monitor_1", 3, 7 }), false)
    t.eq(vm.handle({ "monitor_touch", "monitor_0", 3, 7 }), true)
    vm.render()
    t.eq(vm.current_page().id, "info")
    t.eq(vt.current_page().id, "liste", "andere Ansicht unveraendert")
  end },
  { "Klick ins Leere wird nicht verarbeitet", function()
    local v = new_view(100, 40)
    t.eq(v.handle({ "mouse_click", 1, 1, 1 }), false)
    t.eq(v.handle({ "unbekannt" }), false)
  end },
  { "Monochrom: lesbar, Auswahlmarkierung und Texte bleiben", function()
    local v, screen = new_view(51, 19, { colour = false })
    t.ok(contains_row(screen, "> Signal 1"))
    t.ok(contains_row(screen, "Westbahnhof"))
    local _, fg, bg = screen.cell(3, 2)
    t.ok(fg ~= bg)
  end },
  { "Farbgeraet bekommt die Palette", function()
    local v, screen = new_view(51, 19)
    t.ok(screen.palette[1], "Palette gesetzt")
    local mono_view, mono_screen = new_view(51, 19, { colour = false })
    t.eq(next(mono_screen.palette), nil)
  end },
  { "Textumbruch", function()
    local lines = W.wrap("Dies ist ein langer Hinweistext fuer die Bedienung", 20)
    for _, l in ipairs(lines) do t.ok(#l <= 20, l) end
    t.eq(table.concat(lines, " "), "Dies ist ein langer Hinweistext fuer die Bedienung")
    t.eq(#W.wrap("", 10), 1)
    local long = W.wrap("Supercalifragilisticexpialidocious", 10)
    t.eq(long[1], "Supercalif")
    t.eq(#W.wrap("a\nb\nc", 10), 3)
  end },
  { "Seite mit 1000 Eintraegen bleibt bedienbar", function()
    local items = {}
    for i = 1, 1000 do items[i] = { text = "Eintrag " .. i } end
    local log = {}
    local screen = screenlib.new(51, 19)
    local pages = { { id = "x", title = "X", render = function(v, rect)
      local st = v.page_state("x"); st.list = st.list or { index = 1 }
      W.list(v, "l", rect, items, st.list)
    end } }
    local v = viewlib.new({ target = screen, ctx = ctx(log), pages = pages })
    v.render()
    for _ = 1, 30 do v.handle({ "key", KEY.pageDown }); v.render() end
    t.ok(v.page_state("x").list.index > 100)
    for _ = 1, 500 do v.handle({ "key", KEY.down }) end
    v.render()
    t.ok(contains_row(screen, "> Eintrag " .. v.page_state("x").list.index))
  end },
}
