# Assumptions and Design Decisions

## Runtime Environment

- **Lua 5.1** via CC:Tweaked in Minecraft 1.21.x (ATM10). The code also runs on 5.4 and LuaJIT; CI runs all three.
- `os.epoch("utc")` is available (CC:Tweaked 1.80.0+). Used for all wall-clock timestamps and heartbeat timeouts. Falls back to `os.time()` (Lua 5.1 unix seconds) in the test harness.
- `os.clock()` is used only for relative timing (net retry, dwell intervals) where TPS-dependence is acceptable.
- `os.time()` is NOT used for timeouts — it returns in-game time (0..24 float) in CC:Tweaked.
- At most 256 events are queued per computer; beyond that CC:Tweaked drops events, timers included. All periodic work therefore runs in the ticker, which notices a missing timer.
- A computer has a disk quota (1 MB by default). The installer checks the free space before it touches anything; an update stages every file next to the live one first, so a full disk makes the update fail before any live file is touched.

## Network

- All nodes share a single modem channel (broadcast medium).
- `msg.dst` filtering happens at the receiver, not the modem layer.
- Packet loss is assumed possible. All critical messages use `send_reliable` with exponential backoff and are deduplicated at the receiver.
- Heartbeat timeout default: 6 seconds (`heartbeat_timeout_s`). Increase to 15+ on laggy servers.
- Anyone who can transmit on the channel can send messages. The sender checks (master / `cmd_sources` / `ota_sources`) stop mistakes and
  stray computers, not an attacker; there is no cryptography.

## Setup and pairing

- **Announcing grants nothing.** A computer that is not in the plan can announce itself to the master (`pair_announce`). It waits as a candidate; only an operator's
  deliberate two-touch on the master (**[ANNEHMEN]**) writes its entry into the plan. There is no time window in which acceptance happens by itself, because a window
  would turn "someone in range" into "part of the network". Candidates are bounded (64), forgotten after an hour, and everything they send is cut down before it is kept.
- **Setup never actuates hardware.** The wizard and the doctor only read (peripherals, files, the answer of the master); they never switch a signal or a turnout, so there is no
  release gate in the dispatcher. The record `crn_status.lua` (KONFIGURIERT / GEPRUEFT / PRUEFUNG_OFFEN) is information for the operator, not a permission.
- **Devices are bound by name.** A plan entry may name its `modem` and its `monitor`. A named modem that is missing is never replaced by another one (a computer
  must not silently talk through a different network); a missing named monitor falls back to the first one (a display is not safety relevant). Real monitors are called
  `monitor_<n>` or like their side, never `monitor`; the code looks them up by type when no name fits. **Not verified in the game** (read from the CC:Tweaked API): the exact
  names a real computer reports, and the behaviour of wired versus wireless modems.
- **No distribution of the plan.** Every computer reads its own plan file. Signal, sensor, switch, train and panel computers need only a short plan; a station or depot
  computer needs its platforms/tracks in its own plan, so it needs the full plan copied (the doctor says so). Distributing plans is not built.
- **On-screen text is ASCII.** The terminal shows bytes; umlauts would depend on the font and the CC version, so wizard, installer and master page write `ae oe ue ss`. Whether
  a real terminal could show umlauts is a test in `docs/INGAME_TESTS.md`, not an assumption.

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
