--[[
Purpose: Linien und Takt (Konzept 12.1): eine Linie verweist auf eine Vorlage (geordnete Halte), nennt die zugelassenen Zuege, ein Intervall und eine Prioritaet. Jeder Termin erzeugt hoechstens einen Fahrtwunsch; eine Betriebsunterbrechung erzeugt keine Welle nachzuholender Fahrten, sondern der naechste Termin wird neu berechnet und die ausgefallenen werden gezaehlt.
API: lines.new{ store, path, now } -> l; l.set(linie) -> ok, fehler; l.remove(id); l.get(id); l.list(); l.due() -> Liste der faelligen Linien; l.advance(id) -> { term, skipped }; l.note(id, text); l.save()
Notes: Zeiten sind Betriebszeit in Sekunden (E1). Ein Termin ist die Zeit, zu der der Fahrtwunsch entsteht, keine Abfahrtsgarantie. Der Termin steht in der Anforderungskennung ("linie-ID-Termin"), damit ein wiederholter Termin denselben Auftrag liefert.
]]

local M = {}

M.MIN_INTERVAL = 30

function M.new(opts)
  local l = {}
  local data = opts.store.load(opts.path) or { lines = {} }
  data.lines = data.lines or {}

  function l.save() return opts.store.save(opts.path, data) end

  function l.set(line)
    if type(line.id) ~= "string" or not line.id:match("^[%w%-_]+$") then return nil, "Die Linienkennung ist ungueltig." end
    if type(line.template) ~= "string" or line.template == "" then return nil, "Die Linie braucht eine Vorlage." end
    if type(line.interval) ~= "number" or line.interval < M.MIN_INTERVAL then return nil, "Das Intervall muss mindestens " .. M.MIN_INTERVAL .. " Sekunden betragen." end
    if line.priority ~= nil and line.priority ~= "normal" and line.priority ~= "bevorzugt" then return nil, "Die Prioritaet ist normal oder bevorzugt." end
    local previous = data.lines[line.id]
    local entry = {
      id = line.id, title = line.title ~= "" and line.title or line.id, template = line.template, trains = line.trains or {},
      interval = line.interval, priority = line.priority or "normal", active = line.active ~= false,
      next_due = previous and previous.interval == line.interval and previous.next_due or (opts.now() + (line.offset or line.interval)),
      missed = previous and previous.missed or 0, note = previous and previous.note or nil,
    }
    data.lines[line.id] = entry
    local ok, err = l.save()
    if not ok then data.lines[line.id] = previous return nil, err end
    return true
  end

  function l.remove(id)
    local previous = data.lines[id]
    if not previous then return nil, "Die Linie gibt es nicht." end
    data.lines[id] = nil
    local ok, err = l.save()
    if not ok then data.lines[id] = previous return nil, err end
    return true
  end

  function l.get(id) return data.lines[id] end

  function l.list()
    local ids = {}
    for id in pairs(data.lines) do ids[#ids + 1] = id end
    table.sort(ids)
    local out = {}
    for _, id in ipairs(ids) do out[#out + 1] = data.lines[id] end
    return out
  end

  function l.due()
    local t = opts.now()
    local out = {}
    for _, line in ipairs(l.list()) do
      if line.active and t >= line.next_due then out[#out + 1] = line end
    end
    return out
  end

  -- der faellige Termin ist bedient (oder bewusst ausgelassen); der naechste liegt in der Zukunft
  function l.advance(id, served)
    local line = data.lines[id]
    if not line then return nil end
    local t = opts.now()
    local term = line.next_due
    local skipped = 0
    local nxt = term + line.interval
    while nxt <= t do
      nxt = nxt + line.interval
      skipped = skipped + 1
    end
    line.next_due = nxt
    line.missed = line.missed + skipped + (served == false and 1 or 0)
    l.save()
    return { term = term, skipped = skipped }
  end

  -- zuletzt eingesetzter Zug: die naechste Wahl beginnt hinter ihm (die Zuege wechseln sich ab)
  function l.used(id, train_id)
    local line = data.lines[id]
    if line and line.last_train ~= train_id then line.last_train = train_id l.save() end
  end

  function l.note(id, text)
    local line = data.lines[id]
    if line and line.note ~= text then line.note = text l.save() end
  end

  return l
end

return M
