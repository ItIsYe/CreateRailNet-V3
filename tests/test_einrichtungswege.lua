--[[
Purpose: Keine Sackgassen im Einrichtungsassistenten: jede Rolle (Bahnhof, Bahnhof plus Anmeldung, Anmeldung allein, Leitstelle) wird frisch eingerichtet und danach mit "Einrichtung aendern" noch einmal durchlaufen, bis zum Aktivieren; ein Stillstand (Weiter ohne Wirkung und ohne behebbaren Hinweis) ist ein Fehler.
]]

local t = dofile("tests/lib/t.lua")
local H = dofile("tests/lib/harness.lua")
local model = require("setup.model")

local function screen(d) local ok, s = pcall(function() return d.node.setup.session().screen end); return ok and s or nil end
local function wiz_open(d) local ok, w = pcall(function() return d.node.setup.session().wiz end); return ok and w ~= nil end
local function rows(d, v) return v.target.rows() end
local function has_area(d, v, id) return d.area(v, id) ~= nil end
local function try_tap(d, v, id) if has_area(d, v, id) then d.tap(v, id) return true end return false end
local function marked_row(d, v, text)
  for _, r in ipairs(rows(d, v)) do
    if r:find(text, 1, true) and (r:find("[x]", 1, true) or r:find("(o)", 1, true)) then return true end
  end
  return false
end
local function find_row(d, v, text)
  for _, r in ipairs(rows(d, v)) do if r:find(text, 1, true) then return r end end
end
local function ensure_row(d, v, list, text)
  if find_row(d, v, text) and not marked_row(d, v, text) then d.tap_row(v, list, text) end
end

local function track_from_hint(d, v, hint)
  -- "Gleis 2 hat kein Signal." / "Gleis 1 hat keinen Bahnhof."
  local n = tostring(hint or ""):match("Gleis (%d+)")
  return n and tonumber(n)
end

local function ctx_new(h, d, v, opts)
  return { h = h, d = d, v = v, opts = opts or {}, log = {}, stalls = {} }
end

local function step_wait(c, n) c.h.step(n or 2); c.d.node.render() end

-- Reaktion auf eine Sperre, gesteuert vom Hinweis; liefert true, wenn etwas getan wurde
local function fix(c, sc, hint)
  local d, v, o = c.d, c.v, c.opts
  hint = tostring(hint or "")
  if sc == "4.gleise" then
    local label = hint:match("^(.-) hat ") or hint:match("^(.-) braucht ")
    if label then label = label:gsub("^Einfahrtsgleis ", "") end
    if label then
      local ok = pcall(d.tap_row, v, "gleise", label)
      if ok then d.tap(v, "act:bearbeiten"); c.sub = tonumber(label:match("(%d+)")) or c.sub return true end
    end
  elseif sc == "5.test" then
    if try_tap(d, v, "act:alle_pruefen") then return true end
  elseif sc == "4.zuordnung" then
    local n = tostring(hint):match("^(.-):")
    for i, r in ipairs(d.node.setup.session().wiz.guided_rows()) do
      if hint:find(r.name, 1, true) then
        d.tap(v, "sel:zuordnung:" .. i)
        if hint:find("Signal fehlt", 1, true) then
          if try_tap(d, v, "act:signal_waehlen") then d.tap(v, "sel:signal:1") return true end
        else
          if try_tap(d, v, "act:signal_details") then return true end
        end
      end
    end
  elseif sc == "4.z.detail" then
    local did = false
    if find_row(d, v, "WIRKRICHTUNG FEHLT") then
      for i = 1, 6 do
        if find_row(d, v, "WIRKRICHTUNG FEHLT") and has_area(d, v, "sel:detail:" .. i) then
          d.tap(v, "sel:detail:" .. i); try_tap(d, v, "act:d_richtung"); did = true
        end
      end
    end
    -- Knoteneinfahrt: letztes Signal als Einfahrt markieren
    if has_area(d, v, "act:d_einfahrt") then
      for i = 6, 1, -1 do
        if has_area(d, v, "sel:detail:" .. i) then d.tap(v, "sel:detail:" .. i); d.tap(v, "act:d_einfahrt"); did = true break end
      end
    end
    if find_row(d, v, "Reihenf. bestaet.") and try_tap(d, v, "act:d_reihenfolge") then did = true end
    return did
  elseif sc == "4.anmeldung" then
    if has_area(d, v, "sel:anmeldung:1") then d.tap(v, "sel:anmeldung:1") return true end
  elseif sc == "4.g.name" then
    local list, pat = "bahnhof", "Create_Station_%S+"
    -- ein Geraet, das schon zu einem anderen Gleis gehoert, wird abgelehnt: das naechste freie probieren
    for _, r in ipairs(rows(d, v)) do
      local nm = r:match("%( %) (" .. pat .. ")")
      if nm then
        d.tap_row(v, list, nm)
        if marked_row(d, v, nm) then return true end
      end
    end
    return false
  end  return false
