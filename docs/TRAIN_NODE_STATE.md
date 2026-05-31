# Train Node State Model

## Purpose

The train node represents the onboard computer of one train.

It keeps local display state and reports the current state back to the master.

## Internal destination vs Create destination

The train node now tracks two destination values:

```text
destination         internal CreateRailNet station/depot id, e.g. ST-B
create_destination  exact Create Train Station schedule name, e.g. Hauptbahnhof B
```

The internal destination is used by CreateRailNet routing and diagnostics.
The Create destination is used by Create train schedules and operator display.

## Main states

```text
IDLE
WAITING_FOR_ROUTE
ROUTE_ASSIGNED
WAITING_DEPARTURE
DEPART_AUTHORIZED
RUNNING
ARRIVED
SCHEDULE_FAILED
FAULT
OFFLINE
```

## Important commands

### set_schedule

Master sends a full Create schedule. Train applies it through the configured Create Station peripheral.

Result:

```text
schedule_state = applied | failed
state = ROUTE_ASSIGNED | SCHEDULE_FAILED
```

Then the train sends `schedule_applied` back to the master with:

```text
destination
create_destination
route_id
service_plan
service_stop_index
schedule_state
schedule_station
message
```

### set_destination

Updates the next internal destination and optional Create destination.

### depart_authorized

Marks the train as authorized to depart.

### hold_position

Marks the train as waiting and stores the reason.

## Display

The onboard monitor shows both:

```text
Dest:   ST-B
Create: Hauptbahnhof B
```

This avoids confusing internal IDs with Create station names.
