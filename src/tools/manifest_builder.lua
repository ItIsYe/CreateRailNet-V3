--[[
Purpose: Builds install/manifest.lua, the list of files the installer puts on a computer, per role, with size and Adler-32.
Public API:
  ROLES -> { role = { label, entries = {...} } }          what each role starts from
  build(read_body, runtime_manifest) -> manifest, problems   manifest = { version, id, files, base, roles, seed }
  render(manifest) -> Lua source text (deterministic, so a stale file shows up as a diff)
Notes: seed files (config templates, scripts/start_*.lua) are what an operator edits: the installer puts them on a computer only
  when they are missing and never replaces or removes them.
  dev tool (src/tools is never installed). The files of a role are the closure of its entry points over require() plus the
  config templates; configs/install/runtime_manifest.json stays the authority on what may leave the repository: a file it excludes
  that a role needs is a problem. scripts/manifest_sync.lua writes or checks the result.
]]

local require_scan = require("src.shared.require_scan")
local checksum = require("src.shared.checksum")
local runtime_packager = require("src.tools.runtime_packager")

local manifest_builder = {}

local VERSION = 1

-- every computer: the OTA recovery that startup.lua runs, the setup wizard and the startup upgrade
local COMMON_ENTRIES = { "src.shared.ota_recovery", "scripts/setup.lua", "scripts/upgrade_startup.lua", "scripts/keys.lua", "scripts/auth_bench.lua" }

local TEMPLATES = {
  "configs/templates/network.example.json",
  "configs/templates/network.redstone.example.json",
  "configs/templates/network.create.example.json",
  "configs/templates/network.full.example.json",
  "configs/templates/network.mixed.example.json",
  "configs/templates/network.service_plan.example.json",
}

manifest_builder.ROLES = {
  -- the planner (scripts/setup.lua --layout) is loaded by name from the wizard, so it is named here
  master  = { entries = { "src/master/main.lua", "scripts/ota_push.lua", "scripts/start_master.lua", "src.setup.layout", "src.setup.plan_builder", "src.setup.bauliste" } },
  signal  = { entries = { "src.nodes.signal_node", "scripts/start_signal.lua" } },
  sensor  = { entries = { "src.nodes.sensor_node", "scripts/start_sensor.lua" } },
  switch  = { entries = { "src.nodes.switch_node", "scripts/start_switch.lua" } },
  train   = { entries = { "src.nodes.train_node", "scripts/start_train.lua" } },
  station = { entries = { "src.nodes.station_node", "scripts/start_station.lua" } },
  depot   = { entries = { "src.nodes.depot_node", "scripts/start_depot.lua" } },
  panel   = { entries = { "src.nodes.panel_node", "scripts/start_panel.lua" } },
  arbiter = { entries = { "src.nodes.arbiter_node", "scripts/start_arbiter.lua" } },
}

local function sorted_keys(t)
  local keys = {}
  for key in pairs(t) do keys[#keys + 1] = key end
  table.sort(keys)
  return keys
end

local function set_of(list)
  local set = {}
  for _, item in ipairs(list) do set[item] = true end
  return set
end

function manifest_builder.build(read_body, runtime_manifest)
  local problems = {}
  local role_sets = {}
  local files = {}

  local function note(text) problems[#problems + 1] = text end

  for _, role in ipairs(sorted_keys(manifest_builder.ROLES)) do
    local entries = {}
    for _, entry in ipairs(COMMON_ENTRIES) do entries[#entries + 1] = entry end
    for _, entry in ipairs(manifest_builder.ROLES[role].entries) do entries[#entries + 1] = entry end
    local paths, scan_problems = require_scan.closure(entries, read_body)
    for _, name in ipairs(scan_problems.missing) do note(role .. ": module or file not found: " .. name) end
    for _, name in ipairs(scan_problems.external) do note(role .. ": requires " .. name .. ", which is not part of the runtime") end
    for _, path in ipairs(TEMPLATES) do paths[#paths + 1] = path end
    table.sort(paths)
    role_sets[role] = set_of(paths)
    for _, path in ipairs(paths) do
      if not files[path] then
        local body = read_body(path)
        if not body then
          note(role .. ": cannot read " .. path)
        else
          if runtime_manifest then
            local allowed, why = runtime_packager.should_include(runtime_manifest, path)
            if not allowed then note(role .. ": " .. path .. " may not be installed (" .. tostring(why) .. ")") end
          end
          files[path] = { #body, checksum.adler32(body) }
        end
      end
    end
  end

  -- base: in every role; each role lists only the rest
  local base_set = nil
  for _, role in ipairs(sorted_keys(role_sets)) do
    if base_set == nil then
      base_set = {}
      for path in pairs(role_sets[role]) do base_set[path] = true end
    else
      for path in pairs(base_set) do if not role_sets[role][path] then base_set[path] = nil end end
    end
  end
  local roles = {}
  for _, role in ipairs(sorted_keys(role_sets)) do
    local extra = {}
    for path in pairs(role_sets[role]) do if not base_set[path] then extra[#extra + 1] = path end end
    table.sort(extra)
    roles[role] = extra
  end

  local digest_parts = {}
  for _, path in ipairs(sorted_keys(files)) do
    digest_parts[#digest_parts + 1] = path .. ":" .. files[path][1] .. ":" .. files[path][2]
  end
  local id = checksum.hex(checksum.adler32(table.concat(digest_parts, "\n")))

  local seed = {}
  for _, path in ipairs(sorted_keys(files)) do
    if path:match("^configs/templates/") or path:match("^scripts/start_[%w_]+%.lua$") then seed[#seed + 1] = path end
  end

  return { version = VERSION, id = id, files = files, base = sorted_keys(base_set or {}), roles = roles, seed = seed }, problems
end

local function quote(text) return string.format("%q", text) end

function manifest_builder.render(manifest)
  local out = {
    "-- Purpose: the files the installer puts on a computer, with size and Adler-32, per role (base + roles.<role>); seed files are never replaced.\n",
    "-- GENERATED by scripts/manifest_sync.lua --write. Do not edit: CI fails when this file is out of date.\n",
    "-- id changes with every change of an installed file; the installer writes it into crn_version.txt.\n",
    "return {\n",
    "  version = " .. manifest.version .. ",\n",
    "  id = " .. quote(manifest.id) .. ",\n",
    "  files = {\n",
  }
  for _, path in ipairs(sorted_keys(manifest.files)) do
    out[#out + 1] = string.format("    [%s] = { %d, %d },\n", quote(path), manifest.files[path][1], manifest.files[path][2])
  end
  out[#out + 1] = "  },\n  seed = {\n"
  for _, path in ipairs(manifest.seed) do out[#out + 1] = "    " .. quote(path) .. ",\n" end
  out[#out + 1] = "  },\n  base = {\n"
  for _, path in ipairs(manifest.base) do out[#out + 1] = "    " .. quote(path) .. ",\n" end
  out[#out + 1] = "  },\n  roles = {\n"
  for _, role in ipairs(sorted_keys(manifest.roles)) do
    out[#out + 1] = "    " .. role .. " = {\n"
    for _, path in ipairs(manifest.roles[role]) do out[#out + 1] = "      " .. quote(path) .. ",\n" end
    out[#out + 1] = "    },\n"
  end
  out[#out + 1] = "  },\n}\n"
  return table.concat(out)
end

return manifest_builder
