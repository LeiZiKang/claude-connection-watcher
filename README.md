# Claude Connection Watcher

A native macOS menu bar app that groups Claude-related processes by their application and offers one batch quit action. Includes an original, appearance-aware vector menu bar icon.

This is an independent project, not affiliated with or endorsed by Anthropic.

## Install

Download the signed and Apple-notarized Universal 2 ZIP from [GitHub Releases](https://github.com/LeiZiKang/claude-connection-watcher/releases/latest). Extract it and move **Claude Connection Watcher.app** into Applications. macOS 13 or later is required; Apple silicon and Intel Macs are supported. Download the application ZIP, not GitHub's source-code archives. Xcode is only needed to build from source.

Or install using the maintainer's Homebrew tap:

```bash
brew install --cask leizikang/tap/claude-connection-watcher
```

Update with `brew update` followed by `brew upgrade --cask claude-connection-watcher`. This is a third-party tap maintained at [LeiZiKang/homebrew-tap](https://github.com/LeiZiKang/homebrew-tap), not an entry in the official Homebrew Cask repository.

If you already installed a copy manually, quit Watcher and move that copy out of Applications before installing with Homebrew. Keep it until the Homebrew installation succeeds. Your language preference is preserved.

安装后点击菜单栏图标即可查看相关 App；右上角可以选择 **中文 / English**，并使用 **刷新 / Refresh** 手动重新采样。

## What appears in the list

- **Official clients:** running Claude Desktop components and native Claude Code installations, identified by application ownership and Anthropic's Developer ID signature. These remain visible even when idle. Client identity is not presented as evidence of a network request.
- **Observed connections:** other applications whose local sockets can be associated with a Claude/Anthropic connection in the existing Clash Verge / Mihomo connection table. Records stay in memory for five minutes.
- **Related components:** the other currently running processes inside the same `.app` bundle. Quitting just a renderer may leave its parent application running, so the confirmation lists every captured component PID.

Click the menu bar icon to open the app list directly. Each app uses its original macOS icon and shows its running-process count. Expand a row to see process names, PIDs, identification basis, observed domains, and exited records. Icons load in the background and are cached; expanded groups and scroll position persist across updates. Command-line programs use their executable's system icon when they have no app bundle.

Use **退出全部相关 App…** at the bottom to review and quit the displayed apps together. The action takes its targets from the displayed snapshot, then revalidates their identities. Browsers may close unrelated tabs and windows; save your work first.

The **刷新 / Refresh** button requests a fresh background sample, rather than just redrawing the current list. It shows a refreshing state and coalesces repeated requests while the serial observer is busy. Automatic updates continue.

Choose **中文** or **English** in the top-right language menu. The list, coverage notices, and quit dialogs switch immediately; the preference is retained for the next launch. The initial language follows the system's preferred language (Chinese or English fallback). Application names and domain names are kept as supplied by the system.

## Connection attribution

The observer reads the numerical local TCP/UDP socket table with `lsof -nP`. It does **not** perform reverse DNS, which can stall for addresses without PTR records.

When `/tmp/verge/verge-mihomo.sock` exists, it issues only `GET /connections` on that Unix socket. A domain must exactly match, or be a subdomain of, `anthropic.com`, `claude.ai`, or `claude.com`. The app associates source address, port, and protocol with a local socket, checking the proxy's inbound endpoint where applicable. A TUN connection whose destination was translated must match a unique source socket. Ambiguous matches are discarded.

Socket snapshots bracket the controller read, and native process identities must agree before and after it. Controller-supplied PIDs and process paths are not trusted as termination targets. Sampling is serial, normally every two seconds. Commands time out, output is bounded, both pipes are drained during execution, and the menu reads a cached snapshot without waiting for sampling.

## Network environment stays unchanged

The app never writes Clash settings, selects a node, reloads TUN, changes DNS, modifies routes, deletes proxy connections, or changes a firewall. It does not read proxy configuration secrets. Its controller request is a fixed read-only GET to an existing local Unix socket; no remote controller address or redirects are used.

Clash/Mihomo, common proxy transports, and this app itself are excluded from discovery and checked again before signaling. An inaccessible controller produces a coverage notice; it does not require changing your network configuration or hide independently identified official clients.

## Quit behavior

- Only processes owned by the current user are eligible; root execution is refused.
- Targets are bound to PID, UID, microsecond start time, and executable path using macOS `libproc`.
- Confirmation freezes the target list. New processes are not silently added during termination.
- Identities, protected paths, and observation expiry are checked immediately before `SIGTERM`.
- `SIGKILL` requires another confirmation for the same captured identities.

macOS has no pidfd-style atomic check-and-signal API, so a small race remains between the identity check and signal delivery. Apps can restart or spawn new processes; the next observation lists them rather than automatically terminating them.

## Coverage limits

The app cannot enumerate every program that *could* contact Claude in the future. It identifies official native clients and records connections visible through the supported controller. Other proxy clients, direct traffic outside that controller, short-lived connections between samples, ambiguous sockets, and unsigned or JavaScript-based Claude Code installations may be missed. It cannot reconstruct history before launch. Only the current user's processes can be attributed and stopped.

These are connection observations, not HTTP request-body records. Long-lived idle connections can remain in the observation window while visible. Domain metadata is not cryptographic proof of a remote server's identity. An empty list is not a guarantee that no application can contact Anthropic. This is a process-management tool, not a firewall or packet-capture system.

## Build and test

Requires macOS 13 or later and Xcode Command Line Tools. Runs on Apple silicon and Intel Macs.

```bash
git clone https://github.com/LeiZiKang/claude-connection-watcher.git
cd claude-connection-watcher
bash scripts/test.sh
```

The build writes `dist/Claude Connection Watcher.app` with local ad-hoc signing by default. Set `CCW_SIGN_IDENTITY` to use a Developer ID already in your Keychain. Set `CCW_ARCHITECTURES="arm64 x86_64"` for Universal 2. The build does not launch the application.

Self-tests cover domain boundaries, socket ownership, proxy/client direction, ambiguity, protected processes, output draining, and timeout cleanup. They do not terminate user applications. For a read-only live diagnostic:

```bash
"dist/Claude Connection Watcher.app/Contents/MacOS/ClaudeConnectionWatcher" --diagnose
```

To preview the same vector used in the menu bar:

```bash
xcrun swiftc -framework AppKit Sources/MenuBarIcon.swift scripts/render-menu-icon.swift -o /tmp/ccw-render-icon
/tmp/ccw-render-icon /tmp/ccw-menu-icon.png
```

See [release instructions](docs/RELEASING.md) for signed, notarized release packages. Credentials and private keys stay in the macOS Keychain; build and release outputs are ignored by Git.

## Privacy and license

Process and connection records are in-memory only. No analytics, account login, external API client, or update service is included. The optional `--diagnose` command prints a local summary without saving a history file. Do not publish unreviewed diagnostic output.

[MIT](LICENSE)
