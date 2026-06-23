# Network Protocol

## Message Format

All messages are JSON tables transmitted over a shared modem channel:

```
{
  v   = 1,                          -- protocol version
  type = "register|heartbeat|cmd|event|ack|err",
  id  = "<unique string>",          -- for dedup and ack matching
  src = "<node_id>",
  dst = "<node_id>|broadcast",
  ts  = <ms since epoch>,           -- time.now_ms()
  payload = { ... }
}
```

## Message Types

**register** — node announces itself on connect or reconnect.
Payload includes `role` and full node state (platforms, tracks, etc.).
Master replies with ack. Reliable delivery.

**heartbeat** — periodic liveness signal (every 2s by default).
Master updates `last_seen`. Fire-and-forget.

**cmd** — master sends a command to a node.
Always reliable (`send_reliable`). Node replies with ack or err.
Key commands: `depart_authorized`, `hold_position`, `set_aspect`, `set_position`, `ota_update`.

**event** — node sends an occurrence to the master.
Critical events use `send_reliable` (sensor enter/leave, arrived, request_departure, etc.).
Status-only events are fire-and-forget.

**ack** — acknowledgement. Payload: `{ ack_id = "<original msg id>" }`.
Cancels the retry entry for that message.

**err** — command failed. Payload: `{ ref_id, error }`.

## Reliability

`send_reliable` adds the message to a pending table. `tick()` retries with exponential backoff:
- Base interval: 200ms
- Max interval: 5000ms
- Max retries: 5

After 5 failed retries, `on_drop` fires and the node is marked potentially down.

Deduplication uses `msg.id` with a 30s TTL to discard replayed messages.

## Event Types (node → master)

| Event type | Sender | Reliable |
|---|---|---|
| `sensor` (enter/leave) | sensor_node | ✅ |
| `request_departure` | train_node | ✅ |
| `arrived` | train_node | ✅ |
| `schedule_applied` | train_node | ✅ |
| `train_status` | train_node | ❌ heartbeat |
| `train_arrived_station` | station_node | ✅ |
| `train_left_station` | station_node | ✅ |
| `station_ready_departure` | station_node | ✅ |
| `depot_train_arrived` | depot_node | ✅ |
| `depot_train_left` | depot_node | ✅ |
| `depot_train_ready` | depot_node | ✅ |
| `depot_request_dispatch` | depot_node | ✅ |
| `manual_control` | panel_node | ✅ |
| `ota_result` | any node | ❌ best-effort |

## OTA Update Protocol

Master → node: `cmd` with `cmd="ota_update"`, payload:
```
{ files = [{path, content}, ...], version = "string", file_count = N }
```

Node writes files atomically, reboots, then sends:

Node → master: `event` with `type="ota_result"`:
```
{ node_id, success = true|false, files = N, version = "string", errors = [...] }
```
