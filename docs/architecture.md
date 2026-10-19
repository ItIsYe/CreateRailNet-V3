# Architecture

## Roles
- **MASTER**: registry, dispatcher (blocks, routes, interlocking), UI, alerts, log collector, OTA manager, state store.
- **SIGNAL**: sets a signal; starts with RED.
- **SENSOR**: reports enter/leave of a detector and its current level in the heartbeat.
- **SWITCH**: sets a turnout.
- **STATION / DEPOT / TRAIN / PANEL**: station and depot state, the on-train computer, the operator panel.

## Event loop

Every computer runs one loop that waits for events. CC:Tweaked drops events (timers included) once 256 are queued, so nothing waits for
exactly one timer: `src/shared/ticker.lua` owns all periodic jobs (heartbeat, timeouts, UI, OTA, alerts, auto-clear, signal refresh) and, on
every event, compares the job deadlines with the clock and fires jobs whose timer never arrived. A job that fails is logged and re-armed.
`sleep_guard` does the same for long sleeps. Nothing blocks the loop: network retries, OTA transfers and UI redraws are all driven by the
ticker in small steps.

## Dispatcher (`src/master/dispatcher.lua`)

A train asks for a **route**: an ordered list of **blocks**. A request succeeds only if all of this holds, otherwise it is queued with a reason:

1. **Conflict groups** are free (`block:<id>` per block, `opp:` against the opposite direction on the same corridor, explicit groups).
2. **Blocks** are free (or already reserved for this train).
3. **Switch locks**: every switch of the route can be locked in its position; the switches are set.
4. **Interlocking** (`src/domain/interlocking.lua`) sets the Fahrstrasse: checks blocks and conflicts once more, locks flank switches,
   keeps the overlap block. It goes `SET -> OCCUPIED -> DISSOLVING -> VACANT` while the train moves.

Only then are the blocks `RESERVED`. A GREEN or YELLOW aspect is given by one function that asks the interlocking: a live route must
cover the signal and the block behind it must still be ahead of the train. Everything else is RED.

Sensor events move the train: `enter` -> block `OCCUPIED`, `leave` -> block `FREE`, the next block's signal opens. A train that is done
releases locks, groups and the route. Blocks go `FAULT` on garbage events, signal hardware failures and node timeouts; a block that
faulted by timeout clears itself again when the evidence is there (`docs/OPERATIONS.md`), every other fault waits for the operator.

A node timeout keeps the train's claim (it may still be running) but turns its signals RED; a sensor event or a new request of the train
resolves it. `snapshot()` / `restore()` rebuild blocks, trains, queue, switch locks and interlocking routes after a master restart; the
master then waits in recovery mode until an operator confirms.

`pairs()` order differs between runs and Lua versions; wherever order could change behaviour the code sorts first.

## Fail-safe rules

- Anything uncertain is RED: unknown node, FAULT block, recovery, maintenance.
- The master sends signals again instead of trusting what they show: everything at start, a few blocks per second in a rolling refresh,
  all signals of a node that comes back; RED everywhere when the master stops.
- Commands only from the master (and `cmd_sources`); sensor events only from the sensor itself; manual control only from panels;
  updates only from the master and `ota_sources`.
- Files are written with a temporary file, read back, a `.prev` copy and rollback (`safe_write`); over-the-air updates are transactions
  with a journal and an automatic return to the old version (`docs/OTA.md`).

## Network

`src/shared/net.lua`: one channel, reliable messages with retry and backoff, deduplication per `src/id`, fail-closed validation, protocol
major `v` and additive revision `pv` (`docs/protocol.md`). Retries are throttled and ordered so a network with hundreds of nodes does not
flood itself.

## UI

Pages are drawn into an off-screen buffer and shown at once (no flicker), the page order is fixed (status, alerts, setup, overview, gleisbild,
trains, stations, depots, fahrplan, cargo, diag, logs, ota), a failing page shows an error page, and the whole network is summarised in
one lamp on the status page. Alerts are one line per cause and are acknowledged by touch. Everything is bounded and costs one pass over
the nodes and blocks, so the same UI serves a small and a large network.

## Setup, doctor and pairing

`scripts/setup.lua` is the wizard of one computer (`src/setup/`): role, plan, id, devices (modem and monitor bound by name), then the **doctor**
(`src/setup/doctor.lua`: one pass over installation, `startup.lua`, plan, entry, modem, devices of the role, monitor, space, answer of the master), a
**link test** (`src/setup/link.lua`: the wizard sends `pair_probe` and waits a few seconds for `pair_state`) and a summary that is confirmed before anything is written. The
result of the doctor is kept in `crn_status.lua` (`src/shared/setup_status.lua`; globals-free, checked field by field when read).

A computer the master does not know announces itself (`pair_announce`, protocol revision 3). The master keeps it as a bounded candidate in `src/master/pairing.lua` and shows it
on the page *setup* (`src/master/ui/panels/setup.lua`); only the operator's two-touch **[ANNEHMEN]** writes its entry into the plan file (`safe_write`, `.prev` kept).
Nothing in this path switches hardware or releases anything: the plan remains the only source of blocks, routes and signals (`docs/assumptions.md`, "Setup and pairing").

## Installation

`installer` is a thin bootstrap (like the reactor project's): it fetches `install/*.lua` and three shared modules from one ref, compares the files of the role
(`install/manifest.lua`: size and Adler-32, generated from the `require` closure of the role's entry points) with the disk, checks the space, and replaces
only what differs, with a journal that makes an interrupted run resume at the next boot (`startup.lua` guard). Seed files (config templates,
`scripts/start_*.lua`) are never replaced. Updates later go through OTA (`docs/OTA.md`). Details: `docs/INSTALL.md`.

## Testing outside the game

`lua scripts/run_tests.lua` runs the whole suite with Lua 5.1, 5.4 and LuaJIT in CI. Besides unit tests it has seeded random walks over
generated topologies (legal and chaotic call sequences, snapshot round trips, lossy links, crash injection in the filesystem) that check the
safety invariants after every step, and a trace recorder / replayer that reproduces what happened in the game
(`docs/OPERATIONS.md`). What cannot be tested offline is collected in `docs/INGAME_TESTS.md`.
