// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit

/// P20d: the Task Manager's window, as Chrome's: Task, Profile, Memory Footprint, CPU, Network, Process ID, and End
/// Process for the selected rows. An ordinary window of Airc's, one at a time; closing it stops the sampling.
final class TaskManagerWindow: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private(set) static var shared: TaskManagerWindow?

    let model: TaskManager
    let window: NSWindow
    let table = NSTableView()
    let endButton = NSButton(title: "End Process", target: nil, action: nil)
    let noteLabel = NSTextField(wrappingLabelWithString: "")
    /// The title is in the content, beside the window's buttons (as Arc's own panels have it).
    let titleLabel = NSTextField(labelWithString: "Task Manager")
    /// The rows in the table's order (the model's, or sorted by a column with each process's tasks kept together).
    private(set) var shown: [TaskManager.Row] = []

    /// Opens it, or brings it forward. From a private window it names that window's own pages; from any other, none.
    static func show(from opener: NSWindow?, app: AppDelegate?) {
        let viewer = PrivateBrowsing.shared.window(for: opener)
        let w = shared ?? TaskManagerWindow(app: app)
        shared = w
        if w.model.viewer !== viewer || !w.model.isRunning {
            w.model.viewer = viewer
            w.setTitle(viewer == nil ? "Task Manager" : "Task Manager — Private Window")
            w.model.stop()
            w.model.start()
        }
        if !w.window.isVisible, let p = opener?.frame {
            w.window.setFrameOrigin(NSPoint(x: p.midX - w.window.frame.width / 2, y: p.midY - w.window.frame.height / 2))
        }
        w.window.makeKeyAndOrderFront(nil)
    }

    private init(app: AppDelegate?) {
        model = TaskManager(app: app)
        window = TaskManagerPanelWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 440),
                                        styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                        backing: .buffered, defer: true)
        super.init()
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        setTitle("Task Manager")
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 520, height: 240)
        window.delegate = self
        window.center()
        build()
        model.onChange = { [weak self] in self?.reload() }
    }

    /// Their widths and spacing (about 17 pt each) fit the window's 820 pt, so Process ID shows without scrolling.
    private static let columns: [(id: String, title: String, width: CGFloat, right: Bool)] = [
        ("task", "Task", 240, false), ("profile", "Profile", 110, false), ("memory", "Memory Footprint", 120, true),
        ("cpu", "CPU", 60, true), ("network", "Network", 80, true), ("pid", "Process ID", 80, true),
    ]

    private func build() {
        for c in Self.columns {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(c.id))
            col.title = c.title
            col.width = c.width
            col.minWidth = 44
            col.headerCell.alignment = c.right ? .right : .left
            col.sortDescriptorPrototype = NSSortDescriptor(key: c.id, ascending: c.id == "task" || c.id == "profile")
            table.addTableColumn(col)
        }
        table.style = .fullWidth
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.rowHeight = 22
        table.dataSource = self
        table.delegate = self
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder

        endButton.target = self
        endButton.action = #selector(endProcess)
        endButton.bezelStyle = .rounded
        endButton.isEnabled = false
        noteLabel.font = .systemFont(ofSize: 11)
        noteLabel.textColor = .secondaryLabelColor
        noteLabel.maximumNumberOfLines = 3

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.alignment = .center
        let content = TaskManagerContentView()
        for v in [titleLabel, scroll, endButton, noteLabel] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            titleLabel.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: content.topAnchor, constant: 15),
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 30),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            endButton.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 12),
            endButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            endButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
            noteLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            noteLabel.trailingAnchor.constraint(lessThanOrEqualTo: endButton.leadingAnchor, constant: -16),
            noteLabel.centerYAnchor.constraint(equalTo: endButton.centerYAnchor),
        ])
        window.contentView = content
    }

    // MARK: Rows

    private func reload() {
        let keys = Set(table.selectedRowIndexes.compactMap { shown.indices.contains($0) ? shown[$0].key : nil })
        shown = sorted(model.rows)
        table.reloadData()
        table.selectRowIndexes(IndexSet(shown.indices.filter { keys.contains(shown[$0].key) }), byExtendingSelection: false)
        noteLabel.stringValue = model.note
        // The private window it named went away: its pages are nameless now.
        if model.viewer == nil { setTitle("Task Manager") }
        updateButton()
    }

    /// By the clicked column, each process's rows kept together under its first (Chrome sorts its groups the same way).
    private func sorted(_ rows: [TaskManager.Row]) -> [TaskManager.Row] {
        guard let d = table.sortDescriptors.first, let key = d.key else { return rows }
        var groups: [[TaskManager.Row]] = []
        for r in rows {
            if r.firstOfProcess || groups.isEmpty { groups.append([r]) } else { groups[groups.count - 1].append(r) }
        }
        func value(_ g: [TaskManager.Row]) -> Double {
            switch key {
            case "memory": return Double(g[0].memory ?? -1)
            case "cpu": return g[0].cpu ?? -1
            case "network": return Double(g.reduce(Int64(0)) { $0 + ($1.network ?? 0) })
            case "pid": return Double(g[0].pid)
            default: return 0
            }
        }
        let text = { (g: [TaskManager.Row]) in key == "profile" ? g[0].profile : g[0].title }
        groups.sort { a, b in
            if key == "task" || key == "profile" {
                let c = text(a).localizedStandardCompare(text(b))
                return d.ascending ? c == .orderedAscending : c == .orderedDescending
            }
            return d.ascending ? value(a) < value(b) : value(a) > value(b)
        }
        return groups.flatMap { $0 }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier.rawValue, shown.indices.contains(row) else { return nil }
        let r = shown[row]
        let cell = tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("cell." + id), owner: self) as? TaskManagerCell
            ?? TaskManagerCell(id: id, right: Self.columns.first { $0.id == id }?.right ?? false)
        switch id {
        case "task": cell.set(r.title, symbol: r.symbol)
        case "profile": cell.set(r.profile)
        case "memory": cell.set(r.memory.map(Self.bytes) ?? "")
        case "cpu": cell.set(r.cpu.map { String(format: "%.1f", $0) } ?? "")
        case "network": cell.set(r.network.map { $0 > 0 ? Self.bytes($0) + "/s" : "0" } ?? "–")
        case "pid": cell.set(r.firstOfProcess && r.pid > 0 ? String(r.pid) : "")
        default: break
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateButton() }
    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) { reload() }

    private var selectedRows: [TaskManager.Row] { table.selectedRowIndexes.compactMap { shown.indices.contains($0) ? shown[$0] : nil } }

    private func updateButton() {
        let s = selectedRows
        endButton.isEnabled = !s.isEmpty && s.allSatisfy(\.canEnd)
    }

    @objc func endProcess() {
        let s = selectedRows
        guard !s.isEmpty, s.allSatisfy(\.canEnd) else { return NSSound.beep() }
        model.end(s)
    }

    static func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .memory)
    }

    // MARK: Window

    /// The window's title (the Window menu's, VoiceOver's) and the one drawn in its content.
    private func setTitle(_ title: String) {
        window.title = title
        titleLabel.stringValue = title
    }

    func windowWillClose(_ notification: Notification) {
        model.stop()
        model.viewer = nil
    }
}

