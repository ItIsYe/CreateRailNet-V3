--[[
Purpose: Logische Bahnhoefe mit mehreren Haltegleisen (Konzept 10.1) und die Wahl des Zielgleises: bevorzugtes Gleis zuerst, dann die Alternativen, jeweils nur wenn es erreichbar, frei, nicht zugewiesen, nicht gesperrt und lang genug ist. Das Ziel wird vor der Fahrplanuebergabe festgelegt und danach nicht mehr getauscht.
API: stations.new{ store, path } -> s; s.set(name, mitglieder) -> ok, fehler; s.remove(name); s.get(name); s.list(); s.candidates(name) -> Liste von Create-Namen (Gruppe: ihre Mitglieder in Rangfolge, sonst der Name selbst); s.group_of(create_name); stations.choose(candidates, info) -> create_name oder nil, Gruende
Notes: Mitglieder sind Create-Bahnhofsnamen in Rangfolge (erster = bevorzugt). Ein Create-Bahnhof gehoert hoechstens zu einer Gruppe. info(name) liefert { problem = Text oder nil }; die Pruefungen selbst (Erreichbarkeit, Belegung, Zuweisung, Sperre, Laenge) liegen bei der Leitstelle, damit hier nichts geraten wird.
]]

local M = {}

function M.new(opts)
  local s = {}
  local data = opts.store.load(opts.path) or { groups = {} }
  data.groups = data.groups or {}

  local function save() return opts.store.save(opts.path, data) end

  function s.group_of(create_name)
    for name, g in pairs(data.groups) do
      for _, member in ipairs(g.members) do if member == create_name then return name end end
    end
    return nil
  end

  function s.set(name, members)
    if type(name) ~= "string" or name == "" then return nil, "Der Bahnhof braucht einen Namen." end
    if type(members) ~= "table" or #members == 0 then return nil, "Der Bahnhof braucht mindestens ein Gleis (Create-Bahnhofsname)." end
    local seen = {}
    for _, member in ipairs(members) do
      if type(member) ~= "string" or member == "" then return nil, "Ein Gleisname ist leer." end
      if seen[member] then return nil, "Das Gleis " .. member .. " steht doppelt in der Liste." end
      seen[member] = true
      local other = s.group_of(member)
      if other and other ~= name then return nil, "Das Gleis " .. member .. " gehoert schon zum Bahnhof " .. other .. "." end
    end
    if seen[name] and #members > 1 then return nil, "Der Bahnhofsname darf nicht zugleich ein Gleisname sein." end
    local previous = data.groups[name]
    data.groups[name] = { members = members }
    local ok, err = save()
    if not ok then data.groups[name] = previous return nil, err end
    return true
  end

  function s.remove(name)
    local previous = data.groups[name]
    if not previous then return nil, "Den Bahnhof gibt es nicht." end
    data.groups[name] = nil
    local ok, err = save()
    if not ok then data.groups[name] = previous return nil, err end
    return true
  end

  function s.get(name) return data.groups[name] end

  function s.list()
    local names = {}
    for name in pairs(data.groups) do names[#names + 1] = name end
    table.sort(names)
    local out = {}
    for _, name in ipairs(names) do out[#out + 1] = { name = name, members = data.groups[name].members } end
    return out
  end

  function s.candidates(name)
    local g = data.groups[name]
    if g then
      local out = {}
      for i, m in ipairs(g.members) do out[i] = m end
      return out, true
    end
    return { name }, false
  end

  return s
end

-- waehlt das erste geeignete Gleis; sonst nil und die Gruende je gepruefter Kandidat
function M.choose(candidates, info)
  local reasons = {}
  for _, name in ipairs(candidates) do
    local problem = info(name).problem
    if not problem then return name end
    reasons[#reasons + 1] = name .. ": " .. problem
  end
  return nil, reasons
end

return M
