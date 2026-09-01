import AppKit
import Darwin
import Foundation

private struct SignalResult {
    let status: Int32
    let output: String
}

private struct ProcessIdentity: Hashable {
    let pid: Int32
    let effectiveUID: uid_t
    let startSeconds: UInt64
    let startMicroseconds: UInt64
    let executablePath: String
}

private func captureProcessIdentity(pid: Int32) -> ProcessIdentity? {
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

private struct NetworkEvidence {
    let pid: Int32
    let processName: String
    let endpoint: String
    let matchedDomain: String
    let observedAt: Date
    let identity: ProcessIdentity
}

private final class ClaudeConnectionObserver {
    private struct LsofResult {
        let status: Int32
        let output: String
        let error: String
    }

    static let window: TimeInterval = 5 * 60
    static let domains = ["anthropic.com", "claude.ai", "claude.com"]

    private let queue = DispatchQueue(label: "ClaudeConnectionObserver")
    private let snapshotLock = NSLock()
    private var timer: DispatchSourceTimer?
    private var evidence: [NetworkEvidence] = []
    private var cachedItems: [NetworkEvidence] = []
    private var cachedError: String?
    private(set) var startedAt = Date()
    private var lastError: String?

    func start(onUpdate: @escaping () -> Void) {
        startedAt = Date()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 2)
        timer.setEventHandler { [weak self] in
            self?.sample()
            DispatchQueue.main.async(execute: onUpdate)
        }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    func snapshot() -> (items: [NetworkEvidence], error: String?) {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        return (cachedItems, cachedError)
    }

    private func sample() {
        defer {
            purgeExpired()
            publishSnapshot()
        }
        // Keep hostname resolution enabled: only a hostname carrying an exact
        // Claude/Anthropic suffix is accepted as evidence. IP-only connections
        // are intentionally not guessed because CDN addresses are shared.
        guard let result = runLsof(arguments: ["-P", "-iTCP", "-iUDP", "-Fpcn"]) else {
            lastError = "lsof 网络采样超时或无法启动"
            return
        }
        if result.status == 1 &&
            result.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            result.error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lastError = nil
            return
        }
        let errorText = result.error.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.status == 0, errorText.isEmpty else {
            let diagnostic = errorText.isEmpty
                ? result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                : errorText
            lastError = diagnostic.isEmpty
                ? "lsof 无法读取网络连接（退出码 \(result.status)）"
                : "lsof 错误：\(diagnostic)"
            return
        }
        lastError = nil
        ingest(result.output)
    }

    private func ingest(_ output: String) {
        var currentPID: Int32?
        var currentName = "未知应用"
        var verificationCache: [Int32: NetworkEvidence] = [:]
        var attemptedPIDs = Set<Int32>()
        var appendedPIDs = Set<Int32>()

        for rawLine in output.split(whereSeparator: \Character.isNewline) {
            guard let tag = rawLine.first else { continue }
            let value = String(rawLine.dropFirst())
            switch tag {
            case "p":
                currentPID = Int32(value)
                currentName = "未知应用"
            case "c":
                currentName = value
            case "n":
                guard let pid = currentPID,
                      Self.matchedDomain(in: value) != nil else { continue }
                if !attemptedPIDs.contains(pid) {
                    attemptedPIDs.insert(pid)
                    verificationCache[pid] = verifyCurrentConnection(pid: pid)
                }
                guard var verified = verificationCache[pid] else { continue }
                if verified.processName == "未知应用" && currentName != "未知应用" {
                    verified = NetworkEvidence(
                        pid: verified.pid,
                        processName: currentName,
                        endpoint: verified.endpoint,
                        matchedDomain: verified.matchedDomain,
                        observedAt: verified.observedAt,
                        identity: verified.identity
                    )
                    verificationCache[pid] = verified
                }
                guard appendedPIDs.insert(pid).inserted else { continue }
                evidence.append(verified)
            default:
                continue
            }
        }
    }

    private func verifyCurrentConnection(pid: Int32) -> NetworkEvidence? {
        guard let identityBefore = captureProcessIdentity(pid: pid) else { return nil }

        guard let result = runLsof(arguments: ["-a", "-p", String(pid), "-P", "-iTCP", "-iUDP", "-Fpcn"]),
              result.status == 0,
              result.error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        do {
            let output = result.output
            var processName = "未知应用"
            var matchedEndpoint: String?
            var matchedDomain: String?
            for rawLine in output.split(whereSeparator: \Character.isNewline) {
                guard let tag = rawLine.first else { continue }
                let value = String(rawLine.dropFirst())
                if tag == "c" {
                    processName = value
                } else if tag == "n", let domain = Self.matchedDomain(in: value) {
                    matchedEndpoint = value
                    matchedDomain = domain
                    break
                }
            }

            guard let endpoint = matchedEndpoint,
                  let domain = matchedDomain,
                  let identityAfter = captureProcessIdentity(pid: pid),
                  identityBefore == identityAfter else { return nil }

            return NetworkEvidence(
                pid: pid,
                processName: processName,
                endpoint: endpoint,
                matchedDomain: domain,
                observedAt: Date(),
                identity: identityAfter
            )
        }
    }

    private func runLsof(arguments: [String], timeout: TimeInterval = 5) -> LsofResult? {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let completion = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var collectedOutput = Data()
        var collectedError = Data()

        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = arguments
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.terminationHandler = { _ in completion.signal() }

        let outputReader = outputPipe.fileHandleForReading
        let errorReader = errorPipe.fileHandleForReading
        outputReader.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            lock.lock()
            collectedOutput.append(chunk)
            lock.unlock()
        }
        errorReader.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            lock.lock()
            collectedError.append(chunk)
            lock.unlock()
        }

        do {
            try process.run()
        } catch {
            outputReader.readabilityHandler = nil
            errorReader.readabilityHandler = nil
            return nil
        }

        guard completion.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            if completion.wait(timeout: .now() + 1) == .timedOut {
                Darwin.kill(process.processIdentifier, SIGKILL)
                _ = completion.wait(timeout: .now() + 1)
            }
            outputReader.readabilityHandler = nil
            errorReader.readabilityHandler = nil
            return nil
        }

        outputReader.readabilityHandler = nil
        errorReader.readabilityHandler = nil
        let outputTail = outputReader.readDataToEndOfFile()
        let errorTail = errorReader.readDataToEndOfFile()
        lock.lock()
        collectedOutput.append(outputTail)
        collectedError.append(errorTail)
        let outputData = collectedOutput
        let errorData = collectedError
        lock.unlock()
        return LsofResult(
            status: process.terminationStatus,
            output: String(decoding: outputData, as: UTF8.self),
            error: String(decoding: errorData, as: UTF8.self)
        )
    }

    fileprivate static func matchedDomain(in endpoint: String) -> String? {
        guard let arrow = endpoint.range(of: "->") else { return nil }
        var remote = String(endpoint[arrow.upperBound...]).trimmingCharacters(in: .whitespaces)
        if let state = remote.firstIndex(of: " ") {
            remote = String(remote[..<state])
        }

        let host: String
        if remote.hasPrefix("["), let close = remote.firstIndex(of: "]") {
            host = String(remote[remote.index(after: remote.startIndex)..<close])
        } else if let portSeparator = remote.lastIndex(of: ":") {
            host = String(remote[..<portSeparator])
        } else {
            host = remote
        }

        let normalizedHost = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return domains.first { normalizedHost == $0 || normalizedHost.hasSuffix(".\($0)") }
    }

    private func purgeExpired() {
        let cutoff = Date().addingTimeInterval(-Self.window)
        evidence.removeAll { $0.observedAt < cutoff }
    }

    private func publishSnapshot() {
        let items = Dictionary(grouping: evidence, by: \NetworkEvidence.identity)
            .compactMap { _, values in values.max(by: { $0.observedAt < $1.observedAt }) }
            .sorted { $0.observedAt > $1.observedAt }
        snapshotLock.lock()
        cachedItems = items
        cachedError = lastError
        snapshotLock.unlock()
    }
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
            let image = NSImage(systemSymbolName: "network.badge.shield.half.filled", accessibilityDescription: "Claude Connection Watcher")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "Claude Connection Watcher"
        }

        let menu = NSMenu()
        statusMenuItem = NSMenuItem(title: "状态：正在建立 5 分钟观察窗口…", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        menu.addItem(.separator())

        addAction(to: menu, title: "查看最近 5 分钟 Claude 网络连接…", action: #selector(checkProcesses), key: "c")
        addAction(to: menu, title: "退出这些连接对应的进程…", action: #selector(stopProcesses), key: "s")
        menu.addItem(.separator())

        let scope = NSMenuItem(title: "证据：lsof 反向解析出的远端主机名匹配 Claude 域名", action: nil, keyEquivalent: "")
        scope.isEnabled = false
        menu.addItem(scope)
        let limitation = NSMenuItem(title: "不按名称猜测；代理隐藏域名或仅有 IP 时不会命中", action: nil, keyEquivalent: "")
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
                title: snapshot.items.isEmpty ? "没有明确连接证据" : "发现 \(snapshot.items.count) 个相关进程",
            message: observationMessage(items: snapshot.items, error: snapshot.error),
            details: details,
            style: snapshot.error == nil ? .informational : .warning
        )
    }

    @objc private func stopProcesses() {
        guard !isBusy else { return }
        let snapshot = observer.snapshot()
        guard snapshot.error == nil else {
            showAlert(title: "网络采样不可用", message: "没有执行退出操作。", details: evidenceDetails(snapshot.items, error: snapshot.error), style: .warning)
            return
        }

        let liveItems = snapshot.items.filter { processIdentityIsCurrent($0) }
        guard !liveItems.isEmpty else {
            showAlert(
                title: "无需退出",
                message: "最近 5 分钟没有发现仍在运行、且有明确 Claude 域名连接证据的进程。",
                details: evidenceDetails(snapshot.items, error: nil),
                style: .informational
            )
            return
        }

        guard confirmStop(items: liveItems) else { return }
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

    private func confirmStop(items: [NetworkEvidence]) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "退出这些有网络证据的进程？"
        alert.informativeText = "仅向下列 PID 发送 SIGTERM。发送前会复验 UID、微秒级启动时间和可执行文件路径；身份不一致会跳过。浏览器等多用途应用可能整体退出，并丢失未保存内容。"
        alert.addButton(withTitle: "发送 SIGTERM")
        alert.addButton(withTitle: "取消")
        alert.accessoryView = detailsView(evidenceDetails(items, error: nil))
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
        captureProcessIdentity(pid: item.pid) == item.identity
    }

    private func refreshStatus() {
        guard !isBusy else { return }
        let snapshot = observer.snapshot()
        if snapshot.error != nil {
            statusMenuItem.title = "状态：网络采样不可用"
        } else if snapshot.items.isEmpty {
            let elapsed = min(Int(Date().timeIntervalSince(observer.startedAt)), 300)
            statusMenuItem.title = elapsed < 300
                ? "状态：未命中（已观察 \(elapsed) 秒）"
                : "状态：最近 5 分钟未命中"
        } else {
            statusMenuItem.title = "状态：最近 5 分钟命中 \(snapshot.items.count) 个进程"
        }
    }

    private func observationMessage(items: [NetworkEvidence], error: String?) -> String {
        if error != nil { return "采样失败，结果不完整；不会据此退出任何进程。" }
        let elapsed = Int(Date().timeIntervalSince(observer.startedAt))
        if elapsed < 300 {
            return "应用只从启动后开始观察，目前覆盖约 \(elapsed) 秒；不是启动前 5 分钟的历史。"
        }
        return items.isEmpty ? "完整观察窗口内没有可见的端点主机名匹配。" : "以下进程的 lsof 端点主机名在最近 5 分钟内匹配。"
    }

    private func evidenceDetails(_ items: [NetworkEvidence], error: String?) -> String {
        var lines: [String] = []
        if let error { lines.append("采样错误：\(error)\n") }
        if items.isEmpty {
            lines.append("(none)\n")
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss"
            for item in items {
                lines.append("PID \(item.pid)  \(item.processName)")
                lines.append("  时间：\(formatter.string(from: item.observedAt))")
                lines.append("  匹配：\(item.matchedDomain)")
                lines.append("  连接：\(item.endpoint)\n")
            }
        }
        lines.append("说明：这是 lsof 对远端地址反向解析出的主机名证据，不是 HTTP 内容、DNS 查询或 SNI 记录。共享 CDN IP 不作为证据；代理隐藏域名时会显示未命中。")
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
            let uniqueItems = items.filter { seen.insert($0.pid).inserted }
            var lines: [String] = []

            for item in uniqueItems {
                guard item.pid > 1 else {
                    lines.append("跳过 PID \(item.pid)：不安全的特殊 PID。")
                    continue
                }
                // macOS has no pidfd-style atomic check-and-signal API. Keep the
                // identity check immediately adjacent to kill to minimize the race.
                guard captureProcessIdentity(pid: item.pid) == item.identity else {
                    lines.append("跳过 PID \(item.pid)：进程身份已改变或进程已经退出。")
                    continue
                }
                if Darwin.kill(item.pid, signal) == 0 {
                    lines.append("已向 PID \(item.pid)（\(item.processName)）发送 \(signal == SIGTERM ? "SIGTERM" : "SIGKILL")。")
                } else {
                    lines.append("PID \(item.pid) 信号发送失败：errno \(errno)。")
                }
            }

            if waitSeconds > 0 {
                for _ in 0..<waitSeconds {
                    let remaining = uniqueItems.contains { captureProcessIdentity(pid: $0.pid) == $0.identity }
                    if !remaining { break }
                    Thread.sleep(forTimeInterval: 1)
                }
            }

            let remaining = uniqueItems.filter { captureProcessIdentity(pid: $0.pid) == $0.identity }
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
    guard let ownIdentity = captureProcessIdentity(pid: getpid()),
          ownIdentity.pid == getpid(),
          !ownIdentity.executablePath.isEmpty else {
        FileHandle.standardError.write(Data("SELF_TEST_FAILED: native process identity unavailable\n".utf8))
        exit(1)
    }
    let domainTestsPassed =
        ClaudeConnectionObserver.matchedDomain(in: "127.0.0.1:50000->anthropic.com:443") == "anthropic.com" &&
        ClaudeConnectionObserver.matchedDomain(in: "127.0.0.1:50000->api.anthropic.com:443") == "anthropic.com" &&
        ClaudeConnectionObserver.matchedDomain(in: "127.0.0.1:50000->claude.ai:443") == "claude.ai" &&
        ClaudeConnectionObserver.matchedDomain(in: "127.0.0.1:50000->anthropic.com-evil.example:443") == nil &&
        ClaudeConnectionObserver.matchedDomain(in: "anthropic.com:443") == nil
    guard domainTestsPassed else {
        FileHandle.standardError.write(Data("SELF_TEST_FAILED: endpoint domain parser\n".utf8))
        exit(1)
    }
    print("SELF_TEST_OK")
    print("Native identity and endpoint parser checks passed. No signal was sent.")
    exit(0)
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
