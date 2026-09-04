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
    private var liveCount = 0

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 510))
        preferredContentSize = view.frame.size
        let header = NSTextField(labelWithString: "相关 App")
        header.font = .systemFont(ofSize: 19, weight: .semibold)
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
        let quitWatcher = NSButton(title: "退出 Watcher", target: self, action: #selector(quitWatcherClicked))
        quitWatcher.bezelStyle = .inline
        quitWatcher.font = .systemFont(ofSize: 11)
        quitAll.bezelStyle = .rounded
        quitAll.target = self
        quitAll.action = #selector(quitAllClicked)
        quitAll.isEnabled = false
        let subviews: [NSView] = [header, summary, divider, scroll, empty, notice, footerDivider, quitWatcher, quitAll]
        for subview in subviews {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 22),
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
    }

    func update(items: [NetworkEvidence], warning: String?) {
        _ = view // NSViewController loads lazily; also supports macOS 13.
        self.displayedItems = items
        self.warning = warning
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
        summary.stringValue = "\(groups.count) 个 App · \(liveCount) 个运行中进程 · 自动更新"
        notice.stringValue = warning ?? "显示 Claude 客户端及最近 5 分钟有相关连接的 App。\nClash 等网络工具始终排除。"
        notice.toolTip = notice.stringValue
        notice.textColor = warning == nil ? .secondaryLabelColor : .systemOrange
        empty.isHidden = !groups.isEmpty
        outline.reloadData()
        for group in groups where expanded.contains(group.owner) { outline.expandItem(group) }
        scroll.contentView.scroll(to: origin)
        scroll.reflectScrolledClipView(scroll.contentView)
        quitAll.isEnabled = !busy && liveCount > 0
        loadIcons()
    }

    func setBusy(_ value: Bool) {
        busy = value
        quitAll.title = value ? "正在退出…" : "退出全部相关 App…"
        quitAll.isEnabled = !value && liveCount > 0
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
            cell.subtitle.stringValue = "\(running) 个运行中进程" + (domains.isEmpty ? " · 已识别客户端" : " · \(domains.count) 个相关域名")
            cell.icon.image = icons[group.owner.path] ?? NSImage(systemSymbolName: "app.dashed", accessibilityDescription: group.owner.name)
            cell.icon.setAccessibilityLabel(group.owner.name + " 图标")
            cell.toolTip = group.owner.path
        } else if let row = item as? ProcessRow {
            cell.title.stringValue = row.evidence.processName
            let basis = row.evidence.matchedDomain.isEmpty ? row.evidence.kind.rawValue : row.evidence.matchedDomain
            cell.subtitle.stringValue = "PID \(row.evidence.pid) · \(row.isRunning ? basis : "已退出 · " + basis)"
            cell.toolTip = "\(row.evidence.kind.rawValue)\n\(row.evidence.identity.executablePath)\n\(row.evidence.matchedDomain)"
        }
        return cell
    }
}
