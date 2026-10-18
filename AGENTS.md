# AGENTS

This repository is greenfield. Keep modules Lua 5.1 compatible, avoid globals, and include file header comments with purpose and public API.

## Working rules (learned from ExtreamReactor-Controller-V3)

- Where a block is cleaner rewritten than patched, rewrite the block.
- Write the regression test first and check that it fails on the old code for the intended reason, not for a typo or a missing argument.
- Never wait for exactly one `os.startTimer` event: CC:Tweaked drops events while 256 are queued, timers included. Periodic work goes through `src/shared/ticker.lua`, sleeps through `src/shared/sleep_guard.lua`.
- Never persist state with delete + `fs.move`. Use `src/shared/safe_write.lua` (verify, `.prev` backup, rollback).
- The test harness must not invent errors the game does not have. Drive loops through injected clocks and timers, not through log lines.
- Run the suite with `lua5.4` and `lua5.1` (CI does both, plus LuaJIT) before pushing.
- Change an old test expectation only with a reason in the commit message.
- Anything that depends on `pairs()` order and changes behaviour (not only a log line) iterates over sorted keys.
- A change to the dispatcher is checked by the seeded random walks (`tests/harness/dispatcher_world.lua`); add the invariant it must keep there, and run a wide hunt (many seeds, all three interpreters) before pushing.
- A new config key goes into `docs/config_reference.md` and `validate.lua`; behaviour that only the game can show goes into `docs/INGAME_TESTS.md`.
