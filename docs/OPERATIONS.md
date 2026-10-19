# Operations

What the master shows, what the operator can do about it, and the config keys that belong to it. Written for a network of any size:
everything below is bounded (lists, logs, traces) and costs one pass over the nodes and blocks.

## Pages of the master monitor

Left or right edge of the monitor: previous or next page. Order: **status**, **alerts**, **setup** (titled EINRICHTUNG), overview, gleisbild, trains, stations, depots,
fahrplan, cargo, diag, **logs**, ota.

| Page | Shows |
|---|---|
| status | one lamp for the whole network and why: RED = a signal/switch/sensor node is lost, a block is FAULT, the recovery waits for confirmation, an update failed; YELLOW = another node lost, deadlock, maintenance, update running, unacknowledged alerts. Counts per role and a paged problem list, faults before nodes that are merely offline. The words BETRIEB OK / WARNUNG / STOERUNG are shown next to the colour. |
| alerts | one line per cause with a counter. Touch a row to acknowledge it, "ALLE QUITT." for all. A fault that cleared itself stays listed until it was acknowledged. |
| logs | warnings and errors the nodes forwarded, newest first; the bottom row switches WARN+/ERROR and pages. |
| setup | how far the setup is (four lines, each with a word as well as a colour: plan has blocks and routes, computers of the plan online, they reported a clean check, nobody waiting) and the computers that announced themselves and are not in the plan. See "Accepting new computers" below. |

Frames are drawn off screen and shown at once, so the monitors do not flicker. A page whose drawing fails shows an error page, navigation keeps
working, and the failure is logged once a minute.

## Accepting new computers

A computer that is not in the plan announces itself (protocol revision 3, `docs/protocol.md`) and waits on the page *setup* (EINRICHTUNG); the
alert "Neuer Computer wartet: <id> (<rolle>)" (yellow) points at it. Touch its row, then **[ANNEHMEN]**: the first touch asks (the button reads `[SICHER?]` for 8 s), the second writes its
entry into the plan file (`configs/network.json`; the old file stays as `.prev`) and tells the computer. **[ABLEHNEN]** ignores that id for 10 minutes.
A computer whose id stands in the plan with another role is shown red and cannot be accepted; fix the id or the role first.

- Announcing grants nothing. A waiting computer is not registered, its events are ignored (also `manual_control` from something that calls itself a panel),
  it gets no commands and no panel snapshot, and it is forgotten after an hour of silence; at most 64 wait at once. The same holds for a computer whose id is in
  the plan with another role.
- Accepting writes the entry only. Blocks, routes and signals still come from the plan, so a new signal node does nothing until the plan uses its id; the
  dispatcher is built from the plan at start, so **blocks and routes that use a new computer apply after a restart of the master** (the acceptance message says so).
  The master's lookup of device names (`modem`, `peripheral`, `side`) follows the plan at once.
- **When updating a network that ran before this rule:** every computer must be listed in the master's plan (the documentation always required that). A computer that was
  not listed used to be adopted by its heartbeat; it now waits on the setup page. Open that page after the update and accept the ones that belong to the network.
- A master that runs on a bundled template (`configs/templates/...`) or on a plan that does not validate refuses to write and says why; create
  an own plan with `scripts/setup.lua` first (`--check` names the errors).
- A computer of the plan shows what it reported about its own setup (`crn_status.lua`: KONFIGURIERT / GEPRUEFT / PRUEFUNG_OFFEN, shown as "Selbsttest ok" / "Selbsttest offen"). This is information for the
  operator, not a release: setup never switches a signal or a turnout, and the dispatcher does not wait for it.
- Audit: `pair_candidate`, `pair_conflict`, `node_accepted`, `pair_rejected`.

## Repairing a fault

A block goes FAULT when a sensor sends garbage, a signal cannot be set, or a node times out. Faults from a **node timeout** clear themselves
(below); the others stay FAULT until an operator clears them (`manual_control`, blocked while maintenance mode is on):

- `clear_fault {block_id}`: FAULT -> FREE with a RED signal. Refused for a block that belongs to a train on its way.
- `release_train {train_id}`: releases the blocks, switch locks and corridor claim of a train the master lost (node timeout); blocks in FAULT stay FAULT.
- `ack_alert {key | all = true}`, `trace_dump`, `ota_push {node_id?, version?}`.

### Blocks that clear themselves

