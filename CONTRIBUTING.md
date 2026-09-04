# Contributing

Issues and pull requests are welcome. Please keep the core safety properties intact:

1. Distinguish signed official clients, recent network observations, and same-app components. Never describe client identity as proof of a request.
2. Require verified application ownership or unambiguous socket evidence. Never select a target by display name alone; show all same-app component PIDs before confirmation.
3. Bind every PID to its effective UID, microsecond-resolution start time, and executable path, and revalidate the complete identity immediately before signalling.
4. Discard unavailable or ambiguous connection attribution; independently verified client identities remain usable. Never target this watcher or network transports such as Clash/Mihomo.
5. Keep force termination behind a separate, explicit confirmation.
6. Do not add telemetry or persist observed connection metadata without an opt-in design and clear documentation.
7. Keep controller access read-only. Never modify network settings, switch proxy nodes, reload TUN, or delete controller connections.

Before submitting a pull request, run:

```bash
bash scripts/test.sh
```
