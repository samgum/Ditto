import AppKit
import Carbon
import CoreGraphics
import Darwin

extension NSPasteboard.PasteboardType {
    static let dittoHTML = NSPasteboard.PasteboardType("public.html")
}

struct ClipboardEntry: Codable, Equatable {
    let id: UUID
    let text: String?
    let rtfFileName: String?
    let htmlFileName: String?
    let imageFileName: String?
    let fileURLs: [String]?
    let createdAt: Date

    var isImage: Bool {
        imageFileName != nil
    }

    var isRichText: Bool {
        rtfFileName != nil
    }

    var isHTML: Bool {
        htmlFileName != nil
    }

    var isFileDrop: Bool {
        fileURLs?.isEmpty == false
    }

    var typeLabel: String {
        if isFileDrop {
            return "Files"
        }

        if isImage {
            return "Image"
        }

        if isRichText {
            return "RTF"
        }

        if isHTML {
            return "HTML"
        }

        return "Text"
    }

    var searchableText: String {
        var values: [String] = []

        if let text {
            values.append(text)
        }

        if let fileURLs {
            values.append(contentsOf: fileURLs)
        }

        values.append(typeLabel)
        return values.joined(separator: "\n")
    }

    var preview: String {
        if let fileURLs, fileURLs.isEmpty == false {
            let names = fileURLs.map { URL(fileURLWithPath: $0).lastPathComponent }
            return truncated(names.joined(separator: ", "))
        }

        if let text {
            return truncated(text)
        }

        return typeLabel
    }

    private func truncated(_ value: String) -> String {
        let normalized = value
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
    private let dataDirectory: URL
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
        dataDirectory = directory.appendingPathComponent("Data", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dataDirectory,
            withIntermediateDirectories: true
        )
        load()
    }

    func addClipboardPayload(
        text: String?,
        rtfData: Data?,
        htmlData: Data?,
        imageData: Data?,
        fileURLs: [URL]
    ) {
        let normalizedText = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        let files = fileURLs.map { $0.path }

        guard
            normalizedText?.isEmpty == false ||
            rtfData?.isEmpty == false ||
            htmlData?.isEmpty == false ||
            imageData?.isEmpty == false ||
            files.isEmpty == false
        else {
            return
        }

        if
            entries.first?.text == text,
            entries.first?.fileURLs == files,
            files.isEmpty == false || text != nil
        {
            return
        }

        if let text {
            removeEntries { $0.text == text && $0.fileURLs == files }
        }

        let rtfFileName = saveBlob(rtfData, fileExtension: "rtf")
        let htmlFileName = saveBlob(htmlData, fileExtension: "html")
        let imageFileName = saveBlob(imageData, fileExtension: "png")

        entries.insert(
            ClipboardEntry(
                id: UUID(),
                text: text,
                rtfFileName: rtfFileName,
                htmlFileName: htmlFileName,
                imageFileName: imageFileName,
                fileURLs: files.isEmpty ? nil : files,
                createdAt: Date()
            ),
            at: 0
        )

        trim()
        save()
    }

    func entry(id: UUID) -> ClipboardEntry? {
        entries.first { $0.id == id }
    }

    func copyToPasteboard(_ entry: ClipboardEntry) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        var pasteboardItems: [NSPasteboardItem] = []

        let item = NSPasteboardItem()
        var hasItemData = false

        if let text = entry.text {
            item.setString(text, forType: .string)
            hasItemData = true
        }

        if let rtfFileName = entry.rtfFileName, let data = blobData(named: rtfFileName) {
            item.setData(data, forType: .rtf)
            hasItemData = true
        }

        if let htmlFileName = entry.htmlFileName, let data = blobData(named: htmlFileName) {
            item.setData(data, forType: .dittoHTML)
            hasItemData = true
        }

        if hasItemData {
            pasteboardItems.append(item)
        }

        if let imageFileName = entry.imageFileName, let data = blobData(named: imageFileName) {
            let imageItem = NSPasteboardItem()
            imageItem.setData(data, forType: .png)
            pasteboardItems.append(imageItem)
        }

        if let fileURLs = entry.fileURLs {
            for fileURL in fileURLs.map({ URL(fileURLWithPath: $0) }) {
                let fileItem = NSPasteboardItem()
                fileItem.setString(fileURL.absoluteString, forType: .fileURL)
                pasteboardItems.append(fileItem)
            }
        }

