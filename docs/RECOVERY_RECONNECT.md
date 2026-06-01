# Recovery and Reconnect V1/V2/V3

## Goal

CreateRailNet must not blindly free routes, blocks, station platforms, or depot tracks when a node disappears or restarts.

A disconnected node means the physical state is unknown until the node reconnects and sends a fresh snapshot.

## Train reconnect

Train register/heartbeat payloads include:

```text
train_id
state
route_id
destination
create_destination
service_plan
service_stop_index
schedule_state
schedule_station
message
```

The master keeps these fields in the train registry.

If schedule application fails, the train reports:

```text
state = SCHEDULE_FAILED
schedule_state = failed
message = error text
```

## Station reconnect

Station nodes now send a full platform snapshot on startup/register:

```text
station_id
state
platforms
```

Each platform includes:

```text
platform_id
kind
state
train_id
train_name
sensor_id
block_id
```

The master applies this snapshot to the station registry.

## Depot reconnect

Depot nodes now send a full track snapshot on startup/register:

```text
depot_id
state
tracks
```

Each track includes:

```text
track_id
kind
state
train_id
train_name
sensor_id
block_id
route_id
destination
```

The master applies this snapshot to the depot registry.

## Offline behavior

When a station times out:

```text
station.state = OFFLINE
platform.state = UNKNOWN
platform.recovery_required = true
```

When a depot times out:

```text
depot.state = OFFLINE
track.state = UNKNOWN
track.recovery_required = true
```

This prevents the system from presenting offline platforms/tracks as safely free.

## Reconnect behavior

When the node reconnects and sends a full snapshot:

```text
state returns to ONLINE
platform/track states are overwritten by the fresh snapshot
recovery_required is cleared by the incoming state payload if absent/false
```

## Dispatcher recovery V2

The dispatcher supports in-memory snapshot/restore:

```lua
dispatcher.snapshot()
dispatcher.restore(snapshot)
```

The snapshot contains:

```text
blocks
trains
queue
deadlocks
switch_locks
```

The restore path keeps reserved and occupied blocks reserved/occupied. It does not turn them into FREE.

### Reserved block example

Before restart:

```text
B1.state = RESERVED
B1.reserved_by = TRAIN-1
TRAIN-1.state = RESERVED
```

After restore:

```text
B1.state = RESERVED
B1.reserved_by = TRAIN-1
TRAIN-1.state = RESERVED
```

### Occupied block example

Before restart:

```text
B1.state = OCCUPIED
B1.reserved_by = TRAIN-1
TRAIN-1.state = RUNNING
TRAIN-1.current_block = B1
```

After restore:

```text
B1.state = OCCUPIED
B1.reserved_by = TRAIN-1
TRAIN-1.state = RUNNING
TRAIN-1.current_block = B1
```

### Queue recovery

Queued route requests are restored into a fresh queue object so they can continue being processed after recovery.

## Persistent recovery V3

The master runtime now persists dispatcher snapshots to disk through:

```text
src/domain/master_state_store.lua
```

Default state file:

```text
state/master_state.json
```

A config can override it with:

```json
{
  "state_file": "state/my_network_master_state.json"
}
```

### Save triggers

The master saves a dispatcher snapshot after safety-relevant events, including:

```text
register/reconnect
sensor enter/leave
route request
train arrival
station departure request
depot dispatch request
manual control
timeout
dwell processing
```

### Restore trigger

On `runtime.start()`, the master tries to load the saved dispatcher snapshot and calls:

```lua
dispatcher.restore(snapshot)
```

If no file exists, restore is skipped with `missing`.

### Panel diagnostics

The panel snapshot includes:

```text
diagnostics.recovery.restored
diagnostics.recovery.saved
diagnostics.recovery.last_error
diagnostics.recovery.last_save_reason
```

## Important limitation

Persistent recovery V3 persists dispatcher state only. Station/depot physical occupancy still depends on reconnect snapshots from the station/depot nodes. If there is doubt after a real reboot, operator review is still required before clearing UNKNOWN or FAULT states.

## Files involved

```text
src/nodes/train_node.lua
src/domain/trains.lua
src/nodes/station_node.lua
src/domain/stations.lua
src/nodes/depot_node.lua
src/domain/depots.lua
src/domain/master_state_store.lua
src/master/runtime.lua
src/master/dispatcher.lua
tests/test_sensor_occupancy_flow.lua
tests/test_dispatcher_recovery.lua
tests/test_master_state_store.lua
```
