# Assumptions and Design Decisions

## Runtime Environment

- **Lua 5.1** via CC:Tweaked in Minecraft 1.21.x (ATM10). The code also runs on 5.4 and LuaJIT; CI runs all three.
- `os.epoch("utc")` is available (CC:Tweaked 1.80.0+). Used for all wall-clock timestamps and heartbeat timeouts. Falls back to `os.time()` (Lua 5.1 unix seconds) in the test harness.
- `os.clock()` is used only for relative timing (net retry, dwell intervals) where TPS-dependence is acceptable.
- `os.time()` is NOT used for timeouts — it returns in-game time (0..24 float) in CC:Tweaked.
- At most 256 events are queued per computer; beyond that CC:Tweaked drops events, timers included. All periodic work therefore runs in the ticker, which notices a missing timer.
- A computer has a disk quota (1 MB by default). The installer checks the free space before it touches anything; an update stages every file next to the live one first, so a full disk makes the update fail before any live file is touched.
- **Space budget.** The installer's own check decides whether an installation or update fits (the bytes it has to write, one temporary copy of the largest file, a little headroom, against the free space plus the bytes of the files it replaces; it changes nothing when that fails). On top of that the test suite keeps a budget so a computer keeps room for its state files and for an update over the air: **600 000 bytes for a node, 900 000 for the master** (it carries the dispatcher, the operator pages, the setup tools of every role, the planner of whole networks, 57 KB that no other role gets, and since V3 packages P1 and P3 the authentication and the election of two masters, about 100 KB; the Gesamtkonzept 1.0 names about 740 000 as a project target for the master, which this tree passed on purpose (a master of this size needs `computer_space_limit` raised to 2 MB or more for its state, journals and logs): raising `computer_space_limit` on the server or moving the planner and the setup tools to the panel role are the ways back, decided at the integration package P10 with measured numbers). A role that grows past its budget is a decision to make (move code out, or raise `computer_space_limit`), not a number to quietly raise.

## Network

- All nodes share a single modem channel (broadcast medium).
- `msg.dst` filtering happens at the receiver, not the modem layer.
- Packet loss is assumed possible. All critical messages use `send_reliable` with exponential backoff and are deduplicated at the receiver.
- Heartbeat timeout default: 6 seconds (`heartbeat_timeout_s`). Increase to 15+ on laggy servers.
- Anyone who can transmit on the channel can send messages. The sender checks (master / `cmd_sources` / `ota_sources`) stop mistakes and
  stray computers, not an attacker; there is no cryptography.

## Setup and pairing

- **Announcing grants nothing.** A computer that is not in the plan can announce itself to the master (`pair_announce`). It waits as a candidate and is not a node: the master does not
  register it and ignores its events, whatever role it claims; only an operator's deliberate two-touch on the master (**[ANNEHMEN]**) writes its entry into the plan.
  The plan is the one list of who belongs to the network, and an event type is taken from the role that owns it (`docs/protocol.md`). There is no time window in which acceptance happens by itself, because a window
  would turn "someone in range" into "part of the network". Candidates are bounded (64), forgotten after an hour, and everything they send is cut down before it is kept.
- **Setup never actuates hardware.** The wizard and the doctor only read (peripherals, files, the answer of the master); they never switch a signal or a turnout, so there is no
  release gate in the dispatcher. The record `crn_status.lua` (KONFIGURIERT / GEPRUEFT / PRUEFUNG_OFFEN) is information for the operator, not a permission.
- **The function test switches only after a yes.** `scripts/setup.lua --test` is the one place where setup moves a signal or a turnout, and only one action at a time after a deliberate yes (Enter is a no), with the safe state
  (RED / straight) restored afterwards. It does not release anything: the release of the operation (`require_release`) is the operator's decision at the master. Its result is a claim of the computer about itself, like the doctor's.
- **The link test uses ordinary probes.** `--linktest` asks the master the way the doctor does; a computer that is not in the plan appears as a waiting candidate. The filler a probe may ask for is capped at 4000 bytes per answer; anybody
  on the channel can send a probe anyway (the channel is not encrypted), so this adds no new ability. "Answered at the first try" means an answer within 0.35 s, i.e. before the protocol's first retry (0.2 s) would have gone out.
