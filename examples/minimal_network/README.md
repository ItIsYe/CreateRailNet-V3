# Minimal Network Example

This example provides a single block and a basic route.

## Start
```sh
lua src/master/main.lua --config examples/minimal_network/network.json --id MASTER-1
lua src/nodes/signal_node.lua --config examples/minimal_network/network.json --id SIG-1
lua src/nodes/signal_node.lua --config examples/minimal_network/network.json --id SIG-2
lua src/nodes/sensor_node.lua --config examples/minimal_network/network.json --id SEN-1
lua src/nodes/switch_node.lua --config examples/minimal_network/network.json --id SW-1
```
