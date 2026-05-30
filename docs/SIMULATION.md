# Offline Simulation

## Goal

The simulation layer tests CreateRailNet program logic without Minecraft, CC:Tweaked, ATM10, Create peripherals, redstone, or monitors.

It uses the real domain and master modules:

- train registry
- station registry
- depot registry
- service plans
- route resolver
- dispatcher
- route integration
- audit log

## Modules

```text
src/sim/fake_clock.lua
src/sim/fake_network.lua
src/sim/scenario_runner.lua
```

## What is currently simulated

### Basic service flow

`tests/test_sim_basic_flow.lua` checks:

1. Master sends a Create-format schedule payload.
2. Train requests departure.
3. Dispatcher reserves the route block.
4. Train arrival advances/completes the service plan.

### Multi-train conflict

`tests/test_sim_multitrain_conflict.lua` checks:

1. TRAIN-1 reserves a route.
2. TRAIN-2 requests the same route.
3. TRAIN-2 waits because the block is reserved.
4. After releasing TRAIN-1, queued route processing authorizes TRAIN-2.

## Run

```bash
lua5.4 scripts/run_tests.lua
```

The GitHub Actions workflow also runs these simulation tests.

## Why this matters

This gives offline confidence in the program itself, not just config parsing or syntax.

## Next simulation targets

- station dwell timer and ready departure
- depot ready and dispatch flow
- maintenance lock rejection
- switch conflict handling
- deadlock detection cases
- generated config simulation
- route release by sensor event
