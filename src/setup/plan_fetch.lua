--[[
Purpose: Fetches the network plan from the master, for the setup wizard of a station or depot computer (they read their platforms / tracks
  from their own plan, and a short plan has none). It asks for the plan part by part (event plan_get, answer cmd plan_part), puts the text
  together, and checks it before anybody writes it: size and Adler-32, that it is a valid plan, that it is the plan of the network this
  computer talks in (channel, master) and that it lists this computer with its role. It writes nothing.
Public API: fetch(opts) -> result
  opts: channel, master_id, id, role, modem_name (entry field "modem"), peripheral (CC peripheral api), on_total(parts, bytes),
        wait_s (5: how long one part may take), attempts (3: asks per part), deadline_s (120: the whole transfer), restarts (2),
        for tests: modem (a transport instead of the real one), pull_event(timeout_s) -> event | nil, time (clock module), now() -> seconds
  result: { ok = true, text, cfg, entry, version, size, parts }
        | { ok = false, state, message }
    state: "no_modem" | "no_answer" | "refused" | "error" | "changed" | "damaged" | "invalid" | "mismatch"; message is for the player (German, ASCII)
Notes: everything that comes back is checked before it is used: the sender must be the master, the answer must name this question, the
  numbers must be sane (at most 60 parts, 200000 bytes). A plan that changes at the master during the transfer, or that arrives damaged,
  is fetched again (restarts); anything else that goes wrong is reported, never raised.
]]

local cc_modem = require("src.adapter.cc_modem")
local checksum = require("src.shared.checksum")
local net = require("src.shared.net")
local netplan = require("src.setup.netplan")

local plan_fetch = {}

local MAX_PARTS = 60
local MAX_BYTES = 200000
local MAX_PART_BYTES = 8192
local DEFAULT_WAIT_S = 5
local DEFAULT_ATTEMPTS = 3
local DEFAULT_DEADLINE_S = 120
local DEFAULT_RESTARTS = 2

local function default_pull(timeout)
  local timer = os.startTimer(timeout)
  while true do
    local event = { os.pullEvent() }
    if event[1] == "timer" and event[2] == timer then return nil end
    if event[1] == "modem_message" then
      if os.cancelTimer then pcall(os.cancelTimer, timer) end
      return event
    end
  end
end

local REFUSED = {
  not_in_plan = "Der Master kennt diesen Computer noch nicht. Am Master auf der Seite EINRICHTUNG annehmen, dann noch einmal versuchen.",
  conflict = "Die ID dieses Computers steht im Netzplan des Masters mit einer anderen Rolle. Eins von beiden aendern.",
  role = "Fuer diese Rolle liefert der Master keinen Plan (nur Bahnhof und Depot lesen Bahnsteige und Gleise aus dem Plan).",
  unavailable = "Dieser Master kann keinen Plan liefern (aelterer Stand?). Den Master aktualisieren.",
}

local function fail(state, message) return { ok = false, state = state, message = message } end

local function whole(n, low, high) return type(n) == "number" and n == math.floor(n) and n >= low and n <= high end

