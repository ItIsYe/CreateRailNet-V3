# Operations

What the master shows, what the operator can do about it, and the config keys that belong to it. Written for a network of any size:
everything below is bounded (lists, logs, traces) and costs one pass over the nodes and blocks.

## Pages of the master monitor

Left or right edge of the monitor: previous or next page. Order: **status**, **alerts**, overview, gleisbild, trains, stations, depots,
fahrplan, cargo, diag, **logs**, ota.

| Page | Shows |
|---|---|
| status | one lamp for the whole network and why: RED = a signal/switch/sensor node is lost, a block is FAULT, the recovery waits for confirmation, an update failed; YELLOW = another node lost, deadlock, maintenance, update running, unacknowledged alerts. Counts per role and a paged problem list, faults before nodes that are merely offline. The words BETRIEB OK / WARNUNG / STOERUNG are shown next to the colour. |
| alerts | one line per cause with a counter. Touch a row to acknowledge it, "ALLE QUITT." for all. A fault that cleared itself stays listed until it was acknowledged. |
| logs | warnings and errors the nodes forwarded, newest first; the bottom row switches WARN+/ERROR and pages. |

Frames are drawn off screen and shown at once, so the monitors do not flicker. A page whose drawing fails shows an error page, navigation keeps
working, and the failure is logged once a minute.

## Repairing a fault

A block goes FAULT when a sensor sends garbage, a signal cannot be set, or a node times out. It stays FAULT until an operator clears it
(`manual_control`, blocked while maintenance mode is on):

- `clear_fault {block_id}`: FAULT -> FREE with a RED signal. Refused for a block that belongs to a train on its way.
- `release_train {train_id}`: releases the blocks, switch locks and corridor claim of a train the master lost (node timeout); blocks in FAULT stay FAULT.
- `ack_alert {key | all = true}`, `trace_dump`, `ota_push {node_id?, version?}`.

A train whose node timed out keeps its blocks, switch locks and corridor claim (it may still be running: chunk unloaded, computer off) but its signals
show RED. A sensor event brings it back to RUNNING; a new route request of that train releases the old claim.

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

## Open points

- A block that faulted because a node was lost is not cleared automatically when the node comes back: the sensor would have to report its
  state on registration, and a train that entered unnoticed would then stand on a "free" block. Today an operator clears it.
- A train that is longer than two blocks and a sensor that never reports are handled conservatively (blocks stay reserved until the train arrives),
  not intelligently.
- What a Create signal shows while its computer is off or rebooting is not verified in game (see `docs/OTA.md`).