/// ⌘W closes this window. Without it the main menu's Close Tab would close a tab of the browser window behind it.
final class TaskManagerPanelWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods == .command, event.charactersIgnoringModifiers == "w" { performClose(nil); return true }
        return super.performKeyEquivalent(with: event)
    }
}

/// The content draws the window's own background, so the title strip and the End Process bar look the same in an image
/// of the content alone (the marketing shot) as on screen, where the window draws it behind them.
final class TaskManagerContentView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }
}

final class TaskManagerCell: NSTableCellView {
    private let label = NSTextField(labelWithString: "")
    private let icon = NSImageView()

    init(id: String, right: Bool) {
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier("cell." + id)
        label.lineBreakMode = .byTruncatingTail
        label.alignment = right ? .right : .left
        label.font = right ? .monospacedDigitSystemFont(ofSize: 12, weight: .regular) : .systemFont(ofSize: 12)
        textField = label
        for v in [label, icon] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        let showsIcon = id == "task"
        icon.isHidden = !showsIcon
        icon.contentTintColor = .secondaryLabelColor
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: showsIcon ? 16 : 0),
            icon.heightAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: showsIcon ? 6 : 0),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(_ text: String, symbol: String? = nil) {
        label.stringValue = text
        if let symbol { icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
    }
}
