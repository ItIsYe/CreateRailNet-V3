# Runtime Packager

## Purpose

The runtime packager is the offline helper that decides which files are allowed into a later ingame install package.

It uses this manifest as source of truth:

```text
configs/install/runtime_manifest.json
```

## Module

```text
src/tools/runtime_packager.lua
```

This module is offline/dev tooling. It should not itself be installed on ingame computers in normal runtime packages.

## Included runtime paths

Runtime install packages may include:

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

## Excluded paths

Runtime install packages must exclude:

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

## Guard tests

The following tests protect the boundary:

```text
tests/test_runtime_manifest.lua
tests/test_runtime_packager.lua
```

## Usage example

```lua
local p = require("src.tools.runtime_packager")
local manifest = p.load_manifest("configs/install/runtime_manifest.json")
local included, excluded = p.filter_files(manifest, {
  "startup.lua",
  "src/shared/config.lua",
  "src/sim/scenario_runner.lua",
  "tests/test_sim_basic_flow.lua"
})
```

Expected result:

```text
startup.lua -> included
src/shared/config.lua -> included
src/sim/scenario_runner.lua -> excluded
tests/test_sim_basic_flow.lua -> excluded
```

## Installer rule

The installer (`installer`, `docs/INSTALL.md`) uses `configs/install/runtime_manifest.json` as the authority: `scripts/manifest_sync.lua` refuses to
list a file the manifest excludes, and `tests/test_installer_manifest.lua` checks every listed file against these rules. The installer itself
(`installer`, `install/**`) is fetched by the computer and never installed.