A block that went FAULT because a node timed out (chunk unloaded, computer off) is cleared by the master when all of this holds:

1. every node of the cause is up again and has stayed up for `auto_clear_stable_s` (15 s),
2. every sensor of the block reported "free" after that moment (the sensors send their detector level in the heartbeat; a report older than
   `auto_clear_max_age_s`, 10 s, does not count),
3. the block has at least one sensor, and no train on its way holds it.

A timed-out train that holds the block is released together with it, but only if every block it holds meets the same test (FAULT ones by node
timeout, the others with a free sensor). Garbage events, signal hardware failures, blocks without a sensor and anything an old snapshot cannot
explain stay FAULT. Every step is audited as `fault_auto_cleared`, the queue is processed afterwards. Switch it off with
`auto_clear_faults = false`; it pauses in maintenance mode and while the recovery waits for confirmation. The assumption behind it: a train that is not over any detector of its blocks is not in them (`docs/assumptions.md`).

A train whose node timed out keeps its blocks, switch locks and corridor claim (it may still be running: chunk unloaded, computer off) but its signals
show RED. A sensor event brings it back to RUNNING; a new route request of that train releases the old claim.

## Signals

Vanilla Create signals cannot be read back, so the master does not trust what they show. At start it sends every signal (RED, except the next
block of a waiting train, which gets its GREEN back after a restore); afterwards `signal_refresh_per_s` (default 2) blocks per second, round robin,
so a signal that lost its state is corrected within one round; a signal node that registers or comes back gets its signals at once. A signal node
starts with RED. When the master stops (Ctrl+T or a crash) it puts every signal to RED first (`signal_red_on_stop`), so trains stop in front of
signals instead of running unobserved; block and train state are saved and the restart restores them. Failing sends are counted and logged once
per change; they do not fault blocks. What a Create signal does while its computer is off is not verified (`docs/INGAME_TESTS.md`).

## The gleisbild page

Blocks show their state colour and, below the block, the id of the Fahrstrasse that holds it; the third line lists every live Fahrstrasse
with its state (`SET` green, `OCCU` orange, `DISS` yellow). `gleisbild_pos` in the block config places blocks on the monitor.

## Traces

The master keeps the last 500 dispatcher calls (`config.trace_capacity`). When a block faults, they are written to `traces/fault_1.json` ... `fault_5.json`
(at most once a minute); `trace_dump` writes `traces/trace_1.json` ... `trace_5.json`. Copy a file next to a checkout of the repository and run

    lua scripts/replay_trace.lua traces/fault_1.json configs/network.json [--strict]

It rebuilds the dispatcher from the config, replays the calls on the recorded clock, prints every call whose result differs from the game and every
safety invariant that breaks. `tests/test_trace_recorder.lua` records random runs and replays them: the results have to be identical.

## Config keys

| Key | Default | Meaning |
|---|---|---|
| `cmd_sources` | master only | extra sender ids a node accepts commands from |
| `ota_sources` | `{"OTA-TOOL"}` | sender ids that may start an update (plus the master) |
| `log_forward` | on | `false` keeps a node's warnings to itself |
| `log_sink` | master | node id that receives the forwarded log |
| `trace_capacity` | 500 | dispatcher calls kept for replay |
| `state_file` | `state/master_state.json` | dispatcher snapshot (written with a `.prev` backup) |
| `auto_clear_faults` | `true` | blocks faulted by a node timeout clear themselves (see above) |
| `auto_clear_stable_s` / `auto_clear_max_age_s` | 15 / 10 | how long the nodes must be back / how old a "free" report may be |
| `signal_refresh_per_s` | 2 | blocks whose signals are sent again per second, `0` = off |
| `signal_red_on_stop` | `true` | every signal to RED when the master stops |
| `heartbeat_timeout_s` | 6 | silence after which a node is DOWN |
| `startup_autoupgrade` | `true` | nodes add the OTA recovery to an old `startup.lua` (`docs/OTA.md`) |

The complete list is in `docs/config_reference.md`.

## Open points

- A train that is longer than two blocks and a sensor that never reports are handled conservatively (blocks stay reserved until the train
  arrives), not intelligently.
- What a Create signal shows while its computer is off or rebooting is not verified in game (`docs/INGAME_TESTS.md`).
- A train that stands still inside a block without being over a detector is invisible; the automatic clearing assumes this does not happen.
