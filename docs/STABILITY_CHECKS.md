# CreateRailNet-V3 Stability Checks

## Goal

This checklist is the first step before ingame hardware tests.

## Run all tests

```lua
shell.run("scripts/run_tests.lua")
```

or:

```lua
dofile("tests/harness/runner.lua")
```

## What the test runner now checks

- CC:Tweaked compatibility bootstrap loads.
- Test files load failures are counted as failures.
- Tests run in deterministic sorted order inside each test file.
- Core modules can be required.
- Main example configs load and validate.
- Config loader reports missing files cleanly.
- Audit and diagnostics API shapes are stable.

## Important note

These tests do not replace real ATM10 / Create ingame validation. They reduce syntax, require-path, config, and API-shape mistakes before connecting hardware.

## Recommended sequence

1. Run `scripts/run_tests.lua`.
2. Run `src.tools.check_config` on the chosen config.
3. Run `src.tools.system_check`.
4. Run `src.tools.peripheral_inspector` on every real computer.
5. Only then connect or enable real signal, switch, and train hardware.
