--[[
Purpose: What the installer puts on a computer: loads and checks the manifest, lists the files of a role, compares them with the disk.
Public API:
  ROLES -> ordered list of { key, label, text }       (menu of the installer)
  load_data(body, name) -> value | nil, err        runs a data file without globals
  parse_manifest(body) -> manifest | nil, err
  validate(manifest) -> true | false, err
  files_for_role(manifest, role, with_bundle) -> { [path] = { size, adler, seed } } | nil, err
  total_bytes(files) -> number
  diff(files, read_local, adler32, exists) -> todo (paths, largest first), unchanged (count)
  ref_kind(ref) -> "fixed" | "branch"     a version tag (v1.2.0, 1.4) or a commit id (7 to 40 hex digits) stays what it is; every other name is a
                                          branch and moves with the next push
Notes: read_local(path) -> body | nil. Sizes are compared before checksums, so an unchanged tree costs one read per file.
  Seed files (config templates, scripts/start_*.lua) are what an operator edits: they count as unchanged as soon as they exist.
]]

local plan = {}

plan.ROLES = {
  { key = "master",  label = "Master",  text = "Zentrale Steuerung (nur einer)" },
  { key = "signal",  label = "Signal",  text = "steuert ein Signal" },
  { key = "sensor",  label = "Melder",  text = "meldet Zuege (Train Observer)" },
  { key = "switch",  label = "Weiche",  text = "stellt eine Weiche (Redstone)" },
  { key = "station", label = "Bahnhof", text = "gehoert zu einem Create-Bahnhof" },
  { key = "depot",   label = "Depot",   text = "Abstellbereich / Depot" },
  { key = "train",   label = "Zug",     text = "Bordcomputer im Zug" },
  { key = "panel",   label = "Monitor", text = "Bedien-Monitor (Panel)" },
  { key = "arbiter", label = "Schiedsrichter", text = "dritte Stimme der Masterwahl" },
  { key = "fleet", label = "Flotte", text = "Zuege, Fahrplaene, Auftraege" },
}

local MAX_FILES = 400
local MAX_FILE_BYTES = 200000

-- A data file (manifest, journal, install record) is a Lua table constructor; it runs without any globals.
function plan.load_data(body, name)
  local chunk, err
  if setfenv then
    chunk, err = (loadstring or load)(body, "=" .. name)
    if chunk then setfenv(chunk, {}) end
  else
    chunk, err = load(body, "=" .. name, "t", {})
  end
  if not chunk then return nil, err end
  local ok, value = pcall(chunk)
  if not ok then return nil, value end
  return value
end

function plan.parse_manifest(body)
  if type(body) ~= "string" or body == "" then return nil, "manifest is empty" end
  local manifest, err = plan.load_data(body, "manifest")
  if manifest == nil then return nil, "manifest does not parse: " .. tostring(err) end
  local ok = type(manifest) == "table"
  if not ok then return nil, "manifest is not a table: " .. tostring(manifest) end
  return manifest
end

local function valid_path(path)
  if type(path) ~= "string" or #path == 0 or #path > 120 then return false end
  if not path:match("^[%w_%-%./]+$") then return false end
  if path:find("..", 1, true) or path:find("//", 1, true) or path:sub(1, 1) == "/" or path:sub(-1) == "/" then return false end
  if not (path:match("%.lua$") or path:match("%.json$")) then return false end
  return path:sub(1, 4) == "src/" or path:sub(1, 8) == "scripts/" or path:sub(1, 18) == "configs/templates/"
end

function plan.validate(manifest)
  if type(manifest) ~= "table" or manifest.version ~= 1 then return false, "unknown manifest version" end
  if type(manifest.id) ~= "string" or not manifest.id:match("^%x+$") then return false, "manifest has no id" end
  if type(manifest.files) ~= "table" or type(manifest.base) ~= "table" or type(manifest.roles) ~= "table" or type(manifest.seed) ~= "table" then
    return false, "manifest is incomplete"
  end
  local count = 0
  for path, entry in pairs(manifest.files) do
    count = count + 1
    if not valid_path(path) then return false, "path not allowed: " .. tostring(path) end
    if type(entry) ~= "table" or type(entry[1]) ~= "number" or type(entry[2]) ~= "number" or entry[1] < 0 or entry[1] > MAX_FILE_BYTES then
      return false, "bad size or checksum for " .. path
    end
  end
  if count == 0 or count > MAX_FILES then return false, "implausible number of files: " .. count end
  local function check_list(list, label)
    for _, path in ipairs(list) do
      if not manifest.files[path] then return false, label .. " lists a file without size/checksum: " .. tostring(path) end
    end
    return true
  end
  local ok, err = check_list(manifest.base, "base")
  if not ok then return false, err end
  ok, err = check_list(manifest.seed, "seed")
  if not ok then return false, err end
  for role, list in pairs(manifest.roles) do
    ok, err = check_list(list, "role " .. tostring(role))
    if not ok then return false, err end
  end
  if type(manifest.bundle) ~= "table" then return false, "manifest has no setup bundle" end
  for role, list in pairs(manifest.bundle) do
    if type(list) ~= "table" or not manifest.roles[role] then return false, "bundle of an unknown role: " .. tostring(role) end
    ok, err = check_list(list, "bundle " .. tostring(role))
    if not ok then return false, err end
  end
  return true
end

function plan.files_for_role(manifest, role, with_bundle)
  local extra = manifest.roles and manifest.roles[role]
  if not extra then return nil, "unknown role: " .. tostring(role) end
  local files = {}
  local seed = {}
  for _, path in ipairs(manifest.seed) do seed[path] = true end
  local function add(path) files[path] = { size = manifest.files[path][1], adler = manifest.files[path][2], seed = seed[path] == true } end
  for _, path in ipairs(manifest.base) do add(path) end
  for _, path in ipairs(extra) do add(path) end
  -- the setup bundle (wizard, doctor, key tool ...) is on a computer only while it is being set up or a tool runs
  if with_bundle then
    for _, path in ipairs(manifest.bundle and manifest.bundle[role] or {}) do add(path) end
  end
  return files
end

function plan.ref_kind(ref)
  local text = tostring(ref)
  if #text >= 7 and #text <= 40 and text:match("^%x+$") then return "fixed" end
  if text:match("^v?%d+%.%d+[%w%.%-]*$") then return "fixed" end
  return "branch"
end

function plan.total_bytes(files)
  local total = 0
  for _, entry in pairs(files) do total = total + entry.size end
  return total
end

function plan.diff(files, read_local, adler32, exists)
  local todo, unchanged = {}, 0
  for path, entry in pairs(files) do
    if entry.seed and exists(path) then
      unchanged = unchanged + 1
    else
      local body = read_local(path)
      if body and #body == entry.size and adler32(body) == entry.adler then unchanged = unchanged + 1
      else todo[#todo + 1] = path end
    end
  end
  table.sort(todo, function(a, b)
    if files[a].size ~= files[b].size then return files[a].size > files[b].size end
    return a < b
  end)
  return todo, unchanged
end

return plan
