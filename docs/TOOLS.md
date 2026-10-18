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

## Scripts

| Script | Purpose |
|---|---|
| `scripts/setup.lua` | per computer: role, id, peripherals; writes `startup.lua` and the minimal config |
| `scripts/check_configs.lua` | validates every config under `configs/` |
| `scripts/ota_push.lua [--node ID] [--legacy]` | pushes the runtime to nodes (`docs/OTA.md`) |
| `scripts/upgrade_startup.lua` | gives this computer's `startup.lua` the OTA recovery (nodes do it by themselves at start) |
| `scripts/replay_trace.lua trace.json config.json [--strict]` | replays a recorded dispatcher trace offline (`docs/OPERATIONS.md`) |
| `scripts/run_tests.lua` | the whole offline suite |
| `scripts/check_syntax.lua`, `cc_parse_guard.lua`, `check_test_registry.lua` | the guards CI runs |

## Maintenance mode

Maintenance mode is controlled through manual panel actions:

```json
{"label": "Enter Maintenance", "action": "enter_maintenance", "reason": "track work"}
```

```json
{"label": "Exit Maintenance", "action": "exit_maintenance"}
```

When maintenance is active, normal route requests and automatic dwell departures are blocked. Safe actions such as holding or emergency stopping trains remain allowed.

## Audit diagnostics

The master keeps a bounded in-memory audit log for important events such as manual actions, route requests, queued routes, maintenance entry and route rejection. Recent audit entries are exposed through panel diagnostics.

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
10. Use maintenance mode before changing real track hardware.