        if pasteboardItems.isEmpty == false {
            pasteboard.writeObjects(pasteboardItems)
        }
    }

    func removeEntry(id: UUID) {
        removeEntries { $0.id == id }
        save()
    }

    private func removeEntries(where predicate: (ClipboardEntry) -> Bool) {
        let removed = entries.filter(predicate)
        for entry in removed {
            removeBlobFiles(for: entry)
        }
        entries.removeAll(where: predicate)
    }

    private func saveBlob(_ data: Data?, fileExtension: String) -> String? {
        guard let data, data.isEmpty == false else {
            return nil
        }

        let fileName = "\(UUID().uuidString).\(fileExtension)"
        let fileURL = dataDirectory.appendingPathComponent(fileName)

        guard (try? data.write(to: fileURL, options: .atomic)) != nil else {
            return nil
        }

        return fileName
    }

    private func blobData(named fileName: String) -> Data? {
        try? Data(contentsOf: dataDirectory.appendingPathComponent(fileName))
    }

    private func removeBlobFiles(for entry: ClipboardEntry) {
        for fileName in [entry.rtfFileName, entry.htmlFileName, entry.imageFileName].compactMap({ $0 }) {
            try? FileManager.default.removeItem(
                at: dataDirectory.appendingPathComponent(fileName)
            )
        }
    }

    func legacyImageData(for entry: ClipboardEntry) -> Data? {
        guard let imageFileName = entry.imageFileName else {
            return nil
        }

        if let data = blobData(named: imageFileName) {
            return data
        }

        let legacyImagesDirectory = fileURL
            .deletingLastPathComponent()
            .appendingPathComponent("Images", isDirectory: true)

        return try? Data(contentsOf: legacyImagesDirectory.appendingPathComponent(imageFileName))
    }

    func imageData(for entry: ClipboardEntry) -> Data? {
        legacyImageData(for: entry)
    }

    func removeAll() {
        entries.removeAll()
        try? FileManager.default.removeItem(at: dataDirectory)
        try? FileManager.default.createDirectory(
            at: dataDirectory,
            withIntermediateDirectories: true
        )
        save()
    }

    private func trim() {
        if entries.count > 500 {
            let removedEntries = entries.suffix(entries.count - 500)
            for entry in removedEntries {
                removeBlobFiles(for: entry)
            }
            entries.removeLast(entries.count - 500)
        }
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

        let text = pasteboard.string(forType: .string)
        let rtfData = pasteboard.data(forType: .rtf)
        let htmlData = pasteboard.data(forType: .dittoHTML)
        let imageData = ClipboardMonitor.imageData(from: pasteboard)
        let fileURLs = ClipboardMonitor.fileURLs(from: pasteboard)

        store.addClipboardPayload(
            text: text,
            rtfData: rtfData,
            htmlData: htmlData,
            imageData: imageData,
            fileURLs: fileURLs
        )
        onChange?()
    }

    private static func imageData(from pasteboard: NSPasteboard) -> Data? {
        if let pngData = pasteboard.data(forType: .png) {
            return pngData
        }

        guard
            let tiffData = pasteboard.data(forType: .tiff),
            let bitmap = NSBitmapImageRep(data: tiffData)
        else {
            return nil
        }

        return bitmap.representation(using: .png, properties: [:])
    }

    private static func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true
        ]

        let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: options
        ) as? [NSURL]

        return urls?.map { $0 as URL } ?? []
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
    private let pasteHandler: () -> Void
    private let searchField = NSSearchField()
    private let tableView = NSTableView()
    private var filteredEntries: [ClipboardEntry] = []
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        return formatter
    }()

    init(store: ClipboardStore, pasteHandler: @escaping () -> Void) {
        self.store = store
        self.pasteHandler = pasteHandler

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
                $0.searchableText.range(
                    of: query,
                    options: [.caseInsensitive, .diacriticInsensitive]
                ) != nil
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
        } else if tableColumn?.identifier.rawValue == "type" {
            textField.stringValue = entry.typeLabel
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
        store.copyToPasteboard(entry)
    }

    @objc private func pasteSelectedEntry() {
        copySelectedEntry()
        pasteHandler()
    }

    @objc private func deleteSelectedEntry() {
        let row = tableView.selectedRow
        guard row >= 0, row < filteredEntries.count else {
            return
        }

        store.removeEntry(id: filteredEntries[row].id)
        refresh()
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
        tableView.doubleAction = #selector(pasteSelectedEntry)

        let clipColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("clip"))
        clipColumn.title = "Clip"
        clipColumn.width = 500
        tableView.addTableColumn(clipColumn)

        let typeColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("type"))
        typeColumn.title = "Type"
        typeColumn.width = 80
        tableView.addTableColumn(typeColumn)

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

        let pasteButton = NSButton(
            title: "Paste",
            target: self,
            action: #selector(pasteSelectedEntry)
        )
        pasteButton.bezelStyle = .rounded

        let deleteButton = NSButton(
            title: "Delete",
            target: self,
            action: #selector(deleteSelectedEntry)
        )
        deleteButton.bezelStyle = .rounded

        let clearButton = NSButton(
            title: "Clear",
            target: self,
            action: #selector(clearHistory)
        )
        clearButton.bezelStyle = .rounded

        let toolbar = NSStackView(views: [copyButton, pasteButton, deleteButton, clearButton])
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

