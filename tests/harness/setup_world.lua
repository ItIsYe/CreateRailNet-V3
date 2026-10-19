--[[
Purpose: A fake CC:Tweaked computer for the setup wizard: in-memory disk, made-up peripherals, a screen of 51 x 19 that records every page, and
  scripted answers.
Public API:
  new(opts) -> world       opts: files (path -> body), templates (true: the real configs/templates/*.json on the disk), peripherals (list of
                           { name, type, methods }), width, height, version (false: no crn_version.txt, as before an installer run)
  world.run(argv, answers) -> result      runs src/setup/wizard with those arguments; read() hands out the answers in order
  world.link = function(opts) -> { state }   what the master answers to "do you know this computer?" (none set: nobody is asked)
  world.fetch = function(opts) -> result      what comes back when the computer fetches the plan of the master (none set: it cannot)
  answers can also be a function(page_text) -> answer: it is asked at every prompt with the text of the page so far (nil ends the input)
  world.pages -> list of { lines = {...} }   world.fs, world.rebooted, world.unused (answers that were not asked for)
  world.text() -> all output as one string     world.last_page_text()
  world.check_screen(allow_tall) -> nil | message   every line <= width - 1 characters, ASCII only, every page <= height lines (unless allow_tall)
]]

local memfs = require("tests.harness.memfs")
local wizard = require("src.setup.wizard")

local setup_world = {}

local function read_disk(path)
  local fh = io.open(path, "rb")
  if not fh then return nil end
  local body = fh:read("*a")
  fh:close()
  return body
end

local TEMPLATE_NAMES = {
  "network.create.example.json", "network.depot.example.json", "network.example.json", "network.full.example.json",
  "network.mixed.example.json", "network.panel.example.json", "network.redstone.example.json", "network.service_plan.example.json",
  "network.station.example.json", "network.train.example.json",
}

-- the devices a computer typically has
setup_world.MODEM = { name = "top", type = "modem", methods = { "open", "transmit", "isOpen" } }
setup_world.SIGNAL = { name = "Create_Signal_0", type = "Create_Signal", methods = { "setForcedRed", "isForcedRed" } }
setup_world.OBSERVER = { name = "Create_TrainObserver_0", type = "Create_TrainObserver", methods = { "isTrainPassing", "getPassingTrainName" } }
setup_world.STATION = { name = "Create_Station_0", type = "Create_Station", methods = { "setSchedule", "isTrainPresent", "getStationName" } }
setup_world.MONITOR = { name = "monitor_0", type = "monitor", methods = { "write", "setCursorPos", "clear" } }

function setup_world.new(opts)
  local o = opts or {}
  local world = { fs = memfs.new(), pages = { { lines = {} } }, rebooted = 0, width = o.width or 51, height = o.height or 19 }
  for path, body in pairs(o.files or {}) do world.fs.set(path, body) end
  if o.templates ~= false then
    for _, name in ipairs(TEMPLATE_NAMES) do world.fs.set("configs/templates/" .. name, read_disk("configs/templates/" .. name)) end
  end
  -- a computer the installer has been on: it left its version file (the doctor warns about a missing one)
  if o.version ~= false and world.fs.files["crn_version.txt"] == nil then world.fs.set("crn_version.txt", "main-test0000") end
  local peripherals = o.peripherals or { setup_world.MODEM, setup_world.MONITOR }

  function world.run(argv, answers)
    local queue = {}
    local responder = type(answers) == "function" and answers or nil
    if not responder then for _, a in ipairs(answers or {}) do queue[#queue + 1] = a end end
    local pending = nil
    local function current() return world.pages[#world.pages] end
    local env = {
      fs = world.fs,
      print = function(text) current().lines[#current().lines + 1] = tostring(text) end,
      write = function(text) pending = (pending or "") .. tostring(text) end,
      read = function()
        if pending then current().lines[#current().lines + 1] = pending; pending = nil end
        if responder then return responder(table.concat(current().lines, "\n")) end
        return table.remove(queue, 1)
      end,
      term = {
        clear = function() world.pages[#world.pages + 1] = { lines = {} } end,
        setCursorPos = function() end,
        getSize = function() return world.width, world.height end,
      },
      peripheral = {
        getNames = function() local names = {}; for _, p in ipairs(peripherals) do names[#names + 1] = p.name end; return names end,
        getType = function(name) for _, p in ipairs(peripherals) do if p.name == name then return p.type end end end,
        getMethods = function(name) for _, p in ipairs(peripherals) do if p.name == name then return p.methods end end end,
      },
      os = { reboot = function() world.rebooted = world.rebooted + 1 end },
      link = world.link,
      fetch = world.fetch,
    }
    local result = wizard.run({ args = argv or {}, env = env })
    world.unused = #queue
    return result
  end

  function world.text()
    local parts = {}
    for _, page in ipairs(world.pages) do parts[#parts + 1] = table.concat(page.lines, "\n") end
    return table.concat(parts, "\n")
  end

  function world.last_page_text() return table.concat(world.pages[#world.pages].lines, "\n") end

  function world.check_screen(allow_tall)
    for number, page in ipairs(world.pages) do
      if #page.lines > world.height and not allow_tall then return string.format("page %d has %d lines", number, #page.lines) end
      for _, line in ipairs(page.lines) do
        if #line > world.width - 1 and not line:match("^> ") then return string.format("page %d: line too long (%d): %s", number, #line, line) end
        if line:find("[\128-\255]") then return string.format("page %d: not ASCII: %s", number, line) end
      end
    end
    return nil
  end

  return world
end

return setup_world
