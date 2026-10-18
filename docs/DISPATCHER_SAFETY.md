# Dispatcher Safety

The dispatcher keeps trains apart with several layers. A route is granted only if **every** layer agrees; a request that fails is queued with the
reason (`get_queue()`: `reason`, `blocked_by`, `conflict_group`, `direction`).

| Layer | Question | Where |
|---|---|---|
| conflict groups | is the corridor / block free of other trains and of the opposite direction? | `dispatcher.lua` |
| blocks | `FREE`, or already reserved for this train? | `blocks.lua` |
| switch locks | can every switch be locked in the position the route needs? | `switch_locks.lua` |
| interlocking | is the Fahrstrasse settable (blocks, conflicts with other live routes, flank switches, overlap block)? | `interlocking.lua` |
| signals | does a live route cover this signal and is the block still ahead of the train? | `dispatcher.lua` + `interlocking.lua` |

## Route direction and conflict groups

Every route has a direction `from->to`, stored on the train and on queue items. Each route contributes conflict groups:

- `block:<id>` per block: only one train per block, always exclusive.
- `opp:<A><-><B>` for the corridor between its two ends: a route in the opposite direction is refused while one is active, routes in the **same**
  direction share the group. When the holder finishes, another active train that still needs the group takes it over instead of the group
  disappearing under it.
- `conflict_group` / `conflict_groups` of the route in the config.

```json
{ "id": "R-AB", "from": "ST-A", "to": "ST-B", "blocks": ["B-AB"], "conflict_groups": ["MAIN-AB", "YARD-1"] }
```

Groups are released when the train finishes its route or is released by the operator. `get_conflicts()` lists the active ones.

## Interlocking (Fahrstrasse)

`reserve_route` sets the Fahrstrasse before the blocks are reserved. It checks the blocks and the conflicts with other live routes once more, locks
the switches and the **flank protection** switches (`interlocking_routes[].flank_protection`; the dispatcher also sets them physically), and keeps
the **overlap block** (`overlap_block`) reserved for the train. Status: `SET` (set, train not in yet), `OCCUPIED`, `DISSOLVING` (blocks are cleared one
by one as the train passes), then gone. A refusal queues the request like any other conflict.

GREEN / YELLOW are given by `set_proceed_aspect` only: the signal must belong to a live route and its block must be `RESERVED` for that route's
train and not yet cleared. Otherwise the signal is forced to RED. The manual `set_signal` goes through the same check. A train that enters its
overlap block turns it FAULT (it ran past its exit signal).

## FAULT

A block goes FAULT on garbage sensor events, signal hardware failure and node timeouts, and records the first cause (`node_timeout` with the nodes,
`signal`, `event`). A FAULT block never shows a proceed signal and is never reserved. A train that timed out (`FAULT`) keeps its blocks, switch
locks, corridor claim and Fahrstrasse because it may still be running; a sensor event brings it back, a new request releases the claim.
Only `node_timeout` faults are cleared automatically, see `docs/OPERATIONS.md`.

## Snapshot / restore

`snapshot()` holds blocks (with the fault cause), trains (with `holds_route`), queue, switch locks and conflicts. `restore()` rebuilds the switch
locks and the interlocking routes from the trains that were on their way (earlier versions forgot the switch locks of running trains), restores the
conflict groups and gives waiting trains their GREEN back. A snapshot that contradicts itself (two trains needing one switch) turns the blocks of
the later train FAULT instead of being believed.

## Tests

`tests/test_dispatcher_property.lua` and `tests/test_dispatcher_chaos.lua` run seeded random walks over generated networks (also with flank
protection and overlap blocks) and check after every step, among others: no block with an inconsistent owner, nothing owned by a train that is
gone, no proceed signal without a waiting train and the interlocking's permission, no leaked switch lock / conflict group / interlocking route,
signals agree after a snapshot round trip, auto-clear and signal refresh. `tests/test_dispatcher_regressions.lua` and
`tests/test_interlocking_integration.lua` pin the bugs they found. A failing seed prints its number and the last operations.
