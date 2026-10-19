--[[
Purpose: Builds the whole network plan from the description of a network (src/setup/layout.lua): blocks with their signals and detectors,
  switch ladders at stations with several platforms, one route for every pair of platforms along a line, stations, depots, trains with their
  service plans, the panel. What a person would otherwise type by hand into configs/network.json, with names that follow one rule.
Public API:
  build(layout) -> plan, meta | nil, errors
    plan: the table of configs/network.json (valid: shared/validate.lua, and small enough to be handed out to the computers)
    meta: { computers = list of { id, role, what, where } for the build list, stats = { computers, blocks, routes, signals, sensors, switches },
            create_names = list of { id, name, kind } (the names the Create station blocks must carry), notes = list of sentences }
    errors: list of German sentences
Model (the one the dispatcher works with, docs/NETZ_BAUEN.md):
  * A line is one-way track: the description gives a line "both ways" as two tracks, each with its own blocks, signals (IN / OUT) and detector per block.
  * A route runs from a platform (or depot track) of one station along the blocks of the track to a platform of the next. The platform itself is no block:
    the train waits in front of the entry signal of the first block, and arrives behind the last block.
  * A station with several platforms gets, per platform, an approach block that carries the positions of a ladder of p - 1 switches (SW-<code>-ARR-m)
    and a departure block; with several tracks out, a ladder of q - 1 switches (SW-<code>-DEP-m) whose positions sit on the first block of each track.
  * Every route holds the conflict group of the platforms it uses (PLAT-<station>-<platform>): two routes into or out of one platform exclude each other.
Names: <code> is the id of a station without a leading "ST-" (ST-A -> A). Blocks B-<from>-<to>-<n>, signals SIG-<block>-IN / -OUT, detectors SEN-<block>,
  routes R-<from>-<to> (R-<from>.<k>-<to>.<j> when a platform has to be named).
]]

local netplan = require("src.setup.netplan")
local validate = require("src.shared.validate")

local plan_builder = {}

local MAX_ID = 32
local MAX_PLAN_BYTES = 150000
local PRIORITY = { passenger = 10, mixed = 8, freight = 5, depot = 5 }
local PAGES = { "overview", "trains", "stations", "depots", "service_plans", "manual", "diagnostics", "audit", "maintenance" }

local function code_of(id)
  return (id:gsub("^[Ss][Tt]%-", ""))
end

local function join(list, separator) return table.concat(list, separator or ", ") end

