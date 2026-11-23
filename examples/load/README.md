# Load

A bar widget that shows the one-minute load average. It runs `sysctl -n vm.loadavg` through `host.exec` every 30 seconds, and again when you click it. It uses plain promises and `setInterval`, without Effect.

Copy it with `gary plugin new you.load --from load`. Gary adds it to the right of the bar.
