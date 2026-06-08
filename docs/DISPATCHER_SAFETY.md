# Dispatcher Safety V3

## Goal

Dispatcher Safety V3 adds route direction and conflict-group diagnostics on top of block reservation and switch locks.

The dispatcher must prevent unsafe route overlap such as two trains entering the same section from opposite directions.

## Existing safety layers

Before V3, the dispatcher already used:

```text
block FREE / RESERVED / OCCUPIED / FAULT
switch locks
route queue
sensor enter/leave flow
recovery snapshot/restore
```

## New route direction

Every route has a direction string:

```text
from -> to
```

Example:

```text
R-AB = ST-A->ST-B
R-BA = ST-B->ST-A
```

The direction is stored on train state and queue items for diagnostics.

## Conflict groups

Every route now contributes conflict groups.

Explicit config fields are supported:

```json
{
  "id": "R-AB",
  "from": "ST-A",
  "to": "ST-B",
  "blocks": ["B-AB"],
  "conflict_group": "MAIN-AB"
}
```

or:

```json
{
  "id": "R-AB",
  "conflict_groups": ["MAIN-AB", "YARD-1"]
}
```

The dispatcher also derives automatic groups:

```text
dir:ST-A<->ST-B
block:B-AB
```

## Opposite direction conflict

If `R-AB` is active, `R-BA` shares:

```text
dir:ST-A<->ST-B
```

Therefore `R-BA` is blocked or queued while `R-AB` is reserved/running.

The queue item records:

```text
direction = ST-B->ST-A
reason = opposite direction conflict: dir:ST-A<->ST-B
conflict_group = dir:ST-A<->ST-B
blocked_by = TRAIN-1
```

## Active conflicts

The dispatcher tracks active route conflicts through:

```lua
dispatcher.get_conflicts()
```

Entries include:

```text
owner
train_id
route_id
direction
```

Conflict groups are released when the train finishes its route.

## Snapshot/restore

Dispatcher snapshots now include active conflicts:

```text
active_conflicts
```

On restore, active conflicts are rebuilt from active trains and restored snapshot data.

This prevents a restored master from forgetting that a direction/section is still locked.

## Files involved

```text
src/master/dispatcher.lua
tests/test_dispatcher_multitrain.lua
tests/test_dispatcher_recovery.lua
```

## Current limitation

Conflict-group support is dispatcher-level. Config validation should still be tightened so bad or duplicate route definitions are caught before runtime.
