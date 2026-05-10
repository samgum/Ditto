import AppKit
import Darwin

struct ClipboardEntry: Codable, Equatable {
    let id: UUID
    let text: String
    let createdAt: Date

    var preview: String {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard normalized.count > 160 else {
            return normalized
        }

        let end = normalized.index(normalized.startIndex, offsetBy: 160)
        return String(normalized[..<end]) + "..."
    }
}

final class ClipboardStore {
    private let fileURL: URL
    private(set) var entries: [ClipboardEntry] = []

    init() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        let directory = appSupport.appendingPathComponent("Ditto", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        fileURL = directory.appendingPathComponent("history.json")
        load()
    }

    func add(text: String) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.isEmpty == false else {
            return
        }

        if entries.first?.text == text {
            return
        }

        entries.removeAll { $0.text == text }
        entries.insert(
            ClipboardEntry(id: UUID(), text: text, createdAt: Date()),
            at: 0
        )

        if entries.count > 500 {
            entries.removeLast(entries.count - 500)
        }

        save()
    }

    func removeAll() {
        entries.removeAll()
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else {
            return
        }

        entries = (try? JSONDecoder().decode([ClipboardEntry].self, from: data)) ?? []
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        guard let data = try? encoder.encode(entries) else {
            return
        }

        try? data.write(to: fileURL, options: .atomic)
    }
}

final class ClipboardMonitor {
    private let pasteboard = NSPasteboard.general
    private let store: ClipboardStore
    private var lastChangeCount: Int
    private var timer: Timer?
    var onChange: (() -> Void)?

    init(store: ClipboardStore) {
        self.store = store
        lastChangeCount = NSPasteboard.general.changeCount
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    private func poll() {
        guard pasteboard.changeCount != lastChangeCount else {
            return
        }

        lastChangeCount = pasteboard.changeCount

        guard let text = pasteboard.string(forType: .string) else {
            return
        }

        store.add(text: text)
        onChange?()
    }
}

final class LoginAgentManager {
    private let label = "org.ditto-cp.Ditto"

    private var launchAgentsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("LaunchAgents", isDirectory: true)
    }

    private var plistURL: URL {
        launchAgentsDirectory.appendingPathComponent("\(label).plist")
    }

    func installOrRefresh() {
        guard let executableURL = Bundle.main.executableURL else {
            return
        }

        try? FileManager.default.createDirectory(
            at: launchAgentsDirectory,
            withIntermediateDirectories: true
        )

        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executableURL.path],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ProcessType": "Interactive"
        ]

        guard let data = try? PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        ) else {
            return
        }

        try? data.write(to: plistURL, options: .atomic)
    }

    func disable() {
        let domain = "gui/\(getuid())"
        _ = runLaunchctl(arguments: ["bootout", domain, plistURL.path])
        _ = runLaunchctl(arguments: ["bootout", "\(domain)/\(label)"])
        try? FileManager.default.removeItem(at: plistURL)
    }

    private func runLaunchctl(arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}

final class HistoryWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let store: ClipboardStore
    private let searchField = NSSearchField()
    private let tableView = NSTableView()
    private var filteredEntries: [ClipboardEntry] = []
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        return formatter
    }()

    init(store: ClipboardStore) {
        self.store = store

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 460),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Ditto"
        window.center()

        super.init(window: window)
        filteredEntries = store.entries
        configureContent()
    }

    required init?(coder: NSCoder) {
        nil
    }

    func refresh() {
        applySearch()
    }

    private func applySearch() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

        if query.isEmpty {
            filteredEntries = store.entries
        } else {
            filteredEntries = store.entries.filter {
                $0.text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }

        tableView.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        filteredEntries.count
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard row < filteredEntries.count else {
            return nil
        }

        let entry = filteredEntries[row]
        let identifier = tableColumn?.identifier ?? NSUserInterfaceItemIdentifier("clip")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
            ?? NSTableCellView()

        let textField = cell.textField ?? NSTextField(labelWithString: "")
        textField.lineBreakMode = .byTruncatingTail
        textField.font = NSFont.systemFont(ofSize: 13)

        if tableColumn?.identifier.rawValue == "date" {
            textField.stringValue = dateFormatter.string(from: entry.createdAt)
        } else {
            textField.stringValue = entry.preview
        }

        if cell.textField == nil {
            cell.textField = textField
            textField.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(textField)
            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }

        cell.identifier = identifier
        return cell
    }

    @objc private func copySelectedEntry() {
        let row = tableView.selectedRow
        guard row >= 0, row < filteredEntries.count else {
            return
        }

        let entry = filteredEntries[row]
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(entry.text, forType: .string)
    }

    @objc private func searchChanged() {
        applySearch()
    }

    @objc private func clearHistory() {
        store.removeAll()
        refresh()
    }

    private func configureContent() {
        guard let window else {
            return
        }

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        searchField.placeholderString = "Search"
        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchField.sendsSearchStringImmediately = true
        searchField.translatesAutoresizingMaskIntoConstraints = false

        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowHeight = 30
        tableView.headerView = nil
        tableView.delegate = self
        tableView.dataSource = self
        tableView.target = self
        tableView.doubleAction = #selector(copySelectedEntry)

        let clipColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("clip"))
        clipColumn.title = "Clip"
        clipColumn.width = 560
        tableView.addTableColumn(clipColumn)

        let dateColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("date"))
        dateColumn.title = "Date"
        dateColumn.width = 180
        tableView.addTableColumn(dateColumn)

        scrollView.documentView = tableView

        let copyButton = NSButton(
            title: "Copy",
            target: self,
            action: #selector(copySelectedEntry)
        )
        copyButton.bezelStyle = .rounded

        let clearButton = NSButton(
            title: "Clear",
            target: self,
            action: #selector(clearHistory)
        )
        clearButton.bezelStyle = .rounded

        let toolbar = NSStackView(views: [copyButton, clearButton])
        toolbar.orientation = .horizontal
        toolbar.spacing = 8
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        root.addSubview(searchField)
        root.addSubview(scrollView)
        root.addSubview(toolbar)
        window.contentView = root

        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            searchField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            searchField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),

            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            toolbar.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -12),
            toolbar.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),

            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: toolbar.topAnchor, constant: -12)
        ])
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = ClipboardStore()
    private let loginAgentManager = LoginAgentManager()
    private var monitor: ClipboardMonitor?
    private var statusItem: NSStatusItem?
    private var historyWindowController: HistoryWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        ProcessInfo.processInfo.disableAutomaticTermination(
            "Ditto monitors the clipboard from the menu bar."
        )
        loginAgentManager.installOrRefresh()
        configureStatusItem()

        let monitor = ClipboardMonitor(store: store)
        monitor.onChange = { [weak self] in
            self?.historyWindowController?.refresh()
        }
        monitor.start()
        self.monitor = monitor
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    @objc private func showHistory() {
        if historyWindowController == nil {
            historyWindowController = HistoryWindowController(store: store)
        }

        historyWindowController?.refresh()
        historyWindowController?.showWindow(nil)
        historyWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quit() {
        loginAgentManager.disable()
        NSApp.terminate(nil)
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "Ditto"

        let menu = NSMenu()
        let showHistoryItem = NSMenuItem(
            title: "Show History",
            action: #selector(showHistory),
            keyEquivalent: ""
        )
        showHistoryItem.target = self
        menu.addItem(showHistoryItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit Ditto",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        item.menu = menu
        statusItem = item
    }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