- **The diagnostic file is for sharing.** `crn_diag.txt` holds no plan (only the computer's own entry and a summary) and no secrets, because the system has none; check it anyway before posting it in public.
- **Peripherals are checked against their arguments offline.** `tests/harness/strict_cc.lua` fakes the monitor, window, modem, redstone and peripheral APIs the way CC:Tweaked answers (a fraction as a cursor position, a text that is
  no string, a colour that is no power of two, a channel that is no number raise there and are recorded). The real master application and every node role run on them (`tests/test_master_app.lua`, `tests/test_node_apps.lua`);
  this found a real defect: the modem adapter was written with dots where the adapter's own methods are called with a colon, so it could neither open a channel nor send in the game (fixed, `tests/test_cc_modem.lua`). What
  the fakes cannot know is how the real thing behaves beyond its documented arguments (names, ranges, timing).
- **Monitor sizes.** The pages are laid out for 51 x 19 characters (a 5 x 3 block monitor at text scale 1; a 3 x 2 block monitor at scale 0.5 gives about 58 x 24). Smaller monitors (down to 15 x 10) are drawn without wrong calls
  and without raising, but text and buttons get cut; the size of a monitor of n x m blocks at scale 1 is about (11n - 4) x (7m - 2) characters. How readable the pages are on a real monitor is a matter for `docs/INGAME_TESTS.md`.
- **The planner follows the dispatcher's model, and says where that model stops.** A line is a one-way track: both directions are two tracks with their own blocks, signals and detectors (a detector belongs to one block, a signal faces one way), so a single track used in both directions
  cannot be generated. A platform is not a block: the train waits in front of the entry signal of the first block and has arrived behind the last, because a dispatcher route finishes when the train leaves its last block and the next request of that train is refused until then. A platform that
  is still occupied after its route ended is protected by nothing but the Create signal at the station entrance (`docs/STATION_DEPOT_TRACK_LOGIC.md`). Routes into or out of the same platform exclude each other through a conflict group (`PLAT-<station>-<platform>`), the ladder switches by their locks.
  Verified offline against the real dispatcher (`tests/test_plan_builder_sim.lua`); **not verified in the game**: how `STRAIGHT` / `DIVERGING` of a ladder switch relate to the real turnouts, and that the signals stand where the model puts them.
- **A ref is fixed or it moves.** The installer calls a version tag (`v1.2.0`) or a commit id (7 to 40 hex digits) fixed and every other name a branch; a branch whose name looks like a commit id is taken as fixed. This is a heuristic on the
  name, not a look at GitHub.
- **Devices are bound by name.** A plan entry may name its `modem` and its `monitor`. A named modem that is missing is never replaced by another one (a computer
  must not silently talk through a different network); a missing named monitor falls back to the first one (a display is not safety relevant). Real monitors are called
  `monitor_<n>` or like their side, never `monitor`; the code looks them up by type when no name fits. **Not verified in the game** (read from the CC:Tweaked API): the exact
  names a real computer reports, and the behaviour of wired versus wireless modems.
- **Accepting does not reconfigure a running dispatcher.** The entry is written to the plan file and the master's device lookup follows it, but blocks and routes are built from the
  plan at start: what uses the new computer applies after a restart of the master. A live reload of the dispatcher is not built (it would touch the safety core for a rare operation).
- **The plan is fetched by the computer that needs it, never pushed.** Every computer reads its own plan file. Signal, sensor, switch, train and panel computers need only a short plan; a station or
  depot computer needs its platforms/tracks, so its wizard asks the master for the plan (`plan_get` / `plan_part`), checks it and writes it only after the player's yes. The master never writes a
  plan to another computer, and the OTA paths still exclude `configs/network.json`. The master hands out the file as it lies on its disk when it validates, and only to a station or depot that its
  plan lists with that role; the plan goes over the channel in the clear like everything else (no cryptography, see "Network"). Checks (Adler-32, validation, channel and master, the computer's own
  entry) catch damage and mistakes, not a forged master.
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
