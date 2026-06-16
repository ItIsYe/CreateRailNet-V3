--[[
Purpose: Offline setup wizard that builds a draft config from a peripheral scan report.
Public API: classify_peripheral(info), build_config(report, opts), write_config(path, cfg), run(args).
Notes: Does not access hardware unless caller provides a live report from peripheral_inspector.
]]

local json = require("src.shared.json")
local validate = require("src.shared.validate")
local inspector = require("src.tools.peripheral_inspector")

local setup_wizard = {}

local function lower(value) return string.lower(tostring(value or "")) end

local function contains(text, needle)
  return string.find(lower(text), lower(needle), 1, true) ~= nil
end

local function methods_text(info)
  local text = lower(info.name) .. " " .. lower(info.type)
  for _, method in ipairs(info.methods or info.create_hints or {}) do text = text .. " " .. lower(method) end
  return text
end

local function first_by_role(items, role)
  for _, item in ipairs(items or {}) do if item.role == role then return item end end
  return nil
end

local function add_node(nodes, node)
  table.insert(nodes, node)
  return node
end

local function read_file(path)
  if io and io.open then
    local fh = io.open(path, "r")
    if fh then local content = fh:read("*a"); fh:close(); return content end
  end
  if fs and fs.open then
    local fh = fs.open(path, "r")
    if fh then local content = fh.readAll(); fh.close(); return content end
  end
  return nil, "cannot open " .. tostring(path)
end

local function write_file(path, content)
  if fs and fs.open then
    local fh = fs.open(path, "w")
    if not fh then return false, "cannot open " .. tostring(path) end
    fh.write(content); fh.close(); return true
  end
  if io and io.open then
    local fh = io.open(path, "w")
    if not fh then return false, "cannot open " .. tostring(path) end
    fh:write(content); fh:close(); return true
  end
  return false, "no file API available"
end

function setup_wizard.classify_peripheral(info)
  local text = methods_text(info or {})
  if contains(text, "station") and contains(text, "setschedule") then return "create_station" end
  if contains(text, "trainobserver") or contains(text, "istrainpassing") then return "train_observer" end
  if contains(text, "signal") and (contains(text, "setforcedred") or contains(text, "getstate")) then return "create_signal" end
  if contains(text, "monitor") then return "monitor" end
  if contains(text, "modem") then return "modem" end
  if contains(text, "rotationspeed") or contains(text, "targetspeed") then return "speed_controller" end
  if contains(text, "sequencedgearshift") or contains(text, "rotate") or contains(text, "move") then return "gearshift" end
  return "unknown"
end

function setup_wizard.load_report(path)
  local content, err = read_file(path)
  if not content then return nil, err end
  return json.decode(content)
end

