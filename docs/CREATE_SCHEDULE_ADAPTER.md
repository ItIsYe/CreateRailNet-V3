# Create Train Schedule Adapter

## Current integration model

CreateRailNet-V3 applies train schedules through a Create Train Station peripheral, not through a direct train peripheral.

The train computer config should include the station peripheral name found by the ingame scanner:

```json
{
  "id": "TRAIN-1",
  "role": "train",
  "train_id": "TRAIN-1",
  "create_station": "Create_Station_0",
  "schedule_station": "Create_Station_0"
}
```

## Official Create schedule shape

The adapter builds schedules with this shape:

```lua
{
  cyclic = false,
  entries = {
    {
      instruction = {
        id = "create:destination",
        data = { text = "ST-B" }
      },
      conditions = {
        {
          {
            id = "create:delay",
            data = { value = 10, time_unit = 1 }
          }
        }
      }
    }
  }
}
```

`time_unit = 1` is used for seconds.

## Runtime guard

Before calling `setSchedule(schedule)`, the adapter checks:

```lua
station.isTrainPresent()
```

If no train is present, the adapter returns:

```text
no train present at station
```

and does not call `setSchedule`.

## Important ingame requirement

The train must be present at the Create Station when the onboard computer receives the `set_schedule` command. If the schedule fails with `no train present at station`, move or assemble the train at the station and retry registration/service-plan sending.

## Mapping from service plan

Each service-plan stop becomes one `create:destination` entry:

- `stop.station_name`, `stop.station_id`, `stop.to`, or `stop.destination` -> `instruction.data.text`
- `stop.dwell_seconds` -> `create:delay.data.value`

## Safe test flow

1. Run `src.tools.peripheral_inspector` on the train computer.
2. Confirm the station peripheral name, e.g. `Create_Station_0`.
3. Put that name into `create_station` / `schedule_station`.
4. Ensure a train is present at the station.
5. Start the train node and watch `schedule_state`.
