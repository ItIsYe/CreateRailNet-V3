# CreateRailNet-V3

CreateRailNet-V3 is a realistic, event-driven railway control system for Minecraft Create + CC:Tweaked. It is greenfield, Lua 5.1 compatible, and designed for robustness and testing outside of Minecraft.

## Quick Start

### 1) Install
- Copy the repository to your CC:Tweaked computer.
- Ensure Lua 5.1 compatibility (default for CC:Tweaked).

### 2) Configuration
- Start from `configs/templates/network.example.json`.
- Validate with the harness:
  ```sh
  lua tests/harness/runner.lua
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

## Troubleshooting
- If any node is down or unknown, signals will default to **RED** (fail-safe).
- See `docs/troubleshooting.md` for detailed diagnostics.

## Project Layout
- `src/shared/`: core libraries (log, config, net, event bus)
- `src/master/`: master dispatcher + UI
- `src/nodes/`: node role implementations
- `src/adapter/`: peripherals and Create adapters
- `tests/`: harness + deterministic tests
- `docs/`: architecture, protocol, configuration reference

## License
MIT. See `LICENSE`.