-- the positions that select item `index` of `count` with a ladder of count - 1 switches: switch m diverges for every item behind it
local function ladder(prefix, index, count)
  local out = {}
  for m = 1, count - 1 do
    if m < index then out[#out + 1] = { id = prefix .. m, position = "DIVERGING" }
    elseif m == index then out[#out + 1] = { id = prefix .. m, position = "STRAIGHT" } end
  end
  return out
end

function plan_builder.build(l)
  local errors = {}
  local function fail(text) errors[#errors + 1] = text end

  local plan = { v = 1, channel = l.channel, master_id = l.master_id, blocks = {}, routes = {}, nodes = {} }
  local meta = { computers = {}, stats = {}, create_names = {}, notes = {} }

  -- the ends: stations and depots in the order of the description
  local ends, order = {}, {}
  local codes = {}
  local function add_end(item, kind, berths)
    local code = code_of(item.id)
    if codes[code] then fail("Die Kurzform " .. code .. " kommt bei " .. codes[code] .. " und " .. item.id .. " doppelt vor (Bahnhof-IDs unterscheiden sich nach \"ST-\" nicht)."); return end
    codes[code] = item.id
    ends[item.id] = { id = item.id, code = code, name = item.name, kind = kind, type = item.type, berths = berths, in_tracks = {}, out_tracks = {} }
    order[#order + 1] = item.id
  end
  for _, s in ipairs(l.stations) do add_end(s, "station", s.platforms) end
  for _, d in ipairs(l.depots) do add_end(d, "depot", d.tracks) end
  if #errors > 0 then return nil, errors end

  local function berth_name(e, k) return (e.kind == "station" and "P" or "D") .. k end

  -- directed tracks in the order of the lines
  local tracks = {}
  for _, line in ipairs(l.lines) do
    local function add(from, to)
      local track = { from = ends[from], to = ends[to], blocks = line.blocks, kind = line.kind, tag = ends[from].code .. "-" .. ends[to].code, line_blocks = {} }
      tracks[#tracks + 1] = track
      track.from.out_tracks[#track.from.out_tracks + 1] = track
      track.to.in_tracks[#track.to.in_tracks + 1] = track
    end
    add(line.from, line.to)
    if not line.oneway then add(line.to, line.from) end
  end

  -- ── blocks, signals, detectors ────────────────────────────────────────────────────────────────────────────────────
  local nodes_signal, nodes_sensor, nodes_switch = {}, {}, {}
  local seen_ids = {}
  local function claim(id)
    if seen_ids[id] then fail("Die ID " .. id .. " entsteht doppelt: die Namen der Bahnhoefe muessen sich unterscheiden."); return false end
    if #id > MAX_ID then fail("Die ID " .. id .. " ist zu lang (hoechstens " .. MAX_ID .. " Zeichen): kuerzere Bahnhof-IDs waehlen."); return false end
    seen_ids[id] = true
    return true
  end

  local function new_block(base, where, switches)
    local id = "B-" .. base
    local block = { id = id, entry_signal = "SIG-" .. base .. "-IN", exit_signal = "SIG-" .. base .. "-OUT", sensors = { "SEN-" .. base }, switches = switches or {} }
    plan.blocks[#plan.blocks + 1] = block
    if claim(id) then
      nodes_signal[#nodes_signal + 1] = { id = block.entry_signal, where = where .. ", Einfahrtsignal" }
      nodes_signal[#nodes_signal + 1] = { id = block.exit_signal, where = where .. ", Ausfahrtsignal" }
      nodes_sensor[#nodes_sensor + 1] = { id = block.sensors[1], where = where .. ", Train Observer" }
      claim(block.entry_signal); claim(block.exit_signal); claim(block.sensors[1])
    end
    return block
  end

  for _, track in ipairs(tracks) do
    for i = 1, track.blocks do
      track.line_blocks[i] = new_block(track.tag .. "-" .. i, "Strecke " .. track.from.id .. " -> " .. track.to.id .. ", Block " .. i .. " von " .. track.blocks)
    end
  end

  -- Arrival throat of an end with several berths: one approach block per berth, shared by every arriving track, with the positions of the ladder
  -- that leads to that berth. Departure: one block per berth (the train waits in front of its entry signal); the ladder that selects the outgoing
  -- track sits on the first line block of that track, which only routes towards that track use.
  local function arrival_part(e, k)
    if e.berths < 2 then return nil end
    e.arrival = e.arrival or {}
    if not e.arrival[k] then
      e.arrival[k] = new_block(e.code .. "-ARR-" .. k, (e.kind == "station" and "Bahnhof " or "Depot ") .. e.id .. ", Einfahrt zu " .. (e.kind == "station" and "Bahnsteig " or "Gleis ") .. k,
        ladder("SW-" .. e.code .. "-ARR-", k, e.berths))
    end
    return e.arrival[k]
  end
  local function departure_part(e, k)
    if e.berths < 2 then return nil end
    e.departure = e.departure or {}
    if not e.departure[k] then
      e.departure[k] = new_block(e.code .. "-DEP-" .. k, (e.kind == "station" and "Bahnhof " or "Depot ") .. e.id .. ", Ausfahrt von " .. (e.kind == "station" and "Bahnsteig " or "Gleis ") .. k)
    end
    return e.departure[k]
  end
  for _, track in ipairs(tracks) do
    local index = 1
    for i, t in ipairs(track.from.out_tracks) do if t == track then index = i end end
    for _, def in ipairs(ladder("SW-" .. track.from.code .. "-DEP-", index, #track.from.out_tracks)) do
      local first = track.line_blocks[1]
      first.switches[#first.switches + 1] = def
    end
  end

  -- the switch computers (one ladder per end and side)
  for _, id in ipairs(order) do
    local e = ends[id]
    local kind_word = e.kind == "station" and "Bahnsteig" or "Gleis"
    for m = 1, e.berths - 1 do
      local sw = "SW-" .. e.code .. "-ARR-" .. m
      if #e.in_tracks > 0 and claim(sw) then nodes_switch[#nodes_switch + 1] = { id = sw, where = (e.kind == "station" and "Bahnhof " or "Depot ") .. e.id .. ", Einfahrt, Stufe " .. m .. " von " .. (e.berths - 1) .. ": geradeaus zu " .. kind_word .. " " .. m .. ", Abzweig zu den weiteren" } end
    end
    for m = 1, #e.out_tracks - 1 do
      local sw = "SW-" .. e.code .. "-DEP-" .. m
      if claim(sw) then nodes_switch[#nodes_switch + 1] = { id = sw, where = (e.kind == "station" and "Bahnhof " or "Depot ") .. e.id .. ", Ausfahrt, Stufe " .. m .. " von " .. (#e.out_tracks - 1) .. ": geradeaus zur Strecke nach " .. e.out_tracks[m].to.id .. ", Abzweig zu den weiteren" } end
    end
  end

  -- ── routes ─────────────────────────────────────────────────────────────────────────────────────────────────────────
  local routes_by_key = {}
  local function route_id(a, k, b, j)
    if a.berths == 1 and b.berths == 1 then return "R-" .. a.code .. "-" .. b.code end
    return "R-" .. a.code .. "." .. k .. "-" .. b.code .. "." .. j
  end
  for _, track in ipairs(tracks) do
    local a, b = track.from, track.to
    for k = 1, a.berths do
      for j = 1, b.berths do
        local blocks = {}
        local dep = departure_part(a, k)
        if dep then blocks[#blocks + 1] = dep.id end
        for _, block in ipairs(track.line_blocks) do blocks[#blocks + 1] = block.id end
        local arr = arrival_part(b, j)
        if arr then blocks[#blocks + 1] = arr.id end
        local route = {
          id = route_id(a, k, b, j), from = a.id, to = b.id, blocks = blocks, priority = PRIORITY[track.kind] or 5, kind = track.kind,
          conflict_groups = { "PLAT-" .. a.id .. "-" .. berth_name(a, k), "PLAT-" .. b.id .. "-" .. berth_name(b, j) },
        }
        plan.routes[#plan.routes + 1] = route
        routes_by_key[a.id .. "/" .. k .. ">" .. b.id .. "/" .. j] = route
      end
    end
  end

  -- ── nodes ──────────────────────────────────────────────────────────────────────────────────────────────────────────
  local function describe(id, role, what, where) meta.computers[#meta.computers + 1] = { id = id, role = role, what = what, where = where or "" } end
  local function add_node(entry, what, where)
    plan.nodes[#plan.nodes + 1] = entry
    describe(entry.id, entry.role, what, where)
  end

  add_node({ id = l.master_id, role = "master" }, "Master-Computer mit einem Monitor (Bedienung und Anzeige des ganzen Netzes)", "Zentrale")

  for _, t in ipairs(l.trains) do
    add_node({ id = t.id, role = "train", train_id = t.id, display_name = t.name, service_plan = "SP-" .. t.id, create_station = "Create_Station_0", schedule_station = "Create_Station_0" },
      "Bordcomputer im Zug \"" .. t.name .. "\" (mit dem Create-Bahnhofsblock als Peripherie)", "Zug " .. t.name .. ": " .. (function()
        local names = {}
        for _, stop in ipairs(t.stops) do names[#names + 1] = stop.id end
        return join(names, " - ")
      end)())
  end

  if l.panel then
    local actions = {}
    for _, t in ipairs(l.trains) do
      actions[#actions + 1] = { label = "Halt " .. t.id, action = "hold_train", train_id = t.id }
      actions[#actions + 1] = { label = "Notstopp " .. t.id, action = "emergency_stop", train_id = t.id }
    end
    add_node({ id = "PANEL-1", role = "panel", display_name = "Hauptpanel", refresh_seconds = 2, pages = PAGES, manual_actions = actions }, "Bedien-Monitor (Panel) mit eigenem Computer", "Zentrale oder wo bedient wird")
  end

  for _, id in ipairs(order) do
    local e = ends[id]
    if e.kind == "station" then
      local platforms = {}
      for k = 1, e.berths do platforms[k] = { id = berth_name(e, k), kind = e.type, dwell_seconds = 10 } end
      add_node({ id = e.id, role = "station", station_type = e.type, display_name = e.name, create_station_name = e.name, platforms = platforms },
        "Computer am Create-Bahnhofsblock \"" .. e.name .. "\" (" .. e.berths .. " Bahnsteig" .. (e.berths == 1 and "" or "e") .. ")", "Bahnhof " .. e.id)
      meta.create_names[#meta.create_names + 1] = { id = e.id, name = e.name, kind = "station" }
    else
      local list = {}
      for k = 1, e.berths do list[k] = { id = berth_name(e, k), kind = "storage", ready_after_seconds = 5 } end
      add_node({ id = e.id, role = "depot", depot_type = "mixed", display_name = e.name, tracks = list },
        "Computer am Create-Bahnhofsblock \"" .. e.name .. "\" (" .. e.berths .. " Gleis" .. (e.berths == 1 and "" or "e") .. ")", "Depot " .. e.id)
      meta.create_names[#meta.create_names + 1] = { id = e.id, name = e.name, kind = "depot" }
    end
  end

  local function with_defaults(entry, defaults)
    for key, value in pairs(defaults) do entry[key] = value end
    return entry
  end
  table.sort(nodes_signal, function(x, y) return x.id < y.id end)
  table.sort(nodes_sensor, function(x, y) return x.id < y.id end)
  table.sort(nodes_switch, function(x, y) return x.id < y.id end)
  for _, s in ipairs(nodes_signal) do add_node(with_defaults({ id = s.id, role = "signal" }, l.defaults.signal), "Computer am Create-Signal", s.where) end
  for _, s in ipairs(nodes_sensor) do add_node(with_defaults({ id = s.id, role = "sensor" }, l.defaults.sensor), "Computer am Train Observer", s.where) end
  for _, s in ipairs(nodes_switch) do add_node(with_defaults({ id = s.id, role = "switch" }, l.defaults.switch), "Computer an der Weiche (Redstone-Ausgang)", s.where) end

  -- ── trains: service plans ──────────────────────────────────────────────────────────────────────────────────────────
  if #l.trains > 0 then
    plan.service_plans = {}
    for _, t in ipairs(l.trains) do
      local stops = {}
      for i = 1, #t.stops - 1 do
        local a, b = ends[t.stops[i].id], ends[t.stops[i + 1].id]
        local route = routes_by_key[a.id .. "/" .. t.stops[i].platform .. ">" .. b.id .. "/" .. t.stops[i + 1].platform]
        if not route then
          fail("Der Zug " .. t.id .. " faehrt von " .. a.id .. " nach " .. b.id .. ", aber diese Strecke gibt es nicht.")
        else
          stops[#stops + 1] = { from = a.id, to = b.id, route_id = route.id, kind = route.kind, dwell_seconds = a.kind == "depot" and 0 or t.dwell, create_destination = b.name }
        end
      end
      plan.service_plans[#plan.service_plans + 1] = { id = "SP-" .. t.id, train_id = t.id, display_name = t.name, repeat_plan = t.repeat_plan, stops = stops }
    end
  end

  if #errors > 0 then return nil, errors end

  -- ── checks of the result ───────────────────────────────────────────────────────────────────────────────────────────
  local ok, problems = validate.validate_config(plan)
  if not ok then
    for i = 1, math.min(#problems, 5) do fail("Interner Fehler im erzeugten Plan: " .. problems[i]) end
    return nil, errors
  end
  local size = #netplan.encode(plan)
  if size > MAX_PLAN_BYTES then
    return nil, { "Der Plan ist zu gross (" .. size .. " Byte, hoechstens " .. MAX_PLAN_BYTES .. "): die Computer holen ihn in Teilen vom Master und schaffen nicht mehr. Weniger Bloecke je Strecke oder weniger Bahnhoefe." }
  end

  local counts = { signals = #nodes_signal, sensors = #nodes_sensor, switches = #nodes_switch }
  meta.stats = { computers = #plan.nodes, blocks = #plan.blocks, routes = #plan.routes, signals = counts.signals, sensors = counts.sensors, switches = counts.switches, bytes = size,
    stations = #l.stations, depots = #l.depots, trains = #l.trains }
  meta.notes = {
    "Jede Strecke ist in beide Richtungen zwei getrennte Gleise mit eigenen Bloecken, Signalen und Meldern (\"einrichtung\" baut nur eine Richtung).",
    "Der Bahnsteig ist kein Block: der Zug wartet vor dem Einfahrtsignal des ersten Blocks und kommt hinter dem letzten Block an.",
  }
  return plan, meta
end

return plan_builder
