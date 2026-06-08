# Config Validation V2

## Goal

Config Validation V2 catches unsafe or incomplete network configs before runtime.

The validator lives in:

```text
src/shared/validate.lua
```

## Required top-level fields

```text
v = 1
channel = positive integer
master_id = existing master node id
blocks = array
routes = array
nodes = array
```

## ID uniqueness

The validator checks duplicate IDs for:

```text
node.id
train_id
station_id
depot_id
block.id
route.id
service_plan.id
station platform ids within a station
depot track ids within a depot
```

## Node references

Blocks must reference existing node roles:

```text
entry_signal -> signal node
exit_signal  -> signal node
sensors[]    -> sensor node
switches[].id -> switch node
```

Station platforms can reference:

```text
sensor_id -> sensor node
block_id  -> block
```

Depot tracks can reference:

```text
sensor_id -> sensor node
block_id  -> block
```

## Station Create destination names

Station nodes should define an exact Create Train Station destination name:

```json
{
  "id": "ST-B",
  "role": "station",
  "create_station_name": "Hauptbahnhof B"
}
```

This prevents Create schedules from accidentally using internal IDs such as `ST-B` when the actual Create station has a different name.

Supported fields:

```text
create_station_name
create_destination
schedule_destination
create_name
```

## Routes

Routes must have:

```text
id
from
to
at least one block
```

Each route block must exist.

Supported optional conflict fields:

```text
conflict_group
conflict_groups[]
```

Each conflict group must be a non-empty string.

## Service plans

Service plans must have:

```text
id
at least one stop
```

If `train_id` is set, it must reference an existing train.

Stops must provide either:

```text
route_id
```

or:

```text
from + to/destination/station_id
```

If a stop targets a station/depot id that does not exist, it must provide `create_destination` as an explicit external Create destination override.

## Tests

Validation rules are covered in:

```text
tests/test_config.lua
```
