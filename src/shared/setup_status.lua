--[[
Purpose: The record of how far this computer's setup got: written by the setup wizard and by the doctor, reported to the master.
Public API:
  PATH -> "crn_status.lua"        STATES -> { KONFIGURIERT, GEPRUEFT, PRUEFUNG_OFFEN } (state names, German on purpose: they are shown)
  render(status) -> text          parse(text) -> status | nil       read(fs) -> status | nil       write(fs, status) -> ok, err
  status: { state, role, id, config, version, at, fail, warn, hw, hw_at }   hw: "ok" | "fail", the result of the function test, at hw_at
Notes: the file is a Lua table that runs without any globals (like the installer's records) and is checked field by field when it is read,
  so a damaged or hand-edited file never gives a half-valid status. It records what the doctor found, it grants nothing: the release of
  a node for operation is the master's decision.
  KONFIGURIERT: the wizard wrote startup.lua and the plan.  GEPRUEFT: the doctor found nothing red.  PRUEFUNG_OFFEN: it found something.
]]

local safe_write = require("src.shared.safe_write")

local setup_status = {}

setup_status.PATH = "crn_status.lua"
setup_status.STATES = { KONFIGURIERT = true, GEPRUEFT = true, PRUEFUNG_OFFEN = true }
-- the result of the guided function test (scripts/setup.lua --test): "ok" = every step that was done passed, "fail" = one did not
setup_status.HW = { ok = true, fail = true }

local STRING_FIELDS = { "state", "role", "id", "config", "version", "hw" }
local NUMBER_FIELDS = { "at", "fail", "warn", "hw_at" }
local MAX_STRING = 200

function setup_status.render(status)
  local lines = { "return {" }
  for _, key in ipairs(STRING_FIELDS) do
    if type(status[key]) == "string" then lines[#lines + 1] = "  " .. key .. " = " .. string.format("%q", status[key]) .. "," end
  end
  for _, key in ipairs(NUMBER_FIELDS) do
    if type(status[key]) == "number" then lines[#lines + 1] = "  " .. key .. " = " .. string.format("%d", status[key]) .. "," end
  end
  lines[#lines + 1] = "}"
  return table.concat(lines, "\n") .. "\n"
end

-- runs the text with no globals on every Lua version
local function run_data(text)
  local chunk
  if setfenv then
    chunk = (loadstring or load)(text, "=crn_status")
    if chunk then setfenv(chunk, {}) end
  else
    chunk = load(text, "=crn_status", "t", {})
  end
  if not chunk then return nil end
  local ok, value = pcall(chunk)
  if ok and type(value) == "table" then return value end
  return nil
end

function setup_status.parse(text)
  if type(text) ~= "string" or #text > 4000 then return nil end
  local value = run_data(text)
  if not value then return nil end
  local status = {}
  for _, key in ipairs(STRING_FIELDS) do
    local item = value[key]
    if item ~= nil then
      if type(item) ~= "string" or #item > MAX_STRING then return nil end
      status[key] = item
    end
  end
  for _, key in ipairs(NUMBER_FIELDS) do
    local item = value[key]
    if item ~= nil then
      if type(item) ~= "number" or item ~= item or item < 0 or item > 2 ^ 52 then return nil end
      status[key] = math.floor(item)
    end
  end
  if not setup_status.STATES[status.state or ""] then return nil end
  if status.hw ~= nil and not setup_status.HW[status.hw] then return nil end
  return status
end

function setup_status.read(fs_api)
  local fs_ = fs_api or _G.fs
  if not (fs_ and fs_.exists and fs_.exists(setup_status.PATH)) then return nil end
  local fh = fs_.open(setup_status.PATH, "r")
  if not fh then return nil end
  local text = fh.readAll()
  fh.close()
  return setup_status.parse(text)
end

function setup_status.write(fs_api, status)
  if not setup_status.STATES[status and status.state or ""] then return false, "unknown state: " .. tostring(status and status.state) end
  return safe_write.write(setup_status.PATH, setup_status.render(status), { fs = fs_api or _G.fs })
end

return setup_status
