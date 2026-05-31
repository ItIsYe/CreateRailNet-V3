# Recovery and Reconnect V1

## Goal

CreateRailNet must not blindly free routes, station platforms, or depot tracks when a node disappears or restarts.

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

## Important limitation

Dispatcher block state is still controlled by route/sensor flow. Recovery V1 prevents station/depot tracks from appearing falsely free, but full persistent dispatcher recovery is a later block.

## Files involved

```text
src/nodes/train_node.lua
src/domain/trains.lua
src/nodes/station_node.lua
src/domain/stations.lua
src/nodes/depot_node.lua
src/domain/depots.lua
src/master/runtime.lua
tests/test_sensor_occupancy_flow.lua
```
