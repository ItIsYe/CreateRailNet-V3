# Configuration Reference

## Top-Level
- `v` (number): schema version (1).
- `channel` (number): modem channel for network.
- `master_id` (string): node id of master.
- `blocks` (array): block definitions.
- `routes` (array): route definitions.
- `nodes` (array): node definitions.

## Block
```
{ "id": "B1",
  "entry_signal": "SIG-1",
  "exit_signal": "SIG-2",
  "sensors": ["SEN-1"],
  "switches": [{"id":"SW-1","position":"STRAIGHT"}] }
```

## Route
```
{ "id": "R1", "from":"A", "to":"B", "blocks":["B1"], "priority":10 }
```

## Node
```
{ "id":"SIG-1", "role":"signal" }
```

All topology is declared in JSON, no hardcoding in code.
