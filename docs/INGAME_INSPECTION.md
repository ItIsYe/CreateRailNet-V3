# Ingame Peripheral / Create Inspection

## Goal

Use this before finalizing the ATM10/Create hardware adapters.
All tools in this document are read-only unless explicitly noted. They do not toggle signals, switches, or train controls.

## 1. Peripheral Inspector

Run on each computer:

```lua
local insp = require("src.tools.peripheral_inspector")
insp.run({ write = "crn_peripheral_report.json" })
```

For one side only:

```lua
local insp = require("src.tools.peripheral_inspector")
insp.run({ side = "left", write = "crn_left_report.json" })
```

Send back the generated report or paste the printed method list.

## 2. Create Method Finder

Run on train computers and any station/control computer connected to Create peripherals:

```lua
local finder = require("src.tools.create_method_finder")
finder.run()
```

This searches method names for terms like train, schedule, station, destination, speed, track, signal, and switch.

## 3. Hardware Binding Report

Run after your config has the right node IDs and sides:

```lua
local hw = require("src.tools.hardware_binding_report")
hw.run({ config = "configs/templates/network.full.example.json" })
```

This compares config bindings against visible peripherals and side names.

## 4. Redstone Side Report

Run on computers with redstone-bound sensors, signals, or switches:

```lua
local rs = require("src.tools.redstone_side_report")
rs.run({ config = "configs/templates/network.full.example.json" })
```

This only reads `redstone.getInput` and `redstone.getOutput`. It does not set outputs.

## 5. What to send back

For Create Train Schedule finalization, send:

- peripheral type of the onboard train computer
- all methods containing train/schedule/station/destination/speed
- whether the train peripheral is on a side or named peripheral
- any method errors printed by the tools

## 6. Safe order

1. Run `scripts/run_tests.lua`.
2. Run config check.
3. Run peripheral inspector.
4. Run Create method finder.
5. Run hardware binding report.
6. Run redstone side report.
7. Only after that, enable real route dispatching.
