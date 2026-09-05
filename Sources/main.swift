import AppKit
import Darwin
import Foundation

private struct SignalResult {
    let status: Int32
    let output: String
}

struct ProcessIdentity: Hashable {
    let pid: Int32
    let effectiveUID: uid_t
    let startSeconds: UInt64
    let startMicroseconds: UInt64
    let executablePath: String
}

func captureProcessIdentity(pid: Int32) -> ProcessIdentity? {
    let currentUID = geteuid()
    guard pid > 1, currentUID != 0 else { return nil }

    var info = proc_bsdinfo()
    let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.stride)
    let infoSize = withUnsafeMutablePointer(to: &info) { pointer in
        proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, pointer, expectedSize)
    }
    guard infoSize == expectedSize,
          info.pbi_pid == UInt32(pid),
          info.pbi_uid == currentUID else { return nil }

    var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
    let pathLength = pathBuffer.withUnsafeMutableBufferPointer { buffer in
        proc_pidpath(pid, buffer.baseAddress, UInt32(buffer.count))
    }
    guard pathLength > 0 else { return nil }

    return ProcessIdentity(
        pid: pid,
        effectiveUID: info.pbi_uid,
        startSeconds: info.pbi_start_tvsec,
        startMicroseconds: info.pbi_start_tvusec,
        executablePath: String(cString: pathBuffer)
    )
}


