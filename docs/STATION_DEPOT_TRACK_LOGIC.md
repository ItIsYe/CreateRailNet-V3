# Station and Depot Track Logic

## Stations

A station may contain multiple platforms/tracks but still counts as one station in the network.

Platforms support:

- `kind`: `passenger`, `freight`, or `mixed`
- `state`: `EMPTY`, `RESERVED`, `ARRIVING`, `OCCUPIED`, `DWELLING`, `READY_TO_DEPART`, `DEPARTING`, `FAULT`
- `train_id`
- `route_id`
- `destination`
- optional `priority`

Selection rules:

1. Offline or faulty stations are unavailable.
2. Only `EMPTY` platforms are considered free.
3. Platform kind must match the request kind, unless one side is `mixed`.
4. Higher priority platforms are preferred.
5. Ties are sorted by platform id.

## Depots

Depots contain tracks/staging slots.

Tracks support:

- `kind`: `storage`, `staging`, or `mixed`
- `state`: `EMPTY`, `RESERVED`, `OCCUPIED`, `STAGING`, `READY`, `DEPARTING`, `LOCKED`, `FAULT`
- `train_id`
- `route_id`
- `destination`
- optional `priority`

Selection rules:

1. Offline or faulty depots are unavailable.
2. `EMPTY`, `READY`, and `STAGING` tracks may be selected.
3. Track kind must match the request kind, unless one side is `mixed`.
4. Higher priority tracks are preferred.
5. Ties are sorted by track id.

## Route integration

When a station/depot event includes an explicit `platform_id` or `track_id`, that specific entry is updated.

If no explicit id is included, CreateRailNet tries to reserve a matching free platform/track automatically.

## Queue behavior

Depot queues now sort by priority first and sequence number second.

## Current limits

The logic reserves platforms/tracks at the domain level. It does not yet perform physical block-level platform occupancy confirmation by sensor; that remains part of the next integration hardening step.