final class HotKeyController {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let onPressed: () -> Void

    init(onPressed: @escaping () -> Void) {
        self.onPressed = onPressed
    }

    func register() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else {
                    return noErr
                }

                let controller = Unmanaged<HotKeyController>
                    .fromOpaque(userData)
                    .takeUnretainedValue()
                controller.onPressed()
                return noErr
            },
            1,
            &eventType,
            selfPointer,
            &handlerRef
        )

        let hotKeyID = EventHotKeyID(signature: OSType(0x4469746F), id: 1)
        RegisterEventHotKey(
            UInt32(kVK_ANSI_V),
            UInt32(cmdKey | optionKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }

    deinit {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }

        if let handlerRef {
            RemoveEventHandler(handlerRef)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let store = ClipboardStore()
    private let loginAgentManager = LoginAgentManager()
    private var monitor: ClipboardMonitor?
    private var hotKeyController: HotKeyController?
    private var statusItem: NSStatusItem?
    private var statusMenu: NSMenu?
    private var historyWindowController: HistoryWindowController?
    private var previousApplication: NSRunningApplication?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        ProcessInfo.processInfo.disableAutomaticTermination(
            "Ditto monitors the clipboard from the menu bar."
        )
        loginAgentManager.installOrRefresh()
        registerHotKey()
        configureStatusItem()

        let monitor = ClipboardMonitor(store: store)
        monitor.onChange = { [weak self] in
            self?.historyWindowController?.refresh()
        }
        monitor.start()
        self.monitor = monitor
    }

    private func registerHotKey() {
        let hotKeyController = HotKeyController { [weak self] in
            DispatchQueue.main.async {
                self?.showHistory()
            }
        }
        hotKeyController.register()
        self.hotKeyController = hotKeyController
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    @objc private func showHistory() {
        if historyWindowController == nil {
            historyWindowController = HistoryWindowController(
                store: store,
                pasteHandler: { [weak self] in
                    self?.pasteToPreviousApplication()
                }
            )
        }

        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier != Bundle.main.bundleIdentifier {
            previousApplication = NSWorkspace.shared.frontmostApplication
        }

        historyWindowController?.refresh()
        historyWindowController?.showWindow(nil)
        historyWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func pasteToPreviousApplication() {
        historyWindowController?.window?.orderOut(nil)

        guard let previousApplication else {
            return
        }

        previousApplication.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            let source = CGEventSource(stateID: .combinedSessionState)
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true)
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
            keyDown?.flags = .maskCommand
            keyUp?.flags = .maskCommand
            keyDown?.post(tap: .cghidEventTap)
            keyUp?.post(tap: .cghidEventTap)
        }
    }

    @objc private func quit() {
        loginAgentManager.disable()
        NSApp.terminate(nil)
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "Ditto"

        let menu = NSMenu()
        menu.delegate = self
        statusMenu = menu
        rebuildStatusMenu(menu)
        item.menu = menu
        statusItem = item
    }

    func menuWillOpen(_ menu: NSMenu) {
        rebuildStatusMenu(menu)
    }

    @objc private func copyRecentMenuItem(_ sender: NSMenuItem) {
        guard
            let idString = sender.representedObject as? String,
            let id = UUID(uuidString: idString),
            let entry = store.entry(id: id)
        else {
            return
        }

        store.copyToPasteboard(entry)
    }

    private func rebuildStatusMenu(_ menu: NSMenu) {
        menu.removeAllItems()

        let showHistoryItem = NSMenuItem(
            title: "Show History",
            action: #selector(showHistory),
            keyEquivalent: ""
        )
        showHistoryItem.target = self
        menu.addItem(showHistoryItem)

        let recentEntries = Array(store.entries.prefix(10))
        if recentEntries.isEmpty == false {
            menu.addItem(.separator())
        }

        for entry in recentEntries {
            let item = NSMenuItem(
                title: "[\(entry.typeLabel)] \(entry.preview)",
                action: #selector(copyRecentMenuItem(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = entry.id.uuidString
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit Ditto",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)
    }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
