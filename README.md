# CreateRailNet-V3

CreateRailNet-V3 is a realistic, event-driven railway control system for Minecraft 1.21.x (ATM10) with Create + CC:Tweaked. It is written
for Lua 5.1 (also runs on 5.4 and LuaJIT) and designed for robustness: everything that can be tested outside the game is, with seeded random
walks over generated networks, lossy links and crash injection.

What it does: block reservation with conflict groups, switch locks and an interlocking (Fahrstrassen, flank protection, overlap); queueing of
conflicting trains; signals that are sent again instead of trusted; node timeouts that fault blocks and clear them again when the evidence is
there; recovery after a master restart; verified over-the-air updates with automatic rollback; a status page with one lamp for the whole
network, alerts, central log and a trace you can replay offline. Network size is not fixed: lists, logs, queues and retries are bounded.

## Quick Start

### 1) Install
On each CC:Tweaked computer (HTTP enabled):
```
wget run https://raw.githubusercontent.com/ItIsYe/CreateRailNet-V3/main/installer
```
The installer asks for the role, downloads and verifies exactly the files that role needs, then starts the setup wizard: one question per page, a header
that shows the step (role, network plan, name, hardware, check), `?` for help, `<` to go back, and nothing is written before you confirm the summary.
Running the installer again updates or repairs. Wizard: `docs/INGAME_SETUP.md`. Installer details, options and error messages: `docs/INSTALL.md`.

### 2) Configuration
- The wizard puts the network plan of the master at `configs/network.json` (a copy of an example or an empty plan); other computers get a short plan of
  their own. Start from `configs/templates/network.example.json` (`network.full.example.json` for everything) and extend it.
- Validate before connecting hardware:
  ```sh
  lua scripts/check_configs.lua
  ```

### 3) Run Master
```sh
lua src/master/main.lua --config configs/templates/network.example.json --id MASTER-1
```

### 4) Run Nodes
```sh
lua src/nodes/sensor_node.lua --config configs/templates/network.example.json --id SEN-1
lua src/nodes/signal_node.lua --config configs/templates/network.example.json --id SIG-1
lua src/nodes/switch_node.lua --config configs/templates/network.example.json --id SW-1
```

### 5) Update
- Nodes: `lua scripts/ota_push.lua` from the master (`docs/OTA.md`). Nodes that were set up with an older version get there with the installer
  or `lua scripts/ota_push.lua --legacy`. The master: run `installer` on it again.

## Tests (outside the game)
```sh
lua scripts/run_tests.lua      # whole suite; CI runs it on lua5.1, lua5.4 and luajit
lua scripts/check_syntax.lua && lua scripts/cc_parse_guard.lua && lua scripts/check_test_registry.lua
```
What cannot be tested offline is listed in `docs/INGAME_TESTS.md` — please run that checklist once in your world.

## ATM10
- See `docs/atm10_setup.md` for ATM10 setup and peripheral inspection.
- Peripheral methods vary by modpack/addons; always inspect ingame.

## Troubleshooting
- If any node is down or unknown, signals will default to **RED** (fail-safe).
- See `docs/troubleshooting.md` and `docs/OPERATIONS.md` for diagnostics and repair actions.

## Documentation
| Topic | File |
|---|---|
| design and fail-safe rules | `docs/architecture.md`, `docs/assumptions.md`, `docs/DISPATCHER_SAFETY.md` |
| configuration | `docs/config_reference.md`, `docs/CONFIG_VALIDATION.md` |
| operating the master, repairs, traces | `docs/OPERATIONS.md` |
| updates and rollback | `docs/OTA.md` |
| messages | `docs/protocol.md` |
| installation | `docs/INSTALL.md` |
| in-game setup and tests | `docs/INGAME_SETUP.md`, `docs/INGAME_TESTS.md` |

## Project Layout
- `src/shared/`: core libraries (log, config, net, ticker, safe writes, updater)
- `src/domain/`: blocks, interlocking, switch locks, alerts, status model, trace recorder
- `src/master/`: master dispatcher, runtime, UI, OTA manager
- `src/nodes/`: node role implementations
- `src/adapter/`: peripherals and Create adapters
- `installer`, `install/`: the one-line installer and its modules, `install/manifest.lua` is generated (`scripts/manifest_sync.lua`)
- `scripts/`: setup, OTA push, trace replay, checks
- `tests/`: harness + deterministic and seeded random tests
- `docs/`: architecture, protocol, configuration reference

## License
MIT. See `LICENSE`.
