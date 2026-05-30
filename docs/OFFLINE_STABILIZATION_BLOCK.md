# Offline Stabilization Block

This block prepares the next ingame validation without requiring an ingame run yet.

## Added tools

### Create Station Schedule Test

```lua
local t = require("src.tools.create_station_schedule_test")
t.run({ station = "Create_Station_0", destination = "ST-B", dwell_seconds = 5 })
```

By default this is read-only. It only inspects the station and prints train presence.

To apply a test schedule, pass explicit confirmation:

```lua
local t = require("src.tools.create_station_schedule_test")
t.run({ station = "Create_Station_0", destination = "ST-B", dwell_seconds = 5, confirm = true })
```

## Added configs

- `configs/templates/network.create.example.json`
- `configs/templates/network.mixed.example.json`

The create example uses Create Station, Create Signal, and Train Observer peripherals.
The mixed example combines Create peripherals with redstone signal/sensor/switch fallback.

## Panel additions

Panel default pages now include:

- `audit`
- `maintenance`

The renderer shows recent audit entries and maintenance lock state separately from diagnostics.

## Test coverage

Added/updated tests cover:

- safe schedule tool without confirmation
- create/mixed config loading
- audit panel rendering
- maintenance panel rendering

## No ingame test performed

No ingame hardware calls were executed during this block.
