# Architecture

## Roles
- **MASTER**: central registry, dispatcher, UI, diagnostics.
- **SIGNAL**: controls signal aspects via adapter.
- **SENSOR**: reports block occupancy transitions.
- **SWITCH**: sets turnout positions.
- **STATION/DEPOT/PANEL**: stubs for future expansion.

## Event-Driven Design
- All nodes use a shared `eventbus` to publish/subscribe.
- Polling is minimized. Sensors should publish enter/leave events.

## Block System
- Blocks can be `FREE`, `RESERVED`, `OCCUPIED`, or `FAULT`.
- A block is `RESERVED` during an active route and `OCCUPIED` after enter.

## Fail-Safe Rules
- **If the master cannot verify state, or if nodes are missing, signals are forced to RED.**
- Node timeouts mark referenced blocks as `FAULT`.

## UI
- Master UI uses dirty redraws only, no full redraw loops.
- Panels include overview and diagnostics.
