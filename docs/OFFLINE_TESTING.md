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

## Fakes that check their arguments

Most fakes of the suite accept any call, and the code wraps many monitor calls in `pcall`, so a call with wrong arguments would only show up in the game (as an empty screen). `tests/harness/strict_cc.lua`
fakes the monitor, window, modem, redstone and peripheral APIs the way CC:Tweaked answers: a fraction as a cursor position, a text that is no string, a colour that is no power of two, a channel that is no number or a
bad text scale raise the error the game raises and are recorded in `violations`. Two test files run the real thing on them: `tests/test_master_app.lua` starts `src/master/app.lua` (all pages, a touch grid, small
monitors from 51 x 19 down to 15 x 10, signals through redstone) and `tests/test_node_apps.lua` starts every node role from the plan file the wizard writes. A new adapter or page should be started this way once. This
found a real defect already (the modem adapter was called with a colon but written with a dot, `tests/test_cc_modem.lua`). The fakes still only know the documented API: names, ranges and timing of the real devices need the game.

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
