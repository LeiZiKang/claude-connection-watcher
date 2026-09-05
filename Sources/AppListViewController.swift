import AppKit

private final class AppGroup: NSObject {
    let owner: AppOwner
    var processes: [ProcessRow] = []
    init(owner: AppOwner) { self.owner = owner }
}

private final class ProcessRow: NSObject {
    let evidence: NetworkEvidence
    let isRunning: Bool
    init(_ evidence: NetworkEvidence) {
        self.evidence = evidence
        isRunning = captureProcessIdentity(pid: evidence.pid) == evidence.identity
    }
}

private final class AppListCell: NSTableCellView {
    let title = NSTextField(labelWithString: "")
    let subtitle = NSTextField(labelWithString: "")
    let icon = NSImageView()

    init(appRow: Bool) {
        super.init(frame: .zero)
        title.font = .systemFont(ofSize: appRow ? 13 : 12, weight: appRow ? .semibold : .regular)
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        title.lineBreakMode = .byTruncatingTail
        subtitle.lineBreakMode = .byTruncatingTail
        icon.imageScaling = .scaleProportionallyUpOrDown
        let labels = NSStackView(views: [title, subtitle])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 4
        labels.translatesAutoresizingMaskIntoConstraints = false
        addSubview(labels)
        if appRow {
            icon.translatesAutoresizingMaskIntoConstraints = false
            addSubview(icon)
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
                icon.centerYAnchor.constraint(equalTo: centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 32),
                icon.heightAnchor.constraint(equalToConstant: 32),
                labels.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12)
            ])
        } else {
            labels.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8).isActive = true
        }
        NSLayoutConstraint.activate([
            labels.centerYAnchor.constraint(equalTo: centerYAnchor),
            labels.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12)
        ])
        textField = title
        imageView = appRow ? icon : nil
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// A cached snapshot drives the list. Icon file access stays off the UI thread.
final class AppListViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    var onQuitAll: (([NetworkEvidence], String?) -> Void)?
    var onQuitWatcher: (() -> Void)?
    var onRefresh: (() -> Void)?
    var onLanguageChange: (() -> Void)?
    private let header = NSTextField(labelWithString: "")
    private let refreshButton = NSButton(title: "", target: nil, action: nil)
    private let languagePicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let quitWatcher = NSButton(title: "", target: nil, action: nil)
    private let outline = NSOutlineView()
    private let scroll = NSScrollView()
    private let summary = NSTextField(labelWithString: "正在识别相关 App…")
    private let notice = NSTextField(wrappingLabelWithString: "")
    private let empty = NSTextField(wrappingLabelWithString: "暂未发现相关 App\n识别结果会自动显示在这里")
    private let quitAll = NSButton(title: "退出全部相关 App…", target: nil, action: nil)
    private let iconQueue = DispatchQueue(label: "ClaudeConnectionWatcher.AppIcons", qos: .utility)
    private var icons: [String: NSImage] = [:]
    private var pendingIcons = Set<String>()
    private var groups: [AppGroup] = []
    private var displayedItems: [NetworkEvidence] = []
    private var warning: String?
    private var busy = false
    private var refreshing = false
    private var liveCount = 0

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 510))
        preferredContentSize = view.frame.size
        header.font = .systemFont(ofSize: 19, weight: .semibold)
        refreshButton.bezelStyle = .rounded
        refreshButton.target = self
        refreshButton.action = #selector(refreshClicked)
        languagePicker.addItems(withTitles: ["中文", "English"])
        languagePicker.target = self
        languagePicker.action = #selector(languageChanged)
        summary.font = .systemFont(ofSize: 12)
        summary.textColor = .secondaryLabelColor
        let divider = NSBox()
        divider.boxType = .separator

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("app"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.indentationPerLevel = 16
        outline.intercellSpacing = NSSize(width: 0, height: 0)
        outline.style = .fullWidth
        outline.backgroundColor = .clear
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.doubleAction = #selector(toggleGroup)
        outline.setAccessibilityLabel("Claude 相关 App 与进程列表")
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        empty.alignment = .center
        empty.textColor = .secondaryLabelColor
        empty.font = .systemFont(ofSize: 13)

        notice.font = .systemFont(ofSize: 11)
        notice.textColor = .secondaryLabelColor
        notice.maximumNumberOfLines = 3
        let footerDivider = NSBox()
        footerDivider.boxType = .separator
        quitWatcher.target = self
        quitWatcher.action = #selector(quitWatcherClicked)
        quitWatcher.bezelStyle = .inline
        quitWatcher.font = .systemFont(ofSize: 11)
        quitAll.bezelStyle = .rounded
        quitAll.target = self
        quitAll.action = #selector(quitAllClicked)
        quitAll.isEnabled = false
        let subviews: [NSView] = [header, summary, refreshButton, languagePicker, divider, scroll, empty, notice, footerDivider, quitWatcher, quitAll]
        for subview in subviews {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 22),
            header.trailingAnchor.constraint(lessThanOrEqualTo: refreshButton.leadingAnchor, constant: -10),
            languagePicker.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            languagePicker.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            languagePicker.widthAnchor.constraint(equalToConstant: 100),
            refreshButton.trailingAnchor.constraint(equalTo: languagePicker.leadingAnchor, constant: -8),
            refreshButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            refreshButton.widthAnchor.constraint(equalToConstant: 110),
            summary.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 6),
            summary.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            summary.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -22),
            divider.topAnchor.constraint(equalTo: summary.bottomAnchor, constant: 16),
            divider.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            scroll.bottomAnchor.constraint(equalTo: notice.topAnchor, constant: -12),
            empty.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            empty.widthAnchor.constraint(equalTo: scroll.widthAnchor, constant: -32),
            notice.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 22),
            notice.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -22),
            notice.bottomAnchor.constraint(equalTo: footerDivider.topAnchor, constant: -12),
            notice.heightAnchor.constraint(equalToConstant: 44),
            footerDivider.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            footerDivider.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            footerDivider.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -60),
            quitWatcher.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            quitWatcher.centerYAnchor.constraint(equalTo: quitAll.centerYAnchor),
            quitAll.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            quitAll.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16)
        ])
        localizeControls()
    }

    func update(items: [NetworkEvidence], warning: String?) {
        _ = view // NSViewController loads lazily; also supports macOS 13.
        self.displayedItems = items
        self.warning = warning
        localizeControls()
        let expanded = Set(groups.filter { outline.isItemExpanded($0) }.map { $0.owner })
        let origin = scroll.contentView.bounds.origin
        let prior = Dictionary(uniqueKeysWithValues: groups.map { ($0.owner, $0) })
        let grouped = Dictionary(grouping: items, by: { $0.process.owner })
        groups = grouped.keys.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }.map { owner in
            let group = prior[owner] ?? AppGroup(owner: owner)
            group.processes = grouped[owner]!.sorted { $0.pid < $1.pid }.map(ProcessRow.init)
            return group
        }
        liveCount = groups.reduce(0) { $0 + $1.processes.filter(\.isRunning).count }
        summary.stringValue = L10n.text("\(groups.count) 个 App · \(liveCount) 个运行中进程 · 自动更新", "Apps: \(groups.count) · Running: \(liveCount) · Auto-update")
        notice.stringValue = warning ?? L10n.text("显示 Claude 客户端及最近 5 分钟有相关连接的 App。\nClash 等网络工具始终排除。", "Claude clients and apps with related connections in the past 5 minutes.\nNetwork tools such as Clash are excluded.")
        notice.toolTip = notice.stringValue
        notice.textColor = warning == nil ? .secondaryLabelColor : .systemOrange
        empty.isHidden = !groups.isEmpty
        outline.reloadData()
        for group in groups where expanded.contains(group.owner) { outline.expandItem(group) }
        scroll.contentView.scroll(to: origin)
        scroll.reflectScrolledClipView(scroll.contentView)
        quitAll.isEnabled = !busy && !refreshing && liveCount > 0
        loadIcons()
    }

    func setBusy(_ value: Bool) {
        busy = value
        localizeControls()
    }

    func setRefreshing(_ value: Bool) {
        refreshing = value
        localizeControls()
    }

    private func localizeControls() {
        header.stringValue = L10n.text("相关 App", "Related apps")
        refreshButton.title = refreshing ? L10n.text("刷新中…", "Refreshing…") : L10n.text("刷新", "Refresh")
        refreshButton.toolTip = L10n.text("立即重新采样", "Sample connections now")
        refreshButton.isEnabled = !busy && !refreshing
        languagePicker.selectItem(at: L10n.language == .chinese ? 0 : 1)
        languagePicker.setAccessibilityLabel(L10n.text("语言", "Language"))
        languagePicker.isEnabled = !busy
        quitWatcher.title = L10n.text("退出 Watcher", "Quit Watcher")
        quitAll.title = busy ? L10n.text("正在退出…", "Quitting…") : L10n.text("退出全部相关 App…", "Quit all related apps…")
        quitAll.isEnabled = !busy && !refreshing && liveCount > 0
        empty.stringValue = L10n.text("暂未发现相关 App\n识别结果会自动显示在这里", "No related apps found yet\nResults will appear here automatically")
        outline.setAccessibilityLabel(L10n.text("Claude 相关 App 与进程列表", "Claude-related apps and processes"))
    }

    @objc private func refreshClicked() { onRefresh?() }
    @objc private func languageChanged() {
        L10n.language = languagePicker.indexOfSelectedItem == 0 ? .chinese : .english
        localizeControls()
        onLanguageChange?()
    }

    private func loadIcons() {
        for path in Set(groups.map { $0.owner.path }) where icons[path] == nil && pendingIcons.insert(path).inserted {
            iconQueue.async { [weak self] in
                let image = NSWorkspace.shared.icon(forFile: path)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.pendingIcons.remove(path)
                    self.icons[path] = image
                    for group in self.groups where group.owner.path == path {
                        let row = self.outline.row(forItem: group)
                        if row >= 0 { self.outline.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0)) }
                    }
                }
            }
        }
    }

    @objc private func quitAllClicked() { onQuitAll?(displayedItems, warning) }
    @objc private func quitWatcherClicked() { onQuitWatcher?() }
    @objc private func toggleGroup() {
        guard let group = outline.item(atRow: outline.clickedRow) as? AppGroup else { return }
        if outline.isItemExpanded(group) { outline.collapseItem(group) }
        else { outline.expandItem(group) }
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if let group = item as? AppGroup { return group.processes.count }
        return item == nil ? groups.count : 0
    }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { item is AppGroup }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let group = item as? AppGroup { return group.processes[index] }
        return groups[index]
    }
    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat { item is AppGroup ? 62 : 48 }
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let group = item as? AppGroup
        let identifier = NSUserInterfaceItemIdentifier(group == nil ? "process" : "group")
        let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? AppListCell ?? AppListCell(appRow: group != nil)
        cell.identifier = identifier
        if let group {
            cell.title.stringValue = group.owner.name
            let running = group.processes.filter(\.isRunning).count
            let domains = Set(group.processes.flatMap { $0.evidence.matchedDomain.components(separatedBy: ", ") }.filter { !$0.isEmpty })
            cell.subtitle.stringValue = L10n.text("\(running) 个运行中进程", "Running: \(running)") + (domains.isEmpty ? L10n.text(" · 已识别客户端", " · Verified client") : L10n.text(" · \(domains.count) 个相关域名", " · Domains: \(domains.count)"))
            cell.icon.image = icons[group.owner.path] ?? NSImage(systemSymbolName: "app.dashed", accessibilityDescription: group.owner.name)
            cell.icon.setAccessibilityLabel(group.owner.name + L10n.text(" 图标", " icon"))
            cell.toolTip = group.owner.path
        } else if let row = item as? ProcessRow {
            cell.title.stringValue = row.evidence.processName
            let basis = row.evidence.matchedDomain.isEmpty ? row.evidence.kind.localizedDescription : row.evidence.matchedDomain
            cell.subtitle.stringValue = "PID \(row.evidence.pid) · \(row.isRunning ? basis : L10n.text("已退出 · ", "Exited · ") + basis)"
            cell.toolTip = "\(row.evidence.kind.localizedDescription)\n\(row.evidence.identity.executablePath)\n\(row.evidence.matchedDomain)"
        }
        return cell
    }
}
