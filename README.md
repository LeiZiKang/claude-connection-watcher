# Claude Connection Watcher

A small, native macOS menu bar app that associates recent Claude/Anthropic network connections with the local processes that opened them. It keeps a five-minute in-memory observation window and can gracefully stop only the positively observed PIDs.

> [!IMPORTANT]
> This is an independent third-party project. It is not affiliated with, maintained by, or endorsed by Anthropic.

## Why

Searching process names for `Claude` is not reliable evidence that a process recently contacted Claude. Claude Connection Watcher instead requires a visible remote hostname ending in one of these domains:

- `anthropic.com`
- `claude.ai`
- `claude.com`

For every match, the app records the process ID, process name, endpoint, matched domain, observation time, effective UID, microsecond-resolution start time, and executable path. Records expire after five minutes and are not written to disk.

## Safety model

- No process is selected by its name or installation path.
- The app binds each PID to its effective UID, microsecond-resolution start time, and executable path using macOS `libproc`.
- A global match is admitted only after a second PID-scoped `lsof` check is bracketed by two identical `libproc` identity reads.
- That complete identity is checked again immediately before every signal; changed or expired identities are skipped.
- PID 0 and PID 1 are never eligible.
- Only processes owned by the app's current effective user are eligible; shutdown is disabled when the app itself runs as root.
- Graceful shutdown uses `SIGTERM` first.
- `SIGKILL` is available only after another explicit confirmation and applies to the same PID list.
- The app does not start or modify VPN, proxy, DNS, or firewall configuration.

Always review the evidence list before stopping a process. Closing an application can discard unsaved work.

## Important limitations

This tool observes network **connections**, not HTTP request contents.

- Observation starts when the app starts. It cannot reconstruct the five minutes before launch.
- A full observation window is available only after the app has run for five minutes.
- A local proxy, TUN, VPN, encrypted DNS setup, or shared CDN can hide the destination hostname. Hidden or IP-only destinations are intentionally not guessed, so false negatives are expected.
- Reverse DNS is not an authoritative history of all network activity.
- Short-lived connections between two-second samples can be missed.
- macOS does not provide a general pidfd-style atomic check-and-signal operation. Full identity checks strongly guard against PID reuse, but an extremely small race remains between the final identity read and signal delivery.
- The app is a visibility and convenience tool, not a firewall, packet capture system, privacy guarantee, or forensic audit log.

## Requirements

- macOS 13 or later
- Apple silicon or Intel Mac
- Xcode Command Line Tools

## Build

```bash
git clone https://github.com/LeiZiKang/claude-connection-watcher.git
cd claude-connection-watcher
bash scripts/build.sh
```

The locally ad-hoc-signed app is written to:

```text
dist/Claude Connection Watcher.app
```

The build script does not launch the app or stop any process. If your installed compiler and SDK are out of sync, set `CCW_SDK_PATH` to a compatible macOS SDK directory before building.

To prepare a Universal 2 ZIP for a GitHub Release, follow the [release guide](docs/RELEASING.md). Stable public packages require Developer ID signing and Apple notarization; signing and notarization credentials remain in the local macOS Keychain and are never copied into the repository.

## Test

```bash
bash scripts/test.sh
```

The test path validates the build script and property list, builds and verifies the app bundle, then checks native process identity capture and endpoint-domain parsing. It sends no termination signal.

## Use

1. Open `Claude Connection Watcher.app`.
2. Keep it running while using relevant applications.
3. Select **查看最近 5 分钟 Claude 网络连接…** to inspect evidence.
4. Select **退出这些连接对应的进程…** only after checking every listed PID and endpoint.

## Privacy

Observed connection metadata and process identities stay in memory and expire after five minutes. The app contains no analytics, update service, account login, or API client. It invokes the system `lsof` tool to inspect visible TCP and UDP connections and uses macOS `libproc` to bind evidence to a specific process lifetime. Because hostname resolution is intentionally enabled, `lsof` and the macOS resolver may issue DNS/PTR lookups while sampling.

Maintainers should complete the [public release credential-safety checklist](docs/PUBLIC_RELEASE_CHECKLIST.md) before publishing code or artifacts.

## License

[MIT](LICENSE)