end

-- Vorarbeiten je Bildschirm (Auswahl, die ein Mensch ohnehin trifft)
local function prep(c, sc)
  local d, v, o = c.d, c.v, c.opts
  if sc == "1.modus" then
    ensure_row(d, v, "modus", o.create and "Erste Leitstelle" or "Diesem bestehenden")
  elseif sc == "1.netzwahl" then
    local any = false
    for _, r in ipairs(rows(d, v)) do if r:find("(o)", 1, true) then any = true end end
    if not any and has_area(d, v, "sel:netzwahl:1") then d.tap(v, "sel:netzwahl:1") end
  elseif sc == "1.netz" then d.type(v, "netz", "Testnetz")
  elseif sc == "1.zentrale" then d.type(v, "zentrale", "hauptstelle")
  elseif sc == "2.rollen" then
    for _, role in ipairs(o.roles or {}) do ensure_row(d, v, "rollen", model.ROLE_TEXT[role]) end
  elseif sc == "2.name" then d.type(v, "name", o.name or "Testhof")
  elseif sc == "2.kennung" then
    step_wait(c, 1)
  elseif sc == "2.station" then
    if has_area(d, v, "sel:station_wahl:1") then d.tap(v, "sel:station_wahl:1") end
    step_wait(c, 4)
  elseif sc == "3.geraete" then
    for _, name in ipairs(o.devices or {}) do ensure_row(d, v, "geraete", name) end
  elseif sc == "4.gleise" then
    -- Gleise legt der Assistent nicht vor: eines nach dem anderen anlegen (Name und Bahnhof stehen auf einem Bildschirm)
    local made = #d.node.setup.session().wiz.tracks()
    if made < (o.track_count or 2) then
      c.sub = made + 1
      d.tap(v, "act:neues_gleis")
    end
  elseif sc == "4.g.name" then
    local n = c.sub or 1
    local name = (o.station_prefix or "Create_Station_") .. n
    if find_row(d, v, name) then ensure_row(d, v, "bahnhof", name) else
      -- irgendeine freie
      for _, r in ipairs(rows(d, v)) do local nm = r:match("%( %) (%S+)") if nm then d.tap_row(v, "bahnhof", nm) break end end
    end
  elseif sc == "4.g.signale" then
    if o.signal_roles then
      local n = c.sub or 1
      for _, r in ipairs(rows(d, v)) do
        local nm = r:match("%[ %] (Create_Signal_(%d+))")
        local num = r:match("%[ %] Create_Signal_(%d+)")
        if num and ((o.signals_on_every_track and tonumber(num) == n) or (not o.signals_on_every_track and n == 1)) then d.tap_row(v, "signale", "Create_Signal_" .. num) end
      end
    end
  elseif sc == "4.anmeldung" then
    if has_area(d, v, "sel:anmeldung:1") and not find_row(d, v, "[x]") then d.tap(v, "sel:anmeldung:1") end
  end
end

