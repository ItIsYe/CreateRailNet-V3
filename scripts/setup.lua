--[[
CreateRailNet-V3 First-Time Setup Tool
Runs interactively on a fresh CC:Tweaked computer.
Guides the user through role/ID selection, scans attached peripherals,
writes startup.lua and a minimal config, then reboots.

Usage: shell.run("scripts/setup.lua")
--]]

-- ─── Helpers ────────────────────────────────────────────────────────────────

local function clear() if term then term.clear(); term.setCursorPos(1,1) end end
local function println(s) print(tostring(s or "")) end
local function print_header(title)
  clear()
  println("╔══════════════════════════════════════════╗")
  println("║   CreateRailNet-V3  Setup Wizard          ║")
  println("╠══════════════════════════════════════════╣")
  println("║  " .. tostring(title):sub(1,42) .. string.rep(" ", math.max(0, 42 - #tostring(title))) .. "  ║")
  println("╚══════════════════════════════════════════╝")
  println("")
end

local function ask(prompt, default)
  io.write(prompt)
  if default then io.write(" [" .. tostring(default) .. "] ") end
  io.write(": ")
  local line = io.read()
  if not line or line == "" then return default end
  return line
end

local function ask_choice(prompt, choices, default)
  println(prompt)
  for i, choice in ipairs(choices) do
    println(string.format("  %d) %s", i, choice))
  end
  while true do
    io.write("Choice [" .. (default or 1) .. "]: ")
    local line = io.read()
    local n = tonumber(line)
    if n == nil or line == "" then n = tonumber(default) or 1 end
    if n and n >= 1 and n <= #choices then return n, choices[n] end
    println("  Please enter a number between 1 and " .. #choices)
  end
end

local function ask_yes(prompt, default_yes)
  local hint = default_yes and "[Y/n]" or "[y/N]"
  io.write(prompt .. " " .. hint .. " ")
  local line = io.read()
  if not line or line == "" then return default_yes end
  return line:lower():sub(1,1) == "y"
end

local function write_file(path, content)
  if fs and fs.open then
    local dir = path:match("^(.*)/[^/]+$")
    if dir and dir ~= "" and fs.makeDir then pcall(fs.makeDir, dir) end
    local fh = fs.open(path, "w")
    if fh then fh.write(content); fh.close(); return true end
    return false
  end
  if io and io.open then
    local fh = io.open(path, "w")
    if fh then fh:write(content); fh:close(); return true end
  end
  return false
end

local function read_file(path)
  if fs and fs.open then
    if fs.exists and not fs.exists(path) then return nil end
    local fh = fs.open(path, "r")
    if fh then local c = fh.readAll(); fh.close(); return c end
  end
  if io and io.open then
    local fh = io.open(path, "r")
    if fh then local c = fh:read("*a"); fh:close(); return c end
  end
end

local function scan_peripherals()
  local found = {}
  local sides = { "left", "right", "top", "bottom", "front", "back" }
  if peripheral and peripheral.getNames then
    for _, name in ipairs(peripheral.getNames()) do
      local ptype = peripheral.getType and peripheral.getType(name) or "unknown"
      local methods = {}
      if peripheral.getMethods then
        local ok, m = pcall(peripheral.getMethods, name)
        if ok and type(m) == "table" then methods = m end
      end
      table.insert(found, { name=name, type=ptype, methods=methods })
    end
  else
    for _, side in ipairs(sides) do
      if peripheral and peripheral.isPresent and peripheral.isPresent(side) then
        local ptype = peripheral.getType and peripheral.getType(side) or "unknown"
        table.insert(found, { name=side, type=ptype, methods={} })
      end
    end
  end
  return found
end

local function classify(peri)
  local name_lower = (peri.name or ""):lower()
  local type_lower = (peri.type or ""):lower()
  local text = name_lower .. " " .. type_lower
  for _, m in ipairs(peri.methods or {}) do text = text .. " " .. m:lower() end

  if text:find("station") and text:find("setschedule") then return "create_station" end
  if text:find("trainobserver") or text:find("istrainpassing") then return "train_observer" end
  if text:find("signal") and (text:find("setforcedred") or text:find("getstate")) then return "create_signal" end
  if text:find("monitor") then return "monitor" end
  if text:find("modem") then return "modem" end
  return "other"
end

local function json_encode(value)
  -- Minimal JSON encoder for config output
  local function enc(v, indent)
    local t = type(v)
    if t == "nil" then return "null"
    elseif t == "boolean" then return tostring(v)
    elseif t == "number" then
      if v == math.floor(v) then return tostring(math.floor(v)) end
      return tostring(v)
    elseif t == "string" then
      return '"' .. v:gsub('\\','\\\\'):gsub('"','\\"'):gsub('\n','\\n') .. '"'
    elseif t == "table" then
      -- Detect array
      local is_array = true
      local max_i = 0
      for k in pairs(v) do
        if type(k) ~= "number" or k ~= math.floor(k) or k < 1 then is_array = false; break end
        if k > max_i then max_i = k end
      end
      if is_array and max_i == #v then
        local items = {}
        for _, item in ipairs(v) do table.insert(items, enc(item, (indent or 0)+2)) end
        if #items == 0 then return "[]" end
        local inner = "[\n" .. string.rep(" ", (indent or 0)+2)
        return inner .. table.concat(items, ",\n" .. string.rep(" ", (indent or 0)+2)) .. "\n" .. string.rep(" ", indent or 0) .. "]"
      else
        local keys = {}
        for k in pairs(v) do if type(k)=="string" then table.insert(keys, k) end end
        table.sort(keys)
        if #keys == 0 then return "{}" end
        local items = {}
        for _, k in ipairs(keys) do
          table.insert(items, '"' .. k .. '": ' .. enc(v[k], (indent or 0)+2))
        end
        local inner = "{\n" .. string.rep(" ", (indent or 0)+2)
        return inner .. table.concat(items, ",\n" .. string.rep(" ", (indent or 0)+2)) .. "\n" .. string.rep(" ", indent or 0) .. "}"
      end
    end
    return "null"
  end
  return enc(value, 0)
end

-- ─── Step 1: Welcome ─────────────────────────────────────────────────────────

print_header("Welcome")
println("This wizard configures this computer as a CreateRailNet node.")
println("It will:")
println("  1. Ask for role and network ID")
println("  2. Scan attached peripherals")
println("  3. Write startup.lua and a network config")
println("  4. Reboot into the correct mode")
println("")

if not ask_yes("Continue?", true) then
  println("Aborted."); return
end

-- ─── Step 2: Network config ──────────────────────────────────────────────────

print_header("Network Configuration")
println("Where is your network config?")
println("  A) Use an existing config file on disk")
println("  B) A master will generate and push one via OTA")
println("  C) Let this wizard generate a minimal config right now")
println("")

local _, config_mode = ask_choice("Config source", {
  "Existing config file",
  "OTA from master (leave default, master will push)",
  "Generate minimal config now"
}, 1)

local config_path = "configs/templates/network.full.example.json"

if config_mode == "Existing config file" then
  config_path = ask("Config file path", config_path)
  if not (fs and fs.exists and fs.exists(config_path)) then
    println("WARNING: File not found: " .. config_path)
    println("         The computer will error on start until the file exists.")
  end
elseif config_mode == "OTA from master (leave default, master will push)" then
  println("OK — will use default path. Master must push config before first run.")
end

-- ─── Step 3: Channel ─────────────────────────────────────────────────────────

print_header("Modem Channel")
println("All CreateRailNet computers must use the same channel.")
println("Default: 777  (change if you have multiple separate networks)")
println("")
local channel_str = ask("Channel", "777")
local channel = tonumber(channel_str) or 777

-- ─── Step 4: Role ────────────────────────────────────────────────────────────

print_header("Node Role")
println("What is the role of THIS computer?")
println("")

local roles = {
  "master    — Central controller (one per network)",
  "train     — Onboard computer in a train",
  "sensor    — Attached to a Create Train Observer",
  "signal    — Attached to a Create Signal",
  "switch    — Controls a track switch via redstone",
  "station   — At a Create Train Station",
  "depot     — At a depot/storage area",
  "panel     — Operator monitor panel",
}
local role_keys = { "master","train","sensor","signal","switch","station","depot","panel" }

local idx = ask_choice("Role", roles, 1)
local role = role_keys[idx]

-- ─── Step 5: Node ID ─────────────────────────────────────────────────────────

print_header("Node ID")

-- Suggest a sensible default based on role
local id_defaults = {
  master  = "MASTER-1",
  train   = "TRAIN-1",
  sensor  = "SEN-1",
  signal  = "SIG-1",
  switch  = "SW-1",
  station = "ST-A",
  depot   = "DEPOT-1",
  panel   = "PANEL-1",
}

println("The Node ID must exactly match the id in your network config.")
println("Examples: MASTER-1, TRAIN-2, SIG-AB-IN, ST-A, DEPOT-1")
println("")

local node_id = ask("Node ID", id_defaults[role] or (role:upper() .. "-1"))

-- ─── Step 6: Peripheral scan ─────────────────────────────────────────────────

print_header("Peripheral Scan")
println("Scanning attached peripherals...")
println("")

local peris = scan_peripherals()
if #peris == 0 then
  println("  No peripherals found.")
  println("  (Modems, monitors, Create blocks will appear here once attached)")
else
  for _, p in ipairs(peris) do
    local cls = classify(p)
    println(string.format("  %-20s type=%-20s class=%s", p.name, p.type, cls))
  end
end
println("")

-- Find modem
local modem_name = nil
for _, p in ipairs(peris) do
  if classify(p) == "modem" then modem_name = p.name; break end
end

if not modem_name then
  println("WARNING: No modem detected!")
  println("         Attach a wireless or wired modem and rerun setup,")
  println("         or proceed and configure manually.")
  println("")
  modem_name = ask("Modem side/name", "top")
end

-- Role-specific peripheral config
local extra_config = {}

if role == "signal" then
  local signal_peri = nil
  for _, p in ipairs(peris) do if classify(p) == "create_signal" then signal_peri = p; break end end
  if signal_peri then
    println("Found Create Signal: " .. signal_peri.name)
    extra_config.peripheral = signal_peri.name
    extra_config.adapter = "peripheral"
  else
    println("No Create Signal detected. Choose signal control method:")
    local _, sig_method = ask_choice("Signal adapter", {"peripheral (Create Signal)", "redstone"}, 2)
    if sig_method == "redstone" then
      extra_config.adapter = "redstone"
      extra_config.side = ask("Redstone output side", "left")
    else
      extra_config.adapter = "peripheral"
      extra_config.peripheral = ask("Peripheral name", "Create_Signal_0")
    end
  end

elseif role == "sensor" then
  local obs_peri = nil
  for _, p in ipairs(peris) do if classify(p) == "train_observer" then obs_peri = p; break end end
  if obs_peri then
    println("Found Train Observer: " .. obs_peri.name)
    extra_config.peripheral = obs_peri.name
    extra_config.sensor_id = node_id
  else
    println("No Train Observer detected.")
    extra_config.peripheral = ask("Train Observer peripheral name", "Create_TrainObserver_0")
    extra_config.sensor_id = node_id
  end

elseif role == "switch" then
  println("NOTE: Vanilla Create track switches use redstone — not a CC peripheral.")
  extra_config.adapter = "redstone"
  extra_config.side = ask("Redstone output side for this switch", "left")
  extra_config.active_position = ask("Position when signal is active", "DIVERGING")

elseif role == "train" then
  local station_peri = nil
  for _, p in ipairs(peris) do if classify(p) == "create_station" then station_peri = p; break end end
  if station_peri then
    println("Found Create Station: " .. station_peri.name)
    extra_config.schedule_station = station_peri.name
    extra_config.create_station = station_peri.name
  else
    extra_config.schedule_station = ask("Create Station peripheral name", "Create_Station_0")
    extra_config.create_station = extra_config.schedule_station
  end
  extra_config.display_name = ask("Train display name", node_id)

elseif role == "station" then
  extra_config.display_name = ask("Station display name", node_id)
  extra_config.create_station_name = ask("Create station name (as it appears in Create)", extra_config.display_name)
  extra_config.station_type = ask("Station type (passenger/freight/mixed)", "passenger")

elseif role == "depot" then
  extra_config.display_name = ask("Depot display name", node_id)
  extra_config.depot_type = ask("Depot type (storage/staging/mixed)", "mixed")

elseif role == "master" then
  extra_config.display_name = "Master"

elseif role == "panel" then
  extra_config.display_name = ask("Panel display name", "Main Panel")
end

-- ─── Step 7: Generate minimal config if needed ───────────────────────────────

if config_mode == "Generate minimal config now" then
  print_header("Generating Config")
  local cfg = {
    v = 1,
    channel = channel,
    master_id = (role == "master") and node_id or "MASTER-1",
    nodes = {},
    blocks = {},
    routes = {},
    service_plans = {}
  }

  local node_entry = { id = node_id, role = role }
  for k, v in pairs(extra_config) do node_entry[k] = v end
  table.insert(cfg.nodes, node_entry)

  config_path = "configs/network.json"
  write_file(config_path, json_encode(cfg))
  println("Minimal config written to: " .. config_path)
  println("Edit it to add more nodes, blocks, and routes before running the full network.")
  println("")
end

-- ─── Step 8: Write startup.lua ───────────────────────────────────────────────

print_header("Writing startup.lua")

-- Build startup.lua content line by line (avoids nested [[ ]] in Lua 5.1)
local lines = {
  "-- CreateRailNet-V3 auto-generated by setup.lua",
  "-- Role: " .. role .. "  ID: " .. node_id,
  "-- To reconfigure: delete this file and run: shell.run(\"scripts/setup.lua\")",
  "",
  'local CRN_ROLE   = "' .. role .. '"',
  'local CRN_ID     = "' .. node_id .. '"',
  'local CRN_CONFIG = "' .. config_path .. '"',
  "",
  "local role_entrypoints = {",
  '  master  = "src.master.main",',
  '  signal  = "src.nodes.signal_node",',
  '  sensor  = "src.nodes.sensor_node",',
  '  switch  = "src.nodes.switch_node",',
  '  train   = "src.nodes.train_node",',
  '  station = "src.nodes.station_node",',
  '  depot   = "src.nodes.depot_node",',
  '  panel   = "src.nodes.panel_node",',
  "}",
  "",
  "local entrypoint = role_entrypoints[CRN_ROLE]",
  'if not entrypoint then error("Unknown CRN_ROLE: " .. tostring(CRN_ROLE)) end',
  "",
  "local function read_version()",
  '  if fs and fs.exists and fs.exists("crn_version.txt") then',
  '    local fh = fs.open("crn_version.txt", "r")',
  '    if fh then local v = fh.readLine(); fh.close(); return v end',
  "  end",
  '  return "unknown"',
  "end",
  "",
  'print("CreateRailNet v" .. read_version() .. "  role=" .. CRN_ROLE .. "  id=" .. CRN_ID)',
  "",
  "local mod = require(entrypoint)",
  "if mod and mod.new_runtime then",
  "  mod.new_runtime({ id = CRN_ID, config = CRN_CONFIG }).run()",
  "elseif mod and mod.run then",
  "  mod.run({ id = CRN_ID, config = CRN_CONFIG })",
  "else",
  '  shell.run("run", entrypoint, "--id", CRN_ID, "--config", CRN_CONFIG)',
  "end",
}
local startup_content = table.concat(lines, "\n") .. "\n"

local wrote = write_file("startup.lua", startup_content)
if wrote then
  println("startup.lua written successfully.")
else
  println("ERROR: Could not write startup.lua!")
  println("       You may need to write it manually.")
end

-- ─── Step 9: Summary ─────────────────────────────────────────────────────────

print_header("Setup Complete")
println("Configuration summary:")
println(string.format("  Role:    %s", role))
println(string.format("  ID:      %s", node_id))
println(string.format("  Config:  %s", config_path))
println(string.format("  Channel: %d", channel))
println(string.format("  Modem:   %s", modem_name or "not found"))
if extra_config.peripheral then
  println(string.format("  Device:  %s", extra_config.peripheral))
end
if extra_config.adapter == "redstone" then
  println(string.format("  Side:    %s", extra_config.side or "?"))
end
println("")

if role == "master" then
  println("NEXT STEPS:")
  println("  1. Edit your network config to define all nodes, blocks and routes")
  println("  2. Reboot — this computer will start as Master")
  println("  3. Run setup.lua on each other computer in the network")
  println("  4. Once all nodes register, the system is live")
elseif role == "train" then
  println("NEXT STEPS:")
  println("  1. Make sure the Master is running")
  println("  2. Reboot — this train computer will register and await routes")
else
  println("NEXT STEPS:")
  println("  1. Make sure the Master is running")
  println("  2. Reboot — this node will register automatically")
end

println("")
local do_reboot = ask_yes("Reboot now?", true)
if do_reboot then
  println("Rebooting...")
  if os.reboot then os.reboot() end
else
  println("Reboot skipped. Run 'reboot' or restart the computer when ready.")
end