final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let appList = AppListViewController()
    private var isBusy = false
    private let observer = ClaudeConnectionObserver()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureMenu()
        guard geteuid() != 0 else {
            statusItem.button?.toolTip = L10n.text("拒绝以 root 身份运行", "Running as root is not supported")
            statusItem.button?.isEnabled = false
            return
        }
        observer.start { [weak self] in self?.refreshStatus() }
        if CommandLine.arguments.contains("--show-list") { togglePopover() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        observer.stop()
    }

    private func configureMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = MenuBarIcon.make()
            button.toolTip = "Claude Connection Watcher"
            button.target = self
            button.action = #selector(togglePopover)
        }
        popover.behavior = .transient
        popover.contentViewController = appList
        appList.onQuitAll = { [weak self] items, warning in
            guard let self else { return }
            self.popover.performClose(nil)
            self.stopProcesses(items: items, warning: warning)
        }
        appList.onQuitWatcher = { [weak self] in self?.quitApp() }
        appList.onLanguageChange = { [weak self] in self?.refreshStatus() }
        appList.onRefresh = { [weak self] in
            guard let self, !self.isBusy else { return }
            if self.observer.refresh(completion: { [weak self] in
                self?.appList.setRefreshing(false)
                self?.refreshStatus()
            }) {
                self.appList.setRefreshing(true)
            }
        }
    }

    @objc private func togglePopover() {
        if popover.isShown { popover.performClose(nil); return }
        guard let button = statusItem.button else { return }
        refreshStatus()
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func stopProcesses(items: [NetworkEvidence], warning: String?) {
        guard !isBusy else { return }
        let liveItems = items.filter { processIdentityIsCurrent($0) }
        guard !liveItems.isEmpty else {
            showAlert(
                title: L10n.text("无需退出", "Nothing to quit"),
                message: L10n.text("当前列表中没有仍在运行的相关进程。", "There are no running related processes in this list."),
                details: evidenceDetails(items, error: warning),
                style: .informational
            )
            return
        }

        guard confirmStop(items: liveItems, warning: warning) else { return }
        setBusy(true, status: L10n.text("状态：正在退出已观测进程…", "Quitting related processes…"))
        signalProcesses(items: liveItems, signal: SIGTERM, waitSeconds: 5) { [weak self] result in
            guard let self else { return }
            if result.status == 0 {
                self.setBusy(false, status: L10n.text("状态：已完成身份校验与退出处理", "Quit operation completed"))
                self.showAlert(title: L10n.text("处理完成", "Completed"), message: L10n.text("身份一致的目标已收到 SIGTERM；已退出或身份改变的目标被跳过。", "SIGTERM was sent to matching targets. Exited or changed identities were skipped."), details: result.output, style: .informational)
            } else {
                self.setBusy(false, status: L10n.text("状态：仍有已观测进程未退出", "Some related processes are still running"))
                self.offerForceQuit(items: liveItems, details: result.output)
            }
        }
    }

    @objc private func quitApp() { NSApp.terminate(nil) }

    private func confirmStop(items: [NetworkEvidence], warning: String?) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.text("退出这 \(Set(items.map { $0.process.owner }).count) 个 App？", "Quit these apps (\(Set(items.map { $0.process.owner }).count))?")
        alert.informativeText = L10n.text("将退出下方列出的 \(items.count) 个进程，包括同属 App 的 Helper。浏览器的其他窗口也可能关闭，请先保存工作。Clash 等网络工具不会退出。", "This will quit the \(items.count) listed processes, including app helpers. Other browser windows may close; save your work first. Clash and other network tools are excluded.")
        alert.addButton(withTitle: L10n.text("退出这些 App", "Quit these apps"))
        alert.addButton(withTitle: L10n.text("取消", "Cancel"))
        alert.accessoryView = detailsView(evidenceDetails(items, error: warning))
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func offerForceQuit(items: [NetworkEvidence], details: String) {
        let remaining = items.filter { processIdentityIsCurrent($0) }
        guard !remaining.isEmpty else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = L10n.text("仍有已观测进程未退出", "Some processes are still running")
        alert.informativeText = L10n.text("可以强制退出同一批进程；SIGKILL 前会再次复验完整进程身份，不会重新扫描或扩大目标。", "You can force quit the same captured processes. Their identities will be checked again; no new targets will be added.")
        alert.addButton(withTitle: L10n.text("暂不处理", "Not now"))
        alert.addButton(withTitle: L10n.text("强制退出剩余进程", "Force quit remaining"))
        alert.accessoryView = detailsView(details)
        guard alert.runModal() == .alertSecondButtonReturn else { return }

        setBusy(true, status: L10n.text("状态：正在强制退出…", "Force quitting…"))
        signalProcesses(items: remaining, signal: SIGKILL, waitSeconds: 1) { [weak self] result in
            guard let self else { return }
            let succeeded = result.status == 0
            self.setBusy(false, status: succeeded ? L10n.text("状态：强制退出处理完成", "Force quit completed") : L10n.text("状态：强制退出失败", "Force quit failed"))
            self.showAlert(title: succeeded ? L10n.text("强制退出处理完成", "Force quit completed") : L10n.text("强制退出失败", "Force quit failed"), message: succeeded ? L10n.text("身份一致的目标已收到 SIGKILL；身份改变的目标被跳过。", "SIGKILL was sent to matching targets. Changed identities were skipped.") : L10n.text("仍有身份匹配的进程未退出。", "Some matching processes are still running."), details: result.output, style: succeeded ? .informational : .critical)
        }
    }

    private func processIdentityIsCurrent(_ item: NetworkEvidence) -> Bool {
        !ProcessInventory.isProtected(item.identity)
            && (item.kind == .official || Date().timeIntervalSince(item.observedAt) < ClaudeConnectionObserver.window)
            && captureProcessIdentity(pid: item.pid) == item.identity
    }

    private func refreshStatus() {
        guard !isBusy else { return }
        let snapshot = observer.snapshot()
        let live = snapshot.items.filter { processIdentityIsCurrent($0) }
        let count = Set(live.map { $0.process.owner }).count
        let suffix = snapshot.error == nil ? "" : L10n.text(" · 部分连接不可见", " · Limited connection coverage")
        statusItem.button?.toolTip = L10n.text("\(count) 个相关 App · \(live.count) 个运行中进程\(suffix)", "Apps: \(count) · Running processes: \(live.count)\(suffix)")
        appList.update(items: snapshot.items, warning: snapshot.error)
    }

    private func evidenceDetails(_ items: [NetworkEvidence], error: String?) -> String {
        var lines: [String] = []
        if let error { lines.append(L10n.text("观察范围提示：\(error)\n", "Coverage notice: \(error)\n")) }
        if items.isEmpty {
            lines.append("(none)\n")
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss"
            let groups = Dictionary(grouping: items, by: { $0.process.owner })
            for owner in groups.keys.sorted(by: { $0.name < $1.name }) {
                lines.append("【\(owner.name)】")
                lines.append(owner.path)
                for item in groups[owner]!.sorted(by: { $0.pid < $1.pid }) {
                    let state = captureProcessIdentity(pid: item.pid) == item.identity ? L10n.text("运行中", "Running") : L10n.text("已退出", "Exited")
                    lines.append("  PID \(item.pid) · \(item.processName) · \(state)")
                    lines.append("    \(item.kind.localizedDescription)")
                    if item.kind == .connection {
                        lines.append("    \(formatter.string(from: item.observedAt)) · \(item.matchedDomain)")
                    }
                }
                lines.append("")
            }
        }
        lines.append(L10n.text("网络记录仅保留最近 5 分钟。客户端身份不代表已发出网络请求；未观测到的其他 App 不会被猜测加入。", "Connections are retained for five minutes. Client identity does not imply a request; unobserved apps are not guessed."))
        return lines.joined(separator: "\n")
    }

    private func signalProcesses(
        items: [NetworkEvidence],
        signal: Int32,
        waitSeconds: Int,
        completion: @escaping (SignalResult) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            var seen = Set<Int32>()
            let uniqueItems = items.filter { seen.insert($0.pid).inserted }.sorted { $0.pid < $1.pid }
            var lines: [String] = []
            var attemptedItems: [NetworkEvidence] = []

            for item in uniqueItems {
                guard !ProcessInventory.isProtected(item.identity),
                      item.kind == .official || Date().timeIntervalSince(item.observedAt) < ClaudeConnectionObserver.window else {
                    lines.append(L10n.text("跳过 PID \(item.pid)：受保护或记录已过期。", "Skipped PID \(item.pid): protected or expired record."))
                    continue
                }
                // macOS has no pidfd-style atomic check-and-signal API. Keep the
                // identity check immediately adjacent to kill to minimize the race.
                guard captureProcessIdentity(pid: item.pid) == item.identity else {
                    lines.append(L10n.text("跳过 PID \(item.pid)：进程身份已改变或进程已经退出。", "Skipped PID \(item.pid): identity changed or process exited."))
                    continue
                }
                attemptedItems.append(item)
                if Darwin.kill(item.pid, signal) == 0 {
                    lines.append(L10n.text("已向 PID \(item.pid)（\(item.processName)）发送 \(signal == SIGTERM ? "SIGTERM" : "SIGKILL")。", "Sent \(signal == SIGTERM ? "SIGTERM" : "SIGKILL") to PID \(item.pid) (\(item.processName))."))
                } else {
                    lines.append(L10n.text("PID \(item.pid) 信号发送失败：errno \(errno)。", "Signal failed for PID \(item.pid): errno \(errno)."))
                }
            }

            if waitSeconds > 0 {
                for _ in 0..<waitSeconds {
                    let remaining = attemptedItems.contains { captureProcessIdentity(pid: $0.pid) == $0.identity }
                    if !remaining { break }
                    Thread.sleep(forTimeInterval: 1)
                }
            }

            let remaining = attemptedItems.filter { captureProcessIdentity(pid: $0.pid) == $0.identity }
            if remaining.isEmpty {
                lines.append(L10n.text("所有目标进程均已退出或身份已不再匹配。", "All attempted targets exited or no longer match their captured identity."))
            } else {
                lines.append(L10n.text("仍在运行且身份匹配的 PID：\(remaining.map { String($0.pid) }.joined(separator: ", "))", "Still-running matching PIDs: \(remaining.map { String($0.pid) }.joined(separator: ", "))"))
            }
            let result = SignalResult(status: remaining.isEmpty ? 0 : 1, output: lines.joined(separator: "\n"))
            DispatchQueue.main.async { completion(result) }
        }
    }

    private func setBusy(_ busy: Bool, status: String) {
        isBusy = busy
        statusItem.button?.toolTip = status
        appList.setBusy(busy)
    }

    private func showAlert(title: String, message: String, details: String, style: NSAlert.Style) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: L10n.text("好", "OK"))
        alert.accessoryView = detailsView(details)
        alert.runModal()
    }

    private func detailsView(_ details: String) -> NSView {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 570, height: 210))
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        let textView = NSTextView(frame: scrollView.bounds)
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.string = details.trimmingCharacters(in: .whitespacesAndNewlines)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        scrollView.documentView = textView
        return scrollView
    }
}

if CommandLine.arguments.contains("--self-test") {
    runSelfTests()
    exit(0)
}

if CommandLine.arguments.contains("--diagnose") {
    let observer = ClaudeConnectionObserver()
    let started = ProcessInfo.processInfo.systemUptime
    observer.sample()
    let snapshot = observer.snapshot()
    let groups = Dictionary(grouping: snapshot.items, by: { $0.process.owner })
    let result: [String: Any] = [
        "seconds": ProcessInfo.processInfo.systemUptime - started,
        "warning": snapshot.error ?? "",
        "apps": groups.keys.sorted(by: { $0.name < $1.name }).map { owner -> [String: Any] in
            let items = groups[owner]!
            return ["app": owner.name, "processCount": items.count,
                    "officialComponents": items.filter { $0.kind == .official }.count,
                    "networkProcesses": items.filter { $0.kind == .connection }.count,
                    "domains": items.filter { !$0.matchedDomain.isEmpty }.map(\.matchedDomain)]
        }
    ]
    if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
        print(String(decoding: data, as: UTF8.self))
    }
    exit(0)
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
