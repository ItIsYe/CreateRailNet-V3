# CreateRailNet-V3 Tools

## Config Check

```lua
local check = require("src.tools.check_config")
check.run({ config = "configs/templates/network.full.example.json" })
```

Use this before connecting real rail hardware.

## System Check

```lua
local sys = require("src.tools.system_check")
sys.run("configs/templates/network.full.example.json")
```

This performs a dry-run using fake signal and switch adapters.

## Diagnosis Report

```lua
local diag = require("src.tools.diagnose_config")
diag.run({ config = "configs/templates/network.full.example.json" })
```

Shows counts for nodes, blocks, routes, service plans, and role distribution.

## Health Report

```lua
local health = require("src.tools.health_report")
health.run({ config = "configs/templates/network.full.example.json" })
```

Shows config validity, role counts, channel, master id, and summary counts.

## Peripheral Inspector

```lua
local insp = require("src.tools.peripheral_inspector")
insp.run()
```

Use this on each computer to list peripheral types and method names.

## Debug Events

```lua
local dbg = require("src.tools.debug_events")
dbg.run({ kind = "sensor", sensor_id = "SEN-AB", action = "enter" })
```

```lua
local dbg = require("src.tools.debug_events")
dbg.run({ kind = "train_depart", train_id = "TRAIN-1", from = "ST-A", to = "ST-B" })
```

```lua
local dbg = require("src.tools.debug_events")
dbg.run({ kind = "train_arrived", train_id = "TRAIN-1", station = "ST-B" })
```

## Safe test order

1. Run config check.
2. Run health report.
3. Run system check.
4. Inspect peripherals on each computer.
5. Start master.
6. Start panel.
7. Start field nodes.
8. Start train node.
9. Use debug events before relying on real hardware.
