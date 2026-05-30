# Offline Testing

## Goal

These checks run without Minecraft/ATM10/Create hardware. They catch syntax errors, config validation errors, require-path errors, and most pure Lua regressions before an ingame test.

## Run locally with Lua

```bash
lua5.4 scripts/check_syntax.lua
lua5.4 scripts/check_configs.lua
lua5.4 scripts/run_tests.lua
```

## Run in CC:Tweaked where possible

```lua
shell.run("scripts/check_configs.lua")
shell.run("scripts/run_tests.lua")
```

`check_syntax.lua` uses `loadfile`, so it is best run under normal Lua or an environment that supports loading files.

## GitHub Actions

The workflow `.github/workflows/offline-tests.yml` runs:

1. syntax check
2. config checks
3. offline tests

It also supports manual `workflow_dispatch`.

## Important limit

Offline checks do not verify real Create peripheral behavior. They do not replace:

- `peripheral_inspector`
- `create_method_finder`
- `create_station_schedule_test`
- real train/station/signal tests

## Recommended flow

1. Run offline checks.
2. Fix any syntax/test/config errors.
3. Run ingame read-only inspection tools.
4. Run `create_station_schedule_test` without confirm.
5. Only then use `confirm=true` for a real schedule application test.
