# Internal Station IDs vs Create Destination Names

## Problem

CreateRailNet uses stable internal IDs for routing and safety, for example:

```text
ST-A
ST-B
DEPOT-1
```

Create trains, however, need the exact visible Create Train Station destination name in their schedule. That name may be different, for example:

```text
Hauptbahnhof B
Cargo Yard 2
Depot 1
```

Because of this, CreateRailNet must not blindly send internal IDs like `ST-B` as Create schedule destinations unless the Create station is actually named `ST-B` ingame.

## Station config

Station nodes can define the real Create destination name:

```json
{
  "id": "ST-B",
  "role": "station",
  "station_type": "passenger",
  "display_name": "Station B",
  "create_station_name": "Hauptbahnhof B",
  "platforms": [
    {"id": "P1", "kind": "passenger", "sensor_id": "OBS-B"}
  ]
}
```

## Service plan override

A service-plan stop can override the Create destination explicitly:

```json
{
  "from": "ST-B",
  "to": "DEPOT-1",
  "route_id": "R-BD",
  "kind": "mixed",
  "dwell_seconds": 0,
  "create_destination": "Depot 1"
}
```

## Resolution order

When CreateRailNet builds a Create schedule entry, it resolves the destination in this order:

1. `stop.create_destination`
2. `stop.create_station_name`
3. `stop.schedule_destination`
4. target station's `create_station_name`
5. target station's `create_destination`
6. target station's `schedule_destination`
7. fallback to internal station id (`stop.to` / `stop.destination` / `stop.station_id`)

## Internal routing remains unchanged

Routes still use internal IDs:

```json
{"id": "R-AB", "from": "ST-A", "to": "ST-B", "blocks": ["B-AB"]}
```

Service plans also continue to use internal IDs for logic:

```json
{"from": "ST-A", "to": "ST-B", "route_id": "R-AB"}
```

Only the Create schedule payload uses the resolved Create destination text.

## Files involved

```text
src/adapter/create_train_schedule.lua
src/domain/stations.lua
src/master/route_integration.lua
```

## Operator rule

Before real operation, every station in the config should have a `create_station_name` matching the actual Create Train Station name used in Minecraft.