function setup_wizard.build_config(report, opts)
  local options = opts or {}
  local peripherals = (report and report.peripherals) or {}
  local classified = {}
  for _, info in ipairs(peripherals) do
    table.insert(classified, { info = info, role = setup_wizard.classify_peripheral(info) })
  end

  local create_station = first_by_role(classified, "create_station")
  local observer = first_by_role(classified, "train_observer")
  local signal_a = first_by_role(classified, "create_signal")
  local monitor = first_by_role(classified, "monitor")

  local cfg = {
    v = 1,
    channel = options.channel or 777,
    master_id = options.master_id or "MASTER-1",
    blocks = {
      { id = "B-GEN-1", entry_signal = "SIG-GEN-IN", exit_signal = "SIG-GEN-OUT", sensors = { "OBS-GEN-1" }, switches = {} }
    },
    routes = {
      { id = "R-GEN-1", from = options.from_station or "ST-A", to = options.to_station or "ST-B", blocks = { "B-GEN-1" }, priority = 10, kind = options.kind or "passenger" }
    },
    service_plans = {
      { id = "SP-GEN-1", train_id = "TRAIN-1", display_name = "Generated Test Plan", repeat_plan = false, stops = { { from = options.from_station or "ST-A", to = options.to_station or "ST-B", route_id = "R-GEN-1", kind = options.kind or "passenger", dwell_seconds = options.dwell_seconds or 5 } } }
    },
    nodes = {}
  }

  add_node(cfg.nodes, { id = cfg.master_id, role = "master" })
  add_node(cfg.nodes, { id = "TRAIN-1", role = "train", train_id = "TRAIN-1", display_name = "Generated Train", monitor = monitor and monitor.info.name or "monitor", service_plan = "SP-GEN-1", create_station = create_station and create_station.info.name or "Create_Station_0", schedule_station = create_station and create_station.info.name or "Create_Station_0" })
  add_node(cfg.nodes, { id = "PANEL-1", role = "panel", display_name = "Generated Panel", monitor = monitor and monitor.info.name or "monitor", pages = { "overview", "trains", "stations", "service_plans", "manual", "diagnostics", "audit", "maintenance" } })
  local from_name = options.from_station or "ST-A"
  local to_name = options.to_station or "ST-B"
  add_node(cfg.nodes, { id = from_name, role = "station", create_station_name = from_name, station_type = options.kind or "passenger", display_name = from_name, monitor = monitor and monitor.info.name or "monitor", platforms = { { id = "P1", kind = options.kind or "passenger", sensor_id = "OBS-GEN-1", block_id = "B-GEN-1", dwell_seconds = options.dwell_seconds or 5 } } })
  add_node(cfg.nodes, { id = to_name, role = "station", create_station_name = to_name, station_type = options.kind or "passenger", display_name = to_name, monitor = monitor and monitor.info.name or "monitor", platforms = { { id = "P1", kind = options.kind or "passenger", sensor_id = "OBS-GEN-2", dwell_seconds = options.dwell_seconds or 5 } } })
  add_node(cfg.nodes, { id = "SIG-GEN-IN", role = "signal", peripheral = signal_a and signal_a.info.name or "Create_Signal_0" })
  add_node(cfg.nodes, { id = "SIG-GEN-OUT", role = "signal", peripheral = "Create_Signal_1" })
  add_node(cfg.nodes, { id = "OBS-GEN-1", role = "sensor", peripheral = observer and observer.info.name or "Create_TrainObserver_0" })
  add_node(cfg.nodes, { id = "OBS-GEN-2", role = "sensor", peripheral = "Create_TrainObserver_1" })

  local ok, errors = validate.validate_config(cfg)
  return cfg, { valid = ok, errors = errors or {}, classified = classified, warnings = setup_wizard.warnings(cfg, classified) }
end

function setup_wizard.warnings(cfg, classified)
  local warnings = {}
  if not first_by_role(classified, "create_station") then table.insert(warnings, "no Create Station detected; using Create_Station_0 placeholder") end
  if not first_by_role(classified, "train_observer") then table.insert(warnings, "no Train Observer detected; using Create_TrainObserver placeholders") end
  if not first_by_role(classified, "create_signal") then table.insert(warnings, "no Create Signal detected; using Create_Signal placeholders") end
  if not first_by_role(classified, "monitor") then table.insert(warnings, "no monitor detected; using monitor placeholder") end
  return warnings
end

function setup_wizard.write_config(path, cfg)
  local ok, err = write_file(path, json.encode(cfg))
  if not ok then return false, err end
  return true, path
end

function setup_wizard.run(args)
  local options = args or {}
  local report
  if options.report then
    local loaded, err = setup_wizard.load_report(options.report)
    if not loaded then print("report load failed: " .. tostring(err)); return false, err end
    report = loaded
  else
    report = inspector.scan()
  end
  local cfg, meta = setup_wizard.build_config(report, options)
  print("CreateRailNet Setup Wizard")
  print("valid=" .. tostring(meta.valid))
  for _, warning in ipairs(meta.warnings or {}) do print("warn: " .. tostring(warning)) end
  for _, err in ipairs(meta.errors or {}) do print("error: " .. tostring(err)) end
  if options.write then
    local ok, result = setup_wizard.write_config(options.write, cfg)
    print((ok and "written: " or "write failed: ") .. tostring(result))
  end
  return meta.valid, cfg, meta
end

return setup_wizard
