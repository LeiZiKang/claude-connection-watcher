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
    private var statusMenuItem: NSMenuItem!
    private var actionItems: [NSMenuItem] = []
    private var isBusy = false
    private let observer = ClaudeConnectionObserver()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureMenu()
        guard geteuid() != 0 else {
            statusMenuItem.title = "状态：拒绝以 root 身份运行"
            actionItems.forEach { $0.isEnabled = false }
            return
        }
        observer.start { [weak self] in self?.refreshStatus() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        observer.stop()
    }

    private func configureMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = MenuBarIcon.make()
            button.toolTip = "Claude Connection Watcher"
        }

        let menu = NSMenu()
        statusMenuItem = NSMenuItem(title: "状态：正在识别相关 App…", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        menu.addItem(.separator())

        addAction(to: menu, title: "查看相关 App 与进程…", action: #selector(checkProcesses), key: "c")
        addAction(to: menu, title: "一键退出全部相关 App…", action: #selector(stopProcesses), key: "s")
        menu.addItem(.separator())

        let scope = NSMenuItem(title: "Claude 客户端 + 最近 5 分钟有相关连接的 App", action: nil, keyEquivalent: "")
        scope.isEnabled = false
        menu.addItem(scope)
        let limitation = NSMenuItem(title: "Clash 等网络工具始终排除；不修改网络设置", action: nil, keyEquivalent: "")
        limitation.isEnabled = false
        menu.addItem(limitation)
        menu.addItem(.separator())

        addAction(to: menu, title: "退出菜单栏应用", action: #selector(quitApp), key: "q", tracked: false)
        statusItem.menu = menu
    }

    private func addAction(to menu: NSMenu, title: String, action: Selector, key: String, tracked: Bool = true) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
        if tracked { actionItems.append(item) }
    }

    @objc private func checkProcesses() {
        let snapshot = observer.snapshot()
        let details = evidenceDetails(snapshot.items, error: snapshot.error)
        showAlert(
            title: snapshot.items.isEmpty ? "暂未识别到相关 App" : "\(Set(snapshot.items.map { $0.process.owner }).count) 个 App · \(snapshot.items.count) 个进程",
            message: observationMessage(items: snapshot.items, error: snapshot.error),
            details: details,
            style: snapshot.error == nil ? .informational : .warning
        )
    }

    @objc private func stopProcesses() {
        guard !isBusy else { return }
        let snapshot = observer.snapshot()
        let liveItems = snapshot.items.filter { processIdentityIsCurrent($0) }
        guard !liveItems.isEmpty else {
            showAlert(
                title: "无需退出",
                message: "当前列表中没有仍在运行的相关进程。",
                details: evidenceDetails(snapshot.items, error: snapshot.error),
                style: .informational
            )
            return
        }

        guard confirmStop(items: liveItems, warning: snapshot.error) else { return }
        setBusy(true, status: "状态：正在退出已观测进程…")
        signalProcesses(items: liveItems, signal: SIGTERM, waitSeconds: 5) { [weak self] result in
            guard let self else { return }
            if result.status == 0 {
                self.setBusy(false, status: "状态：已完成身份校验与退出处理")
                self.showAlert(title: "处理完成", message: "身份一致的目标已收到 SIGTERM；已退出或身份改变的目标被跳过。", details: result.output, style: .informational)
            } else {
                self.setBusy(false, status: "状态：仍有已观测进程未退出")
                self.offerForceQuit(items: liveItems, details: result.output)
            }
        }
    }

    @objc private func quitApp() { NSApp.terminate(nil) }

    private func confirmStop(items: [NetworkEvidence], warning: String?) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "退出这 \(Set(items.map { $0.process.owner }).count) 个 App？"
        alert.informativeText = "将退出下方列出的 \(items.count) 个进程，包括同属 App 的 Helper。浏览器的其他窗口也可能关闭，请先保存工作。Clash 等网络工具不会退出。"
        alert.addButton(withTitle: "退出这些 App")
        alert.addButton(withTitle: "取消")
        alert.accessoryView = detailsView(evidenceDetails(items, error: warning))
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func offerForceQuit(items: [NetworkEvidence], details: String) {
        let remaining = items.filter { processIdentityIsCurrent($0) }
        guard !remaining.isEmpty else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "仍有已观测进程未退出"
        alert.informativeText = "可以强制退出同一批进程；SIGKILL 前会再次复验完整进程身份，不会重新扫描或扩大目标。"
        alert.addButton(withTitle: "暂不处理")
        alert.addButton(withTitle: "强制退出剩余进程")
        alert.accessoryView = detailsView(details)
        guard alert.runModal() == .alertSecondButtonReturn else { return }

        setBusy(true, status: "状态：正在强制退出…")
        signalProcesses(items: remaining, signal: SIGKILL, waitSeconds: 1) { [weak self] result in
            guard let self else { return }
            let succeeded = result.status == 0
            self.setBusy(false, status: succeeded ? "状态：强制退出处理完成" : "状态：强制退出失败")
            self.showAlert(title: succeeded ? "强制退出处理完成" : "强制退出失败", message: succeeded ? "身份一致的目标已收到 SIGKILL；身份改变的目标被跳过。" : "仍有身份匹配的进程未退出。", details: result.output, style: succeeded ? .informational : .critical)
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
        let suffix = snapshot.error == nil ? "" : " · 部分连接不可见"
        statusMenuItem.title = "\(count) 个相关 App · \(live.count) 个运行中进程\(suffix)"
    }

    private func observationMessage(items: [NetworkEvidence], error: String?) -> String {
        let elapsed = min(Int(Date().timeIntervalSince(observer.startedAt)), 300)
        return "按 App 归类，列出 Claude 客户端及最近有相关连接的 App 和组件。网络观察已覆盖 \(elapsed) 秒；已退出的历史进程不会再次退出。"
    }

    private func evidenceDetails(_ items: [NetworkEvidence], error: String?) -> String {
        var lines: [String] = []
        if let error { lines.append("观察范围提示：\(error)\n") }
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
                    let state = captureProcessIdentity(pid: item.pid) == item.identity ? "运行中" : "已退出"
                    lines.append("  PID \(item.pid) · \(item.processName) · \(state)")
                    lines.append("    \(item.kind.rawValue)")
                    if item.kind == .connection {
                        lines.append("    \(formatter.string(from: item.observedAt)) · \(item.matchedDomain)")
                    }
                }
                lines.append("")
            }
        }
        lines.append("网络记录仅保留最近 5 分钟。客户端身份不代表已发出网络请求；未观测到的其他 App 不会被猜测加入。")
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
                    lines.append("跳过 PID \(item.pid)：受保护或记录已过期。")
                    continue
                }
                // macOS has no pidfd-style atomic check-and-signal API. Keep the
                // identity check immediately adjacent to kill to minimize the race.
                guard captureProcessIdentity(pid: item.pid) == item.identity else {
                    lines.append("跳过 PID \(item.pid)：进程身份已改变或进程已经退出。")
                    continue
                }
                attemptedItems.append(item)
                if Darwin.kill(item.pid, signal) == 0 {
                    lines.append("已向 PID \(item.pid)（\(item.processName)）发送 \(signal == SIGTERM ? "SIGTERM" : "SIGKILL")。")
                } else {
                    lines.append("PID \(item.pid) 信号发送失败：errno \(errno)。")
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
                lines.append("所有目标进程均已退出或身份已不再匹配。")
            } else {
                lines.append("仍在运行且身份匹配的 PID：\(remaining.map { String($0.pid) }.joined(separator: ", "))")
            }
            let result = SignalResult(status: remaining.isEmpty ? 0 : 1, output: lines.joined(separator: "\n"))
            DispatchQueue.main.async { completion(result) }
        }
    }

    private func setBusy(_ busy: Bool, status: String) {
        isBusy = busy
        statusMenuItem.title = status
        actionItems.forEach { $0.isEnabled = !busy }
    }

    private func showAlert(title: String, message: String, details: String, style: NSAlert.Style) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "好")
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
