# Load

A bar widget that shows the one-minute load average. It runs `sysctl -n vm.loadavg` through `host.exec` every 30 seconds, and again when you click it.
