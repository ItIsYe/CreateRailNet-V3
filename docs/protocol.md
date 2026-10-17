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

Message ids are `<node>.<boot nonce>.<n>`. Every computer counts from 1 after a boot, so bare numbers collide between nodes
and between two boots of one node. Deduplication keys on `src/id` with a 30s TTL.

A duplicate means the sender never saw our answer (the ack got lost). The receiver answers again without redoing the work:
a node repeats the ack, or the err for a command that failed (it remembers the outcome of recent commands for 30s); the master
acks duplicate `event` and `register` messages again. Duplicate heartbeats and acks get no answer.

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

See `docs/OTA.md` for the full procedure. All commands are reliable `cmd` messages from the master or the OTA tool
(`OTA-TOOL`); nodes accept them only from `master_id` and `config.ota_sources`.

| Message | Direction | Payload |
|---|---|---|
| `ota_offer` | to node | `{ update_id, version, files = [{path, size, adler}] }` |
| `ota_need` (event) | from node | `{ update_id, need = [paths], reason? }` only files that differ |
| `ota_chunk` | to node | `{ update_id, path, index, total, data }` |
| `ota_commit` | to node | `{ update_id }` quiesce, swap, reboot |
| `ota_abort` | to node | `{ update_id }` |
| `ota_result` (event) | from node | `{ update_id, node_id, success, version, files, errors, up_to_date }` |
| `ota_confirmed` (event) | from node | `{ node_id, version }` after the first good boot of the new code |
| `ota_update` | to node | older single-message form `{ files = [{path, content, adler?}], version }`, same safe path |
