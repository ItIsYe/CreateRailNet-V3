# Troubleshooting

## Signals are always RED
- This is expected if the master cannot verify safety.
- Check node heartbeats and registration.
- Verify configuration for blocks and routes.

## Blocks in FAULT
- Sensor inconsistencies (leave without enter, double enter) trigger FAULT.
- Node timeouts mark blocks as FAULT.
- Reset by resolving sensor state and re-registering the node.

## Fail-Safe
If the master is uncertain or nodes are missing, signals are forced to RED by design.
