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
2. Run system check.
3. Inspect peripherals on each computer.
4. Start master.
5. Start panel.
6. Start field nodes.
7. Start train node.
8. Use debug events before relying on real hardware.
