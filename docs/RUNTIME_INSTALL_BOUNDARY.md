# Runtime Install Boundary

## Important rule

The following paths are **development/offline only** and must not be installed on ingame CC:Tweaked computers during normal runtime deployment:

```text
src/sim/**
tests/**
docs/**
.github/**
scripts/check_syntax.lua
scripts/check_configs.lua
scripts/run_tests.lua
src/tools/**
```

## Runtime manifest

The runtime-only install manifest is:

```text
configs/install/runtime_manifest.json
```

It includes runtime code only:

```text
startup.lua
scripts/start_*.lua
src/shared/**
src/domain/**
src/adapter/**
src/master/**
src/nodes/**
configs/templates/*.json
```

## Why simulation is excluded

`src/sim` is for offline verification only. It contains fake clocks, fake networks, and scenario runners. It is not meant to run in Minecraft and should not consume ingame disk space.

## Guard test

The test file below ensures the runtime manifest continues to exclude simulation and other dev-only paths:

```text
tests/test_runtime_manifest.lua
```

If future installer work is added, it must use `configs/install/runtime_manifest.json` as the source of truth for runtime packages.