function plan_fetch.fetch(opts)
  local o = opts or {}
  local modem = o.modem or cc_modem.new({ channel = o.channel, modem_name = o.modem_name, peripheral_api = o.peripheral })
  if not modem.modem and not o.modem then return fail("no_modem", "Kein Modem gefunden: der Master ist nicht erreichbar.") end
  if modem:open(o.channel) == false then return fail("no_modem", "Das Modem konnte nicht geoeffnet werden.") end

  local silent = { info = function() end, warn = function() end, error = function() end, debug = function() end }
  local network = net.new(modem, o.channel, o.id, silent, o.time)
  local now = o.now or function() return (os.epoch and os.epoch("utc") / 1000) or os.clock() end
  local pull = o.pull_event or default_pull
  local wait_s = o.wait_s or DEFAULT_WAIT_S
  local attempts = o.attempts or DEFAULT_ATTEMPTS
  local deadline = now() + (o.deadline_s or DEFAULT_DEADLINE_S)

  -- one part: ask, wait for the answer to exactly this question, ask again when it does not come
  local function ask(index, version)
    for _ = 1, attempts do
      local sent = network.send_reliable("event", o.master_id, { type = "plan_get", role = o.role, index = index, version = version })
      if not sent then return nil end
      local until_ = math.min(now() + wait_s, deadline)
      while true do
        local remaining = until_ - now()
        if remaining <= 0 then break end
        local event = pull(math.min(0.5, remaining))
        if event and event[1] == "modem_message" then
          local msg = event[5]
          local status = network.receive(msg)
          if status == "ok" and type(msg) == "table" and msg.type == "cmd" and msg.src == o.master_id and type(msg.payload) == "table"
              and msg.payload.cmd == "plan_part" and msg.payload.question == sent.id then
            return msg.payload
          end
        end
        network.tick()
      end
      if now() >= deadline then return nil end
    end
    return nil
  end

  -- one complete transfer; returns the text, or a failure
  local function transfer()
    local version, total, size
    local pieces = {}
    local index = 1
    while true do
      local part = ask(index, version)
      if not part then return nil, fail("no_answer", "Der Master antwortet nicht. Laeuft er (und ist er auf dem neuen Stand)? Gleicher Kanal, Modem in Reichweite?") end
      if part.ok ~= true then
        if part.state == "refused" then return nil, fail("refused", REFUSED[part.reason] or "Der Master liefert diesen Plan nicht.") end
        if part.state == "changed" then return nil, fail("changed", "Der Netzplan am Master hat sich waehrend der Uebertragung geaendert.") end
        local reason = type(part.reason) == "string" and part.reason:sub(1, 120) or "unbekannter Grund"
        return nil, fail("error", "Der Master kann den Plan nicht liefern: " .. reason)
      end
      -- the numbers are the master's claims: look at them before they are used
      if part.index ~= index or not whole(part.total, 1, MAX_PARTS) or not whole(part.size, 1, MAX_BYTES)
          or type(part.version) ~= "string" or not part.version:match("^%x%x%x%x%x%x%x%x$")
          or type(part.data) ~= "string" or #part.data == 0 or #part.data > MAX_PART_BYTES then
        return nil, fail("damaged", "Der Master hat eine unbrauchbare Antwort geschickt.")
      end
      if index == 1 then
        version, total, size = part.version, part.total, part.size
        if o.on_total then pcall(o.on_total, total, size) end
      elseif part.version ~= version or part.total ~= total or part.size ~= size then
        return nil, fail("changed", "Der Netzplan am Master hat sich waehrend der Uebertragung geaendert.")
      end
      pieces[index] = part.data
      if index == total then break end
      index = index + 1
    end
    local text = table.concat(pieces)
    if #text ~= size or checksum.hex(checksum.adler32(text)) ~= version then
      return nil, fail("damaged", "Der Plan ist beschaedigt angekommen (Pruefsumme stimmt nicht).")
    end
    return text, nil, version, total
  end

  local text, failure, version, parts
  for _ = 0, o.restarts or DEFAULT_RESTARTS do
    text, failure, version, parts = transfer()
    if text then break end
    -- a plan that changed or arrived damaged is fetched again; anything else will not get better by asking again
    if not (failure.state == "changed" or failure.state == "damaged") or now() >= deadline then break end
  end
  if not text then return failure end

  local cfg, errors, fatal = netplan.parse(text)
  if not cfg then return fail("invalid", "Der Plan des Masters ist keine gueltige Datei: " .. tostring(fatal)) end
  if errors then return fail("invalid", "Der Plan des Masters hat Fehler: " .. netplan.explain(errors[1], cfg)) end
  if cfg.channel ~= o.channel or cfg.master_id ~= o.master_id then
    return fail("mismatch", "Der Plan des Masters gehoert zu einem anderen Netz (Kanal " .. tostring(cfg.channel) .. ", Master " .. tostring(cfg.master_id) .. "). Nichts geaendert.")
  end
  local entry = netplan.find_node(cfg, o.id)
  if not entry or entry.role ~= o.role then
    return fail("mismatch", "Im Plan des Masters fehlt der Eintrag " .. tostring(o.id) .. " mit dieser Rolle. Nichts geaendert.")
  end
  return { ok = true, text = text, cfg = cfg, entry = entry, version = version, size = #text, parts = parts }
end

return plan_fetch
