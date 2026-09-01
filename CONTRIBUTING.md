# Contributing

Issues and pull requests are welcome. Please keep the core safety properties intact:

1. Require positive, recent network evidence before presenting a PID as a target.
2. Never broaden shutdown targets by process name, parent process, or application category.
3. Bind every PID to its effective UID, microsecond-resolution start time, and executable path, and revalidate the complete identity immediately before signalling.
4. Fail closed when observation or identity validation is unavailable or ambiguous.
5. Keep force termination behind a separate, explicit confirmation.
6. Do not add telemetry or persist observed connection metadata without an opt-in design and clear documentation.

Before submitting a pull request, run:

```bash
bash scripts/test.sh
```
