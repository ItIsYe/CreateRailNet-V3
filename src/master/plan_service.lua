--[[
Purpose: The master hands out its network plan, in parts, to a station or depot computer that asks for it (the setup wizard of that
  computer: "Plan vom Master holen"). Those two roles read their platforms / tracks from their own plan, and a plan is more than one modem
  message holds.
Public API: new(opts) -> service
    opts: plan_path (the plan file of this master), fs, chunk_size (3000 bytes per part), max_bytes (200000), cache_s (60), now_s()
  service.part(index, expect_version) -> reply
    reply on success: { ok = true, index, total, version, size, data }     version = Adler-32 of the whole text (8 hex characters)
    reply on failure: { ok = false, state = "changed" | "error", reason }   changed: the plan is not the one the asker began with
Notes: the file is read as it lies on the disk now and is handed out only when it parses and validates (a half-written or broken plan is
  not spread). That is the file the operator edited, which may be newer than what the master runs until its next restart.
  Part 1 (and any request without a version) reads the file again; later parts come from the single cached text of the last read (cache_s
  seconds), so a plan of many parts is read and checked once. If the text changed in between, the asker is told "changed" and starts over.
]]

local checksum = require("src.shared.checksum")
local netplan = require("src.setup.netplan")
local time = require("src.shared.time")

local plan_service = {}

function plan_service.new(opts)
  local o = opts or {}
  local fs_api = o.fs or _G.fs
  local chunk_size = o.chunk_size or 3000
  local max_bytes = o.max_bytes or 200000
  local cache_s = o.cache_s or 60
  local now = o.now_s or time.now_s
  local self = {}
  local cache = nil   -- { text, version, total, at }: the last plan that was read and found valid

  local function read_text()
    if not (o.plan_path and fs_api and fs_api.exists and fs_api.exists(o.plan_path)) then return nil, "Der Master findet seine Netzplan-Datei nicht." end
    local fh = fs_api.open(o.plan_path, "r")
    if not fh then return nil, "Der Master kann seine Netzplan-Datei nicht lesen." end
    local text = fh.readAll()
    fh.close()
    if type(text) ~= "string" or text == "" then return nil, "Die Netzplan-Datei des Masters ist leer." end
    return text
  end

  local function load()
    local text, err = read_text()
    if not text then return nil, err end
    if #text > max_bytes then return nil, "Der Netzplan des Masters ist zu gross (" .. #text .. " Bytes)." end
    local cfg, errors = netplan.parse(text)
    if not cfg then return nil, "Der Netzplan des Masters ist keine gueltige JSON-Datei." end
    if errors then return nil, "Der Netzplan des Masters hat " .. #errors .. " Fehler (am Master: scripts/setup.lua --check)." end
    cache = {
      text = text, version = checksum.hex(checksum.adler32(text)), at = now(),
      total = math.max(1, math.ceil(#text / chunk_size)),
    }
    return cache
  end

  function self.part(index, expect_version)
    if type(index) ~= "number" or index ~= math.floor(index) or index < 1 then return { ok = false, state = "error", reason = "Ungueltige Teilnummer." } end
    if expect_version ~= nil and type(expect_version) ~= "string" then return { ok = false, state = "error", reason = "Ungueltige Version." } end
    local entry = cache
    local fresh = entry and now() - entry.at <= cache_s and entry.at <= now()
    -- the first part (or a request without a version) starts a transfer: read the file again
    if index == 1 or expect_version == nil or not fresh then
      local loaded, err = load()
      if not loaded then return { ok = false, state = "error", reason = err } end
      entry = loaded
    end
    if expect_version ~= nil and expect_version ~= entry.version then
      return { ok = false, state = "changed", reason = "Der Netzplan am Master hat sich geaendert.", version = entry.version }
    end
    if index > entry.total then return { ok = false, state = "error", reason = "Teil " .. index .. " gibt es nicht (" .. entry.total .. " Teile)." } end
    return {
      ok = true, index = index, total = entry.total, version = entry.version, size = #entry.text,
      data = entry.text:sub((index - 1) * chunk_size + 1, index * chunk_size),
    }
  end

  return self
end

return plan_service
