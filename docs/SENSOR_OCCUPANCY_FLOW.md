# Sensor Occupancy Flow

## Goal

Station platforms and depot tracks should follow the physical sensor state instead of only relying on planned reservations.

## Supported sensor sources

CreateRailNet sensor adapters support:

- Redstone input sensors
- Create Train Observer via `isTrainPassing()`
- Train name detection via `getPassingTrainName()` when available

## Station flow

When a platform sensor changes from free to occupied:

1. Station node reads `readOccupied(sensor_id)`.
2. If available, it reads `readTrainName(sensor_id)`.
3. Platform state becomes `DWELLING`.
4. Station sends `train_arrived_station` with `train_id` / `train_name`.
5. Master updates the platform to `DWELLING`.

When the platform remains occupied past `dwell_seconds`:

1. Platform state becomes `READY_TO_DEPART`.
2. Station sends `station_ready_departure`.
3. Master requests/reserves the next route, unless maintenance is active.

When the platform sensor changes from occupied to free:

1. Station sends `train_left_station`.
2. Local platform state becomes `EMPTY`.
3. Master releases the platform through `release_platform`.

## Depot flow

When a depot track sensor changes from free to occupied:

1. Depot node reads the sensor.
2. If available, it reads the passing train name.
3. Track state becomes `OCCUPIED`.
4. Depot sends `depot_train_arrived`.
5. Master updates the depot track.

When a train remains on a depot track past `ready_after_seconds`:

1. Track state becomes `READY`.
2. Depot sends `depot_train_ready`.

When the track sensor changes from occupied to free:

1. Depot sends `depot_train_left`.
2. Local track state becomes `EMPTY`.
3. Master releases the track through `release_track`.

## Known limits

- If a Train Observer returns only a train name and not the internal CreateRailNet train id, the name is used as fallback.
- Dispatcher block release still depends on route sensor events. Platform/track release and block release are separate safety layers.
- Maintenance mode blocks departure/dispatch requests but still allows occupancy updates so the operator sees the physical state.
