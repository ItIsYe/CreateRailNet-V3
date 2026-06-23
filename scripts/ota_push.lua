--[[
Purpose: Standalone OTA update push tool.
Run this on the master computer (or a separate computer with the source files)
to push new code to all nodes in the network.

Usage:
  lua ota_push.lua                          -- push to all registered nodes
  lua ota_push.lua --node TRAIN-1           -- push to specific node
  lua ota_push.lua --version v2.0           -- tag with version string
  lua ota_push.lua --config network.json    -- use specific config

The master must be running for nodes to receive and apply the update.
Each node will apply files atomically and reboot automatically.
]]

local shared_args = require("src.shared.args")
local config = require("src.shared.config")
local log = require("src.shared.log")
local cc_modem = require("src.adapter.cc_modem")
local net = require("src.shared.net")
local ota_manager = require("src.master.ota_manager")
local time = require("src.shared.time")

local parsed = shared_args.parse({...}, { config = {}, node = {}, version = {} })
local cfg = config.load(parsed.config or "configs/templates/network.full.example.json")
local logger = log.new("INFO", 200)
local modem = cc_modem.new({ channel = cfg.channel })
local ok, err = modem:open(cfg.channel)
if not ok then error("modem open failed: " .. tostring(err)) end

local network = net.new(modem, cfg.channel, "OTA-TOOL", logger)
local ota = ota_manager.new(network, nil, logger)

local version = parsed.version or ("ota-" .. tostring(time.now_s()))
local nodes = parsed.node and { parsed.node } or nil

print("CreateRailNet OTA Push")
print("Version: " .. version)
print("Targets: " .. (nodes and table.concat(nodes, ", ") or "all nodes (broadcast)"))
print("")

-- If targeting specific nodes, push directly
-- Otherwise broadcast to all (nodes=nil pushes to each in registry which we don't have here,
-- so we fall back to a broadcast update_announce that nodes pick up)
if nodes then
  local results = ota.push_runtime({ nodes = nodes, version = version })
  for node_id, r in pairs(results) do
    print(node_id .. ": " .. (r.ok and "SENT" or ("FAILED: " .. tostring(r.error))))
  end
else
  -- Broadcast: nodes listening will accept ota_update for "broadcast" dst
  local dirs = {
    "src/shared/", "src/domain/", "src/adapter/",
    "src/master/", "src/nodes/", "scripts/"
  }
  local file_entries = {}
  local function read_file(path)
    if fs and fs.open then
      local fh = fs.open(path, "r")
      if fh then local c = fh.readAll(); fh.close(); return c end
    elseif io and io.open then
      local fh = io.open(path, "r")
      if fh then local c = fh:read("*a"); fh:close(); return c end
    end
  end
  local function scan(dir)
    if not fs or not fs.exists or not fs.exists(dir) then return end
    for _, name in ipairs(fs.list and fs.list(dir) or {}) do
      local full = dir .. name
      if fs.isDir and fs.isDir(full) then scan(full .. "/")
      elseif name:match("%.lua$") then
        local content = read_file(full)
        if content then table.insert(file_entries, { path = full, content = content }) end
      end
    end
  end
  for _, d in ipairs(dirs) do scan(d) end

  print("Collected " .. #file_entries .. " files")
  network.send("cmd", "broadcast", {
    cmd = "ota_update",
    type = "ota_update",
    files = file_entries,
    version = version,
    file_count = #file_entries
  })
  print("Broadcast OTA sent. Nodes will reboot automatically.")
end

-- Tick briefly to flush pending reliable messages
for _ = 1, 20 do
  network.tick()
  if os.sleep then os.sleep(0.1) end
end
print("Done.")
