--[[
Purpose: One small text file with everything that is needed to tell from outside why a computer does not do what it should
  (scripts/setup.lua --export -> crn_diag.txt): the version, what the doctor found, the entry in the plan, the devices as the game names them,
  the files and the free space. It is written for a person who is not at the computer: it can be copied off or sent with `pastebin put`.
Public API:
  build(opts) -> text, report
    opts: fs (CC fs api), peripheral (CC peripheral api), report (a doctor report; made when missing),
          computer_id, label, host (the CC version string, _HOST), now (seconds since 1970), date(format, seconds) -> text (os.date; optional)
  write(opts) -> ok, path | err, text      the same, and the text is written to PATH with src/shared/safe_write (one file, no backup)
  PATH -> "crn_diag.txt"      MAX_BYTES -> 8000
Notes: reads only; nothing is asked of the master and nothing is switched. ASCII only. The text never exceeds MAX_BYTES: the method lists of the
  devices are shortened first, then the hints of the doctor, then the tail is cut with a mark. Passwords or keys do not exist in the plan or in
  the record; the plan itself is not copied (the entry of this computer and a summary are), so the file can be shared as it is.
]]

local doctor = require("src.setup.doctor")
local hardware = require("src.setup.hardware")
local netplan = require("src.setup.netplan")
local safe_write = require("src.shared.safe_write")
local setup_status = require("src.shared.setup_status")

local export = {}

export.PATH = "crn_diag.txt"
export.MAX_BYTES = 8000

local FILES = { "startup.lua", "startup.lua.prev", "crn_version.txt", "crn_status.lua", "crn_install_journal.lua", "crn_install_journal.lua.prev" }

local function ascii(text)
  return (tostring(text):gsub("[^\32-\126]", "?"))
end

-- key = value pairs of a plan entry in a fixed order; nested tables as a count only
local function entry_lines(entry)
  local keys = {}
  for key in pairs(entry) do keys[#keys + 1] = key end
  table.sort(keys)
  local out = {}
  for _, key in ipairs(keys) do
    local value = entry[key]
    if type(value) == "table" then out[#out + 1] = "  " .. key .. ": " .. #value .. " Eintraege"
    else out[#out + 1] = "  " .. key .. ": " .. ascii(value):sub(1, 80) end
  end
  return out
end

function export.build(opts)
  local o = opts or {}
  local fs_api = o.fs or _G.fs
  local function read(path)
    if not (fs_api and fs_api.exists and fs_api.exists(path)) then return nil end
    local fh = fs_api.open(path, "r")
    if not fh then return nil end
    local body = fh.readAll()
    fh.close()
    return body
  end
  local report = o.report or doctor.run({ fs = fs_api, peripheral = o.peripheral })
  local ctx = report.ctx
  local devices = hardware.scan(o.peripheral or _G.peripheral)

  local function compose(method_limit, with_fixes)
    local out = {}
    local function add(line) out[#out + 1] = ascii(line) end
    add("CreateRailNet Diagnose")
    local when = o.now
    if when then
      local stamp = o.date and select(2, pcall(o.date, "%Y-%m-%d %H:%M:%S", when))
      add("erzeugt: " .. (type(stamp) == "string" and stamp or tostring(math.floor(when))) .. " (" .. math.floor(when) .. ")")
    end
    add("Computer: Nr " .. tostring(o.computer_id) .. (o.label and (", Name " .. tostring(o.label)) or ""))
    add("CC: " .. tostring(o.host or "unbekannt"))
    add("Version: " .. tostring((read("crn_version.txt") or "keine"):gsub("%s+$", ""):sub(1, 80)))
    add("Rolle: " .. tostring(ctx.role or "?") .. "  ID: " .. tostring(ctx.id or "?") .. "  Plan: " .. tostring(ctx.config or "?"))
    add("")
    add("Pruefung: " .. doctor.summary(report))
    for _, check in ipairs(report.checks) do
      local tag = check.level == "ok" and "[ OK ] " or (check.level == "warn" and "[WARN] " or "[FEHL] ")
      add(tag .. check.title)
      if with_fixes and check.level ~= "ok" and check.fix then add("       Abhilfe: " .. check.fix) end
    end
    add("")
    if ctx.cfg then
      local summary = netplan.summary(ctx.cfg)
      add("Plan: Kanal " .. tostring(ctx.cfg.channel) .. ", Master " .. tostring(ctx.cfg.master_id) .. ", " .. tostring(summary.computers) .. " Computer, "
        .. tostring(#(ctx.cfg.blocks or {})) .. " Bloecke, " .. tostring(#(ctx.cfg.routes or {})) .. " Routen")
    else
      add("Plan: nicht lesbar")
    end
    if ctx.entry then
      add("Eintrag dieses Computers:")
      for _, line in ipairs(entry_lines(ctx.entry)) do add(line) end
    end
    local status = setup_status.read(fs_api)
    if status then
      add("Pruefprotokoll: " .. tostring(status.state) .. ", Fehler " .. tostring(status.fail) .. ", Hinweise " .. tostring(status.warn)
        .. ", Funktionstest " .. tostring(status.hw or "nicht gemacht") .. ", Stand " .. tostring(status.version or "?"))
    else
      add("Pruefprotokoll: keins (crn_status.lua)")
    end
    add("")
    add("Geraete (" .. #devices .. "):")
    for _, info in ipairs(devices) do
      local line = "  " .. info.name .. "  " .. info.type .. "  " .. info.class
      if method_limit > 0 and #info.methods > 0 then
        local shown = {}
        for index = 1, math.min(method_limit, #info.methods) do shown[#shown + 1] = tostring(info.methods[index]) end
        line = line .. "  [" .. table.concat(shown, ",") .. (#info.methods > method_limit and (",+" .. (#info.methods - method_limit)) or "") .. "]"
      end
      add(line)
    end
    add("")
    add("Dateien:")
    local seen = {}
    local list = {}
    for _, path in ipairs(FILES) do list[#list + 1] = path end
    if ctx.config then list[#list + 1] = ctx.config; list[#list + 1] = ctx.config .. ".prev" end
    for _, path in ipairs(list) do
      if not seen[path] then
        seen[path] = true
        local body = read(path)
        add("  " .. path .. "  " .. (body and (#body .. " Byte") or "fehlt"))
      end
    end
    local free = fs_api and fs_api.getFreeSpace and fs_api.getFreeSpace("/")
    add("Freier Platz: " .. (type(free) == "number" and (math.floor(free) .. " Byte") or "unbekannt"))
    return table.concat(out, "\n") .. "\n"
  end

  local text
  for _, attempt in ipairs({ { 8, true }, { 3, true }, { 0, true }, { 0, false } }) do
    text = compose(attempt[1], attempt[2])
    if #text <= export.MAX_BYTES then return text, report end
  end
  local mark = "\n[gekuerzt]\n"
  return text:sub(1, export.MAX_BYTES - #mark) .. mark, report
end

function export.write(opts)
  local o = opts or {}
  local text, report = export.build(o)
  local ok, err = safe_write.write(export.PATH, text, { fs = o.fs, keep_backup = false })
  if not ok then return false, err, text end
  return true, export.PATH, text, report
end

return export
