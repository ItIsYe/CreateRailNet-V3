# Network Protocol

All messages are JSON tables with:

```
{ v=1, type="register|heartbeat|cmd|event|ack|err",
  id="<unique>", src="<node_id>", dst="<node_id|broadcast>",
  ts=<ms>, payload={...} }
```

- **ack** includes the original message id in `payload.ack_id`.
- Deduplication is based on `id` for received messages.
- Retries use exponential backoff with bounds.
