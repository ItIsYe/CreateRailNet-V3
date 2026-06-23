# Assumptions and Design Decisions

## Runtime Environment

- **Lua 5.1** via CC:Tweaked in Minecraft 1.21.x (ATM10).
- `os.epoch("utc")` is available (CC:Tweaked 1.80.0+). Used for all wall-clock timestamps and heartbeat timeouts. Falls back to `os.time()` (Lua 5.1 unix seconds) in the test harness.
- `os.clock()` is used only for relative timing (net retry, dwell intervals) where TPS-dependence is acceptable.
- `os.time()` is NOT used for timeouts — it returns in-game time (0..24 float) in CC:Tweaked.

## Network

- All nodes share a single modem channel (broadcast medium).
- `msg.dst` filtering happens at the receiver, not the modem layer.
- Packet loss is assumed possible. All critical messages use `send_reliable` with exponential backoff.
- Heartbeat timeout default: 6 seconds. Increase to 15+ on laggy servers.

## Create Mod Hardware

- Create track switches have **no CC:Tweaked peripheral** in vanilla Create. Must use `adapter="redstone"`.
- Create signals expose `setForcedRed(bool)`. `setAspect`/`getState` are add-on methods, not guaranteed.
- Create Train Observer exposes `isTrainPassing()` and `getPassingTrainName()`.
- Create Train Station exposes `setSchedule(table)`, `isTrainPresent()`, `getStationName()`, `getTrainName()`.

## Safety Principles

- **Fail to safe**: any doubt → signals RED. The system never grants permission when uncertain.
- **No implicit trust**: if a node hasn't sent a heartbeat within timeout, all its blocks enter FAULT.
- **Recovery mode**: after master restart with saved state, the system holds in recovery until an operator confirms. This prevents acting on stale state.
- **Atomic writes**: state files and OTA updates use temp-file-then-rename to prevent corruption on crash.

## Scope

- One master per network. Multiple networks would require separate channels and masters.
- The master is single-threaded (CC:Tweaked is single-threaded). All operations are synchronous in the event loop.
- The system does not track physical train positions beyond block-level (enter/leave events). Exact position within a block is unknown.
- Service plans provide scheduled multi-stop journeys. Real-time timetables are not supported.