-- Lauf bis zum Aktivieren; liefert ok, Bericht
local function drive(c, label)
  local d, v = c.d, c.v
  local path = {}
  for i = 1, 160 do
    local sc = screen(d)
    if not wiz_open(d) then return true, path end
    if sc == "6.fertig" then
      path[#path + 1] = sc
      d.tap(v, "act:speichern")
      step_wait(c, 3)
      local ok = d.node.config and d.node.config.status == "aktiv"
      return ok, path, ok and nil or ("Speichern ohne Erfolg: " .. tostring(v.hint))
    end
    if sc == "5.pruefen" then
      path[#path + 1] = sc
      d.tap(v, "act:pruefen")
      for _ = 1, 60 do c.h.step(1) d.node.render() if not wiz_open(d) then break end end
      if wiz_open(d) then return false, path, "5.pruefen kommt nicht zum Ende: " .. tostring(v.hint) .. "\n" .. d.text(v) end
      return true, path
    end
    if path[#path] ~= sc then path[#path + 1] = sc end
    prep(c, sc)
    local before = sc .. "|" .. d.text(v)
    d.tap(v, "act:weiter")
    step_wait(c, 2)
    if (screen(d) or "") .. "|" .. d.text(v) == before or screen(d) == sc then
      -- gesperrt oder gleicher Bildschirm: Hinweis lesen, beheben
      local hint = v.hint
      local did = fix(c, sc, hint)
      if not did then
        return false, path, string.format("Stillstand auf %s, Hinweis: %q\n%s", sc, tostring(hint), d.text(v))
      end
      step_wait(c, 2)
      c.sub_guard = (c.sub_guard or 0) + 1
      if c.sub_guard > 60 then return false, path, "Schleife auf " .. tostring(screen(d)) end
    end
  end
  return false, path, "zu viele Schritte (Schleife?) auf " .. tostring(screen(d))
end

---------------------------------------------------------------------------------------------------------------------------------------------
-- Szenarien
---------------------------------------------------------------------------------------------------------------------------------------------
local function leitstelle(h, f)
  local z = h.add_node({ id = "hauptstelle", roles = { "zentrale" }, tracks = {} })
  local netz = z.node.roles.zentrale.netz
  f(netz, z.node.roles.zentrale)
  return z, netz
end

local function node(h, o)
  local stations = {}
  for i = 1, o.stations or 0 do stations[i] = "Hof " .. i end
  local d = h.add_blank({ id = "neu", stations = stations, installed = o.installed })
  for i = 1, o.signals or 0 do d.world.add_signal("Create_Signal_" .. i) end
  for i = 1, o.observers or 0 do d.world.add_observer("Create_Observer_" .. i) end
  d.restart()
  h.step(1)
  return d
end

local function start_page(d)
  local v = d.view()
  v.set_page("einrichtung")
  d.node.render()
  d.tap(v, "act:start")
  return v
end

local SC = {}
local function sc(name, build) SC[#SC + 1] = { name = name, build = build } end

local function area_station(netz) end

sc("Bahnhof", function()
  local h = H.new(); local z, netz = leitstelle(h, area_station)
  return h, node(h, { stations = 3, signals = 0 }), { roles = { "bahnhof" }, devices = { "Create_Station_1", "Create_Station_2", "Create_Station_3" } }
end)
sc("Bahnhof + Anmeldung", function()
  local h = H.new(); local z, netz = leitstelle(h, area_station)
  return h, node(h, { stations = 3 }), { roles = { "bahnhof", "anmeldung" }, devices = { "Create_Station_1", "Create_Station_2", "Create_Station_3" } }
end)
sc("Anmeldung allein (Bahnhof aus dem Verzeichnis)", function()
  local h = H.new(); local z, netz = leitstelle(h, function(n, zentrale) area_station(n); assert(zentrale.stations.set("Westbahnhof", { "West 1" })) end)
  return h, node(h, { stations = 2 }), { roles = { "anmeldung" }, devices = { "Create_Station_1" } }
end)

local function run(s)
  local h, d, opts = s.build()
  local v = start_page(d)
  local ok, path, err = drive(ctx_new(h, d, v, opts), s.name)
  t.ok(ok, "frisch: " .. s.name .. "\n  Weg: " .. table.concat(path or {}, " > ") .. "\n  " .. tostring(err))
  -- Einrichtung aendern
  h.step(40)
  d.node.render()
  local v2 = d.view(); v2.set_page("einrichtung"); d.node.render()
  t.ok(d.area(v2, "act:start"), "aendern: " .. s.name .. ": kein Knopf Einrichtung aendern")
  d.tap(v2, "act:start")
  local ok2, path2, err2 = drive(ctx_new(h, d, v2, { name = opts.name }), s.name)
  t.ok(ok2, "aendern: " .. s.name .. "\n  Weg: " .. table.concat(path2 or {}, " > ") .. "\n  " .. tostring(err2))
  t.eq(d.node.config.status, "aktiv")
end

local cases = {}
for _, s in ipairs(SC) do
  cases[#cases + 1] = { s.name .. ": frisch einrichten und aendern, ohne Stillstand", function() run(s) end }
end

-- Leitstelle: erste Leitstelle erstellen, danach aendern
cases[#cases + 1] = { "Leitstelle (erste): erstellen und aendern, ohne Stillstand", function()
  local h = H.new()
  local d = h.add_blank({ id = "z1" }); h.step(1)
  local v = d.view(); v.set_page("einrichtung"); d.tap(v, "act:start")
  local c = ctx_new(h, d, v, { create = true, name = "Leitstelle" })
  local ok, path, err = drive(c, "Leitstelle")
  t.ok(ok, "frisch: " .. tostring(err))
  h.step(20)
  local v2 = d.view(); v2.set_page("einrichtung"); d.node.render()
  d.tap(v2, "act:start")
  local ok2, path2, err2 = drive(ctx_new(h, d, v2, { create = true, name = "Leitstelle" }), "Leitstelle")
  t.ok(ok2, "aendern: " .. tostring(err2))
end }

return cases
