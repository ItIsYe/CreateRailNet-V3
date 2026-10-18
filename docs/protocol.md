# Network Protocol

## Message Format

All messages are JSON tables transmitted over a shared modem channel:

```
{
  v   = 1,                          -- protocol major version, must match
  pv  = 2,                          -- protocol revision (additive changes only; older nodes send none = 1)
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
Master updates `last_seen`. Fire-and-forget. Payload: `role`; a sensor adds `occupied` (boolean, what its detector shows now, absent while the
read fails) which the master uses to clear blocks after an outage (`docs/OPERATIONS.md`).

**cmd** — master sends a command to a node.
Always reliable (`send_reliable`). Node replies with ack or err.
Key commands: `depart_authorized`, `hold_position`, `set_aspect`, `set_position`, `ota_update`.

**event** — node sends an occurrence to the master.
Critical events use `send_reliable` (sensor enter/leave, arrived, request_departure, etc.).
Status-only events are fire-and-forget.

**ack** — acknowledgement. Payload: `{ ack_id = "<original msg id>", applied = true|nil }`.
Cancels the retry entry for that message. Without `applied` it means *delivered* (transport level, e.g. an OTA chunk that
was stored). With `applied = true` the receiver also did what the message asked: a node ran the command, the master handled the
event. `net.on_ack(ack_payload, original_message)` lets the sender tell the two apart.

**err** — command failed. Payload: `{ ref_id, error }`.

## Validation and who may send what

`net.receive` is fail-closed: a message with a wrong major version, an id/src/dst that is not a non-empty string of sane length,
an unknown `type`, a payload that is not a table, or a non-numeric `ts`/`pv` is `"invalid"` and dropped. The revision a peer
announced is kept (`net.peer_revision(id)`, at most 1024 peers) so newer features can be used only towards nodes that have them;
during a rolling OTA old and new nodes talk to each other, so changes to the envelope stay additive.

- **Commands to a node** are executed only when `src` is `master_id` or listed in `config.cmd_sources`; anything else gets an
  `err` ("source not allowed") and is logged once per sender and minute. OTA commands follow `config.ota_sources` instead
  (see `docs/OTA.md`), so the OTA tool can update but not steer.
- **Sensor events** are only accepted from the sensor node they name (`payload.sensor_id == src`); **manual control** only from a
  registered node with role `panel`. Rejected events are audited (`event_rejected`) and still acknowledged so the sender stops
  retrying.
- **Heartbeats** of nodes the master does not know (it restarted, nodes only register at their own start) register them
  (`node_adopted`); a heartbeat or register of a node that was DOWN is audited as `node_reconnect`.

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
| `ota_update` | to node | single-message form `{ files = [{path, content, adler?}], version, update_id? }`. New nodes apply it through the same safe path; nodes from before the verified update understand only this (`ota_push.lua --legacy`) and answer `ota_result` without `update_id`, to `broadcast` |
