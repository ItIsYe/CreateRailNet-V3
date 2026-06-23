# Create Hardware Adapters

## Create Signal

Create signals expose these methods (confirmed in vanilla Create):

```text
setForcedRed    -- confirmed
```

Methods that may exist in addon signals but NOT guaranteed in vanilla:

```text
getState
isForcedRed
setAspect
listBlockingTrainNames
```

The adapter checks `method_exists()` before calling any optional method and falls back gracefully.

CreateRailNet now prefers `setForcedRed` when available:

- `setAspect("RED")` -> `setForcedRed(true)`
- `setAspect("GREEN")` or `setAspect("YELLOW")` -> `setForcedRed(false)`

If a signal node is configured with `adapter = "redstone"`, the redstone fallback is still used.

## Create Train Observer

Ingame scan showed Train Observer methods:

```text
isTrainPassing
getPassingTrainName
```

CreateRailNet sensor adapter now prefers `isTrainPassing()` for occupancy and exposes `readTrainName(sensor_id)` for the passing train name.

## Recommended config examples

Create signal peripheral:

```json
{"id": "SIG-1", "role": "signal", "peripheral": "Create_Signal_0"}
```

Create train observer peripheral:

```json
{"id": "SEN-1", "role": "sensor", "peripheral": "Create_TrainObserver_0"}
```

Redstone fallback remains valid:

```json
{"id": "SIG-1", "role": "signal", "adapter": "redstone", "side": "right"}
```

## Safe behavior

The adapter performs no automatic signal cycling. It only forces red or clears forced red when the dispatcher requests an aspect change.

## Create Track Switches

**Vanilla Create track switches do NOT expose a CC:Tweaked peripheral.**

Configure switch nodes with `adapter = "redstone"`:

```json
{"id": "SW-1", "role": "switch", "adapter": "redstone", "side": "left", "active_position": "DIVERGING"}
```

The `setPosition()` peripheral path is only for third-party mods that add CC support to track switches.

