# Assumptions and Design Decisions

## Runtime Environment

- **Lua 5.1** via CC:Tweaked in Minecraft 1.21.x (ATM10). The code also runs on 5.4 and LuaJIT; CI runs all three.
- `os.epoch("utc")` is available (CC:Tweaked 1.80.0+). Used for all wall-clock timestamps and heartbeat timeouts. Falls back to `os.time()` (Lua 5.1 unix seconds) in the test harness.
- `os.clock()` is used only for relative timing (net retry, dwell intervals) where TPS-dependence is acceptable.
- `os.time()` is NOT used for timeouts — it returns in-game time (0..24 float) in CC:Tweaked.
- At most 256 events are queued per computer; beyond that CC:Tweaked drops events, timers included. All periodic work therefore runs in the ticker, which notices a missing timer.
- A computer has a disk quota (1 MB by default). `setup.lua` checks the free space; an update stages every file next to the live one first, so a full disk makes the update fail before any live file is touched.

## Network

- All nodes share a single modem channel (broadcast medium).
- `msg.dst` filtering happens at the receiver, not the modem layer.
- Packet loss is assumed possible. All critical messages use `send_reliable` with exponential backoff and are deduplicated at the receiver.
- Heartbeat timeout default: 6 seconds (`heartbeat_timeout_s`). Increase to 15+ on laggy servers.
- Anyone who can transmit on the channel can send messages. The sender checks (master / `cmd_sources` / `ota_sources`) stop mistakes and
  stray computers, not an attacker; there is no cryptography.

## Create Mod Hardware

- Create track switches have **no CC:Tweaked peripheral** in vanilla Create. Must use `adapter="redstone"`.
- Create signals expose `setForcedRed(bool)`. `setAspect`/`getState` are add-on methods, not guaranteed. A vanilla signal cannot be read back,
  so the master sends signals again instead of asking them.
- Create Train Observer exposes `isTrainPassing()` and `getPassingTrainName()`. A detector is a level (a train is over it or not) and the master
  derives `enter` / `leave` from the changes; the level itself is reported in the sensor's heartbeat.
- Create Train Station exposes `setSchedule(table)`, `isTrainPresent()`, `getStationName()`, `getTrainName()`.
- **Not verified in the game**: what a Create signal shows while its computer is off, rebooting or unloaded, and whether `setForcedRed`
  survives a chunk unload. The software does not depend on it (re-sending, RED on stop) but cannot prove it. `docs/INGAME_TESTS.md`
  has the experiment.

## Safety Principles

- **Fail to safe**: any doubt → signals RED. The system never grants permission when uncertain.
- **No implicit trust**: if a node hasn't sent a heartbeat within timeout, all its blocks enter FAULT. They clear again only with evidence
  (node back and stable, detectors report free, no train on its way) or by the operator.
- **A silent train may still be running**: a node timeout keeps the train's blocks, switch locks and corridor claim.
- **Recovery mode**: after master restart with saved state, the system holds in recovery until an operator confirms. This prevents acting on stale state.
- **Atomic writes**: state files and OTA updates use a temporary file, read-back verification and a backup copy; a crash at any point leaves a complete old or new version.
- **A block is a detector**: occupancy is what the block's detectors report. A train that stands still in a block without being over a detector
  is invisible to the system; place detectors so that this cannot happen.

## Scope

- One master per network. Multiple networks would require separate channels and masters.
- The master is single-threaded (CC:Tweaked is single-threaded). All operations are synchronous in the event loop; work is split into bounded steps.
- The system does not track physical train positions beyond block-level (enter/leave events). Exact position within a block is unknown.
- A train longer than two blocks is handled conservatively: its blocks stay reserved until it has left them.
- Service plans provide scheduled multi-stop journeys. Real-time timetables are not supported.
- Network size is not fixed: lists, logs, traces, queues and retries are bounded, and per-event work does not grow with the number of nodes.
