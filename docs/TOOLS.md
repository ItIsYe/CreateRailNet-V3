# CreateRailNet-V3 Tools

The programs in `src/tools/` described below are **development tools**: they run in the repository (or the simulation) and are not installed on game
computers by the installer (`install/manifest.lua` does not list them). On a game computer use `scripts/setup.lua --check` and `--doctor` (see "Scripts"
below). A single tool can be copied to a computer by hand to the same path if it is needed there (for example the peripheral inspector); that is not tested
in the game.

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

## Keys

`scripts/keys.lua` handles the keys of the message authentication (`docs/KEYS.md`): `init`, `issue <id>`, `revoke <id>`, `list`, `export-master`, `import-master`, `install --id <id>`, `status`.
Keys travel on a disk in a disk drive or are typed; the tool names a fingerprint on both sides and never prints a key unless asked to (issue without a disk).

## Scripts

| Script | Purpose |
|---|---|
| `installer` | one-line installer: `wget run https://raw.githubusercontent.com/ItIsYe/CreateRailNet-V3/main/installer` (`docs/INSTALL.md`) |
| `scripts/build_dist.lua --write\|--check` | writes / checks `dist/`, the minified copy of every installed file (run before `manifest_sync.lua`) |
| `scripts/manifest_sync.lua --write\|--check` | regenerates / checks `install/manifest.lua`, the installer's file list (after changing any installed file) |
| `scripts/setup.lua [--role R]` | the setup wizard of one computer: role, network plan (`configs/network.json`), id, hardware, summary; writes `startup.lua` (`docs/INGAME_SETUP.md`) |
| `scripts/setup.lua --check [file]` | checks a network plan (default `configs/network.json`) on the computer and names every problem; changes nothing |
| `scripts/setup.lua --fetch-plan` | station / depot: asks the master for its network plan (`plan_get` / `plan_part`), checks it (size, Adler-32, valid plan, same channel and master, this computer in it with its role) and writes it to the plan file after a yes; the old file stays as `.prev`; keeps the modem / monitor chosen on this computer |
| `scripts/setup.lua --doctor` | the doctor: installation, `startup.lua`, plan, entry, modem, devices of the role, monitor, free space, answer of the master; one line per point (`[ OK ]` / `[WARN]` / `[FEHL]`) and what to do about each. Writes only the record of its result, `crn_status.lua` (KONFIGURIERT / GEPRUEFT / PRUEFUNG_OFFEN); never switches a signal or a turnout |
| `scripts/setup.lua --layout [file]` | master: builds the plan of a whole new network from a short description (`configs/layout.txt`, text or JSON): blocks with signals and detectors, switch ladders, routes, stations, trains, service plans; writes the build list `crn_bauliste.txt` and, after a yes (default no), `configs/network.json` (old one as `.prev`); `docs/NETZ_BAUEN.md` |
| `scripts/setup.lua --test` | guided function test of this computer: reads modem / master / detector / station, shows a line on the monitor, switches a signal (3 s, then RED) or a turnout (3 s, then straight) **only after a yes for that action**; the result goes into `crn_status.lua` and to the master (`hw`) |
| `scripts/setup.lua --linktest` | link to the master: answers, how many at the first try, time, and the largest message (256 .. 4000 bytes) that goes through both ways; changes nothing |
| `scripts/setup.lua --export` | writes `crn_diag.txt` (at most 8000 bytes, ASCII): version, doctor result, own entry, devices, files, free space; reads only |
| `scripts/release_check.lua [--version vX.Y.Z]` | development only: the checks of the CI, the state of git, and when everything is green the tag commands (printed, never run; `docs/RELEASE.md`) |
| `scripts/check_configs.lua` | development only: validates the maintained example plans under `configs/templates/` (not installed on computers) |
| `scripts/ota_push.lua [--node ID] [--role R] [--limit N] [--dry-run] [--legacy]` | pushes the runtime to nodes; `--role` / `--limit` roll out by role and to the first N only, `--dry-run` says whom it would reach (`docs/OTA.md`) |
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
