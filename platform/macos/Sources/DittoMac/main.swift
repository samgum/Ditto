import AppKit
import Carbon
import CoreGraphics
import Darwin
import UniformTypeIdentifiers

extension NSPasteboard.PasteboardType {
    static let dittoHTML = NSPasteboard.PasteboardType("public.html")
}

final class LocalizationManager {
    static let shared = LocalizationManager()

    private let languageKey = "Ditto.Language"
    private var strings: [String: String] = [:]

    var currentLanguage: String {
        UserDefaults.standard.string(forKey: languageKey) ?? "en"
    }

    let languages: [(code: String, name: String)] = [
        ("en", "English"),
        ("zh-Hans", "简体中文"),
        ("zh-Hant", "繁體中文")
    ]

    private init() {
        loadLanguage(currentLanguage)
    }

    func setLanguage(_ code: String) {
        UserDefaults.standard.set(code, forKey: languageKey)
        loadLanguage(code)
    }

    func text(_ key: String) -> String {
        strings[key] ?? Self.fallbackStrings[key] ?? key
    }

    private func loadLanguage(_ code: String) {
        guard
            let resourceURL = Bundle.main.resourceURL?
                .appendingPathComponent("Localizations", isDirectory: true)
                .appendingPathComponent("\(code).json"),
            let data = try? Data(contentsOf: resourceURL),
            let decoded = try? JSONDecoder().decode([String: String].self, from: data)
        else {
            strings = Self.fallbackStrings
            return
        }

        strings = decoded
    }

    private static let fallbackStrings: [String: String] = [
        "app_name": "Ditto",
        "show_history": "Show History",
        "preferences": "Preferences...",
        "import_history": "Import History...",
        "import_windows_database": "Import Windows Ditto Database...",
        "export_history": "Export History...",
        "quit": "Quit Ditto",
        "search": "Search",
        "clip": "Clip",
        "type": "Type",
        "date": "Date",
        "copy": "Copy",
        "paste": "Paste",
        "delete": "Delete",
        "favorite": "Favorite",
        "favorites": "Favorites",
        "group": "Group",
        "all_groups": "All",
        "ungrouped": "Ungrouped",
        "set_group": "Set Group...",
        "group_name": "Group name",
        "clear": "Clear",
        "language": "Language",
        "hot_key": "Hot Key",
        "close": "Close",
        "disabled": "Disabled",
        "import_success": "History imported.",
        "import_windows_success": "Windows Ditto database imported.",
        "export_success": "History exported.",
        "operation_failed": "Operation failed."
    ]
}

enum HotKeyChoice: String, CaseIterable {
    case optionCommandV
    case controlOptionV
    case commandShiftV
    case disabled

    static let defaultsKey = "Ditto.HotKey"

    static var current: HotKeyChoice {
        get {
            guard
                let value = UserDefaults.standard.string(forKey: defaultsKey),
                let choice = HotKeyChoice(rawValue: value)
            else {
                return .optionCommandV
            }

            return choice
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey)
        }
    }

    var title: String {
        switch self {
        case .optionCommandV:
            return "Option+Command+V"
        case .controlOptionV:
            return "Control+Option+V"
        case .commandShiftV:
            return "Command+Shift+V"
        case .disabled:
            return LocalizationManager.shared.text("disabled")
        }
    }

    var keyCode: UInt32? {
        switch self {
        case .optionCommandV, .controlOptionV, .commandShiftV:
            return UInt32(kVK_ANSI_V)
        case .disabled:
            return nil
        }
    }

    var modifiers: UInt32 {
        switch self {
        case .optionCommandV:
            return UInt32(optionKey | cmdKey)
        case .controlOptionV:
            return UInt32(controlKey | optionKey)
        case .commandShiftV:
            return UInt32(cmdKey | shiftKey)
        case .disabled:
            return 0
        }
    }
}

struct ClipboardEntry: Codable, Equatable {
    let id: UUID
    let text: String?
    let rtfFileName: String?
    let htmlFileName: String?
    let imageFileName: String?
    let fileURLs: [String]?
    let createdAt: Date
    var isFavorite: Bool?
    var groupName: String?

    var favorite: Bool {
        isFavorite ?? false
    }

    var displayGroup: String? {
        guard let groupName = groupName?.trimmingCharacters(in: .whitespacesAndNewlines), groupName.isEmpty == false else {
            return nil
        }

        return groupName
    }

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

        if let displayGroup {
            values.append(displayGroup)
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
    private struct ClipboardArchive: Codable {
        let version: Int
        let entries: [ArchiveEntry]
    }

    private struct ArchiveEntry: Codable {
        let id: UUID
        let text: String?
        let rtfBase64: String?
        let htmlBase64: String?
        let imageBase64: String?
        let fileURLs: [String]?
        let createdAt: Date
        let isFavorite: Bool?
        let groupName: String?
    }

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
                createdAt: Date(),
                isFavorite: nil,
                groupName: nil
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

    func toggleFavorite(id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else {
            return
        }

        entries[index].isFavorite = !(entries[index].isFavorite ?? false)
        save()
    }

    func setGroup(id: UUID, groupName: String?) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else {
            return
        }

        let normalized = groupName?.trimmingCharacters(in: .whitespacesAndNewlines)
        entries[index].groupName = normalized?.isEmpty == false ? normalized : nil
        save()
    }

    var groupNames: [String] {
        Array(Set(entries.compactMap(\.displayGroup))).sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    func exportArchive(to url: URL) throws {
        let archive = ClipboardArchive(
            version: 1,
            entries: entries.map { entry in
                ArchiveEntry(
                    id: entry.id,
                    text: entry.text,
                    rtfBase64: entry.rtfFileName.flatMap { blobData(named: $0)?.base64EncodedString() },
                    htmlBase64: entry.htmlFileName.flatMap { blobData(named: $0)?.base64EncodedString() },
                    imageBase64: entry.imageFileName.flatMap { _ in imageData(for: entry)?.base64EncodedString() },
                    fileURLs: entry.fileURLs,
                    createdAt: entry.createdAt,
                    isFavorite: entry.isFavorite,
                    groupName: entry.groupName
                )
            }
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(archive)
        try data.write(to: url, options: Data.WritingOptions.atomic)
    }

    func importArchive(from url: URL) throws {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let archive = try decoder.decode(ClipboardArchive.self, from: data)

        var importedEntries: [ClipboardEntry] = []
        for archiveEntry in archive.entries {
            let rtfFileName = archiveEntry.rtfBase64
                .flatMap { Data(base64Encoded: $0) }
                .flatMap { saveBlob($0, fileExtension: "rtf") }
            let htmlFileName = archiveEntry.htmlBase64
                .flatMap { Data(base64Encoded: $0) }
                .flatMap { saveBlob($0, fileExtension: "html") }
            let imageFileName = archiveEntry.imageBase64
                .flatMap { Data(base64Encoded: $0) }
                .flatMap { saveBlob($0, fileExtension: "png") }

            importedEntries.append(
                ClipboardEntry(
                    id: archiveEntry.id,
                    text: archiveEntry.text,
                    rtfFileName: rtfFileName,
                    htmlFileName: htmlFileName,
                    imageFileName: imageFileName,
                    fileURLs: archiveEntry.fileURLs,
                    createdAt: archiveEntry.createdAt,
                    isFavorite: archiveEntry.isFavorite,
                    groupName: archiveEntry.groupName
                )
            )
        }

        let importedIDs = Set(importedEntries.map(\.id))
        removeEntries { importedIDs.contains($0.id) }
        entries = (importedEntries + entries).sorted { $0.createdAt > $1.createdAt }
        trim()
        save()
    }

    @discardableResult
    func importWindowsDittoDatabase(from url: URL) throws -> Int {
        let importer = WindowsDittoDatabaseImporter { [weak self] data, fileExtension in
            self?.saveBlob(data, fileExtension: fileExtension)
        }
        let importedEntries = try importer.importEntries(from: url)
        mergeImportedEntries(importedEntries)
        return importedEntries.count
    }

    private func mergeImportedEntries(_ importedEntries: [ClipboardEntry]) {
        let importedKeys = Set(importedEntries.map(importKey(for:)))
        removeEntries { importedKeys.contains(importKey(for: $0)) }
        entries = (importedEntries + entries).sorted { $0.createdAt > $1.createdAt }
        trim()
        save()
    }

    private func importKey(for entry: ClipboardEntry) -> String {
        [
            "\(Int(entry.createdAt.timeIntervalSince1970))",
            entry.text ?? "",
            entry.rtfFileName == nil ? "" : "rtf",
            entry.htmlFileName == nil ? "" : "html",
            entry.imageFileName == nil ? "" : "image",
            entry.fileURLs?.joined(separator: "\u{1f}") ?? "",
            entry.groupName ?? ""
        ].joined(separator: "\u{1e}")
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
    private enum GroupFilter: Equatable {
        case all
        case favorites
        case ungrouped
        case group(String)
    }

    private let store: ClipboardStore
    private let pasteHandler: () -> Void
    private let searchField = NSSearchField()
    private let groupFilterPopup = NSPopUpButton()
    private let tableView = NSTableView()
    private let copyButton = NSButton(title: "", target: nil, action: nil)
    private let pasteButton = NSButton(title: "", target: nil, action: nil)
    private let favoriteButton = NSButton(title: "", target: nil, action: nil)
    private let groupButton = NSButton(title: "", target: nil, action: nil)
    private let deleteButton = NSButton(title: "", target: nil, action: nil)
    private let clearButton = NSButton(title: "", target: nil, action: nil)
    private var filteredEntries: [ClipboardEntry] = []
    private var currentGroupFilter: GroupFilter = .all
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
        window.title = LocalizationManager.shared.text("app_name")
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

    func refreshText() {
        window?.title = LocalizationManager.shared.text("app_name")
        searchField.placeholderString = LocalizationManager.shared.text("search")
        rebuildGroupFilterPopup()
        tableView.tableColumns.first { $0.identifier.rawValue == "clip" }?.title =
            LocalizationManager.shared.text("clip")
        tableView.tableColumns.first { $0.identifier.rawValue == "type" }?.title =
            LocalizationManager.shared.text("type")
        tableView.tableColumns.first { $0.identifier.rawValue == "favorite" }?.title =
            LocalizationManager.shared.text("favorite")
        tableView.tableColumns.first { $0.identifier.rawValue == "group" }?.title =
            LocalizationManager.shared.text("group")
        tableView.tableColumns.first { $0.identifier.rawValue == "date" }?.title =
            LocalizationManager.shared.text("date")
        copyButton.title = LocalizationManager.shared.text("copy")
        pasteButton.title = LocalizationManager.shared.text("paste")
        favoriteButton.title = LocalizationManager.shared.text("favorite")
        groupButton.title = LocalizationManager.shared.text("set_group")
        deleteButton.title = LocalizationManager.shared.text("delete")
        clearButton.title = LocalizationManager.shared.text("clear")
        tableView.reloadData()
    }

    private func applySearch() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        filteredEntries = store.entries.filter { entry in
            let matchesGroup: Bool
            switch currentGroupFilter {
            case .all:
                matchesGroup = true
            case .favorites:
                matchesGroup = entry.favorite
            case .ungrouped:
                matchesGroup = entry.displayGroup == nil
            case .group(let group):
                matchesGroup = entry.displayGroup == group
            }

            let matchesSearch = query.isEmpty || entry.searchableText.range(
                of: query,
                options: [.caseInsensitive, .diacriticInsensitive]
            ) != nil

            return matchesGroup && matchesSearch
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
        } else if tableColumn?.identifier.rawValue == "favorite" {
            textField.stringValue = entry.favorite ? "★" : ""
        } else if tableColumn?.identifier.rawValue == "group" {
            textField.stringValue = entry.displayGroup ?? ""
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

    @objc private func toggleFavoriteSelectedEntry() {
        let row = tableView.selectedRow
        guard row >= 0, row < filteredEntries.count else {
            return
        }

        store.toggleFavorite(id: filteredEntries[row].id)
        refresh()
    }

    @objc private func setGroupForSelectedEntry() {
        let row = tableView.selectedRow
        guard row >= 0, row < filteredEntries.count else {
            return
        }

        let entry = filteredEntries[row]
        let alert = NSAlert()
        alert.messageText = LocalizationManager.shared.text("set_group")
        alert.informativeText = LocalizationManager.shared.text("group_name")
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: LocalizationManager.shared.text("clear"))

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        input.stringValue = entry.displayGroup ?? ""
        alert.accessoryView = input

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            store.setGroup(id: entry.id, groupName: input.stringValue)
        } else {
            store.setGroup(id: entry.id, groupName: nil)
        }

        rebuildGroupFilterPopup()
        refresh()
    }

    @objc private func searchChanged() {
        applySearch()
    }

    @objc private func groupFilterChanged() {
        let index = groupFilterPopup.indexOfSelectedItem
        switch index {
        case 0:
            currentGroupFilter = .all
        case 1:
            currentGroupFilter = .favorites
        case 2:
            currentGroupFilter = .ungrouped
        default:
            let groupIndex = index - 3
            let groups = store.groupNames
            if groupIndex >= 0, groupIndex < groups.count {
                currentGroupFilter = .group(groups[groupIndex])
            } else {
                currentGroupFilter = .all
            }
        }
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

        searchField.placeholderString = LocalizationManager.shared.text("search")
        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchField.sendsSearchStringImmediately = true
        searchField.translatesAutoresizingMaskIntoConstraints = false

        groupFilterPopup.target = self
        groupFilterPopup.action = #selector(groupFilterChanged)
        groupFilterPopup.translatesAutoresizingMaskIntoConstraints = false
        rebuildGroupFilterPopup()

        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowHeight = 30
        tableView.headerView = nil
        tableView.delegate = self
        tableView.dataSource = self
        tableView.target = self
        tableView.doubleAction = #selector(pasteSelectedEntry)

        let clipColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("clip"))
        clipColumn.title = LocalizationManager.shared.text("clip")
        clipColumn.width = 500
        tableView.addTableColumn(clipColumn)

        let typeColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("type"))
        typeColumn.title = LocalizationManager.shared.text("type")
        typeColumn.width = 80
        tableView.addTableColumn(typeColumn)

        let favoriteColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("favorite"))
        favoriteColumn.title = LocalizationManager.shared.text("favorite")
        favoriteColumn.width = 70
        tableView.addTableColumn(favoriteColumn)

        let groupColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("group"))
        groupColumn.title = LocalizationManager.shared.text("group")
        groupColumn.width = 120
        tableView.addTableColumn(groupColumn)

        let dateColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("date"))
        dateColumn.title = LocalizationManager.shared.text("date")
        dateColumn.width = 180
        tableView.addTableColumn(dateColumn)

        scrollView.documentView = tableView

        copyButton.title = LocalizationManager.shared.text("copy")
        copyButton.target = self
        copyButton.action = #selector(copySelectedEntry)
        copyButton.bezelStyle = .rounded

        pasteButton.title = LocalizationManager.shared.text("paste")
        pasteButton.target = self
        pasteButton.action = #selector(pasteSelectedEntry)
        pasteButton.bezelStyle = .rounded

        favoriteButton.title = LocalizationManager.shared.text("favorite")
        favoriteButton.target = self
        favoriteButton.action = #selector(toggleFavoriteSelectedEntry)
        favoriteButton.bezelStyle = .rounded

        groupButton.title = LocalizationManager.shared.text("set_group")
        groupButton.target = self
        groupButton.action = #selector(setGroupForSelectedEntry)
        groupButton.bezelStyle = .rounded

        deleteButton.title = LocalizationManager.shared.text("delete")
        deleteButton.target = self
        deleteButton.action = #selector(deleteSelectedEntry)
        deleteButton.bezelStyle = .rounded

        clearButton.title = LocalizationManager.shared.text("clear")
        clearButton.target = self
        clearButton.action = #selector(clearHistory)
        clearButton.bezelStyle = .rounded

        let toolbar = NSStackView(views: [copyButton, pasteButton, favoriteButton, groupButton, deleteButton, clearButton])
        toolbar.orientation = .horizontal
        toolbar.spacing = 8
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        root.addSubview(searchField)
        root.addSubview(groupFilterPopup)
        root.addSubview(scrollView)
        root.addSubview(toolbar)
        window.contentView = root

        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            searchField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            searchField.trailingAnchor.constraint(equalTo: groupFilterPopup.leadingAnchor, constant: -8),

            groupFilterPopup.topAnchor.constraint(equalTo: searchField.topAnchor),
            groupFilterPopup.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            groupFilterPopup.widthAnchor.constraint(equalToConstant: 170),

            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            toolbar.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -12),
            toolbar.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),

            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: toolbar.topAnchor, constant: -12)
        ])
    }

    private func rebuildGroupFilterPopup() {
        let selected = currentGroupFilter
        groupFilterPopup.removeAllItems()
        groupFilterPopup.addItem(withTitle: LocalizationManager.shared.text("all_groups"))
        groupFilterPopup.addItem(withTitle: LocalizationManager.shared.text("favorites"))
        groupFilterPopup.addItem(withTitle: LocalizationManager.shared.text("ungrouped"))

        let groups = store.groupNames
        for group in groups {
            groupFilterPopup.addItem(withTitle: group)
        }

        currentGroupFilter = selected
        switch selected {
        case .all:
            groupFilterPopup.selectItem(at: 0)
        case .favorites:
            groupFilterPopup.selectItem(at: 1)
        case .ungrouped:
            groupFilterPopup.selectItem(at: 2)
        case .group(let group):
            if let index = groups.firstIndex(of: group) {
                groupFilterPopup.selectItem(at: index + 3)
            } else {
                currentGroupFilter = .all
                groupFilterPopup.selectItem(at: 0)
            }
        }
    }
}

final class PreferencesWindowController: NSWindowController {
    private let languageLabel = NSTextField(labelWithString: "")
    private let hotKeyLabel = NSTextField(labelWithString: "")
    private let languagePopup = NSPopUpButton()
    private let hotKeyPopup = NSPopUpButton()
    private let closeButton = NSButton(title: "", target: nil, action: nil)
    private let onChanged: () -> Void

    init(onChanged: @escaping () -> Void) {
        self.onChanged = onChanged

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 170),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = LocalizationManager.shared.text("preferences")
        window.center()

        super.init(window: window)
        configureContent()
    }

    required init?(coder: NSCoder) {
        nil
    }

    func refreshText() {
        window?.title = LocalizationManager.shared.text("preferences")
        languageLabel.stringValue = LocalizationManager.shared.text("language")
        hotKeyLabel.stringValue = LocalizationManager.shared.text("hot_key")
        closeButton.title = LocalizationManager.shared.text("close")
        configurePopupTitles()
    }

    @objc private func languageChanged() {
        let selected = LocalizationManager.shared.languages[languagePopup.indexOfSelectedItem]
        LocalizationManager.shared.setLanguage(selected.code)
        refreshText()
        onChanged()
    }

    @objc private func hotKeyChanged() {
        HotKeyChoice.current = HotKeyChoice.allCases[hotKeyPopup.indexOfSelectedItem]
        onChanged()
    }

    @objc private func closeWindow() {
        close()
    }

    private func configureContent() {
        guard let window else {
            return
        }

        refreshText()

        languagePopup.target = self
        languagePopup.action = #selector(languageChanged)
        hotKeyPopup.target = self
        hotKeyPopup.action = #selector(hotKeyChanged)
        closeButton.target = self
        closeButton.action = #selector(closeWindow)
        closeButton.bezelStyle = .rounded

        let grid = NSGridView(views: [
            [languageLabel, languagePopup],
            [hotKeyLabel, hotKeyPopup]
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .fill
        grid.rowSpacing = 12
        grid.columnSpacing = 12
        grid.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        root.addSubview(grid)
        root.addSubview(closeButton)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = root

        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: root.topAnchor, constant: 24),
            grid.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            grid.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),

            closeButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            closeButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18)
        ])
    }

    private func configurePopupTitles() {
        languagePopup.removeAllItems()
        for language in LocalizationManager.shared.languages {
            languagePopup.addItem(withTitle: language.name)
        }
        if let index = LocalizationManager.shared.languages.firstIndex(where: { $0.code == LocalizationManager.shared.currentLanguage }) {
            languagePopup.selectItem(at: index)
        }

        hotKeyPopup.removeAllItems()
        for choice in HotKeyChoice.allCases {
            hotKeyPopup.addItem(withTitle: choice.title)
        }
        if let index = HotKeyChoice.allCases.firstIndex(of: HotKeyChoice.current) {
            hotKeyPopup.selectItem(at: index)
        }
    }
}

final class HotKeyController {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let onPressed: () -> Void

    init(onPressed: @escaping () -> Void) {
        self.onPressed = onPressed
    }

    func register(choice: HotKeyChoice) {
        unregisterHotKey()

        guard let keyCode = choice.keyCode else {
            return
        }

        if handlerRef == nil {
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
        }

        let hotKeyID = EventHotKeyID(signature: OSType(0x4469746F), id: 1)
        RegisterEventHotKey(
            keyCode,
            choice.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }

    deinit {
        unregisterHotKey()

        if let handlerRef {
            RemoveEventHandler(handlerRef)
        }
    }

    private func unregisterHotKey() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
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
    private var preferencesWindowController: PreferencesWindowController?
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
        hotKeyController.register(choice: HotKeyChoice.current)
        self.hotKeyController = hotKeyController
    }

    private func reloadHotKey() {
        hotKeyController?.register(choice: HotKeyChoice.current)
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

    @objc private func showPreferences() {
        if preferencesWindowController == nil {
            preferencesWindowController = PreferencesWindowController { [weak self] in
                self?.reloadHotKey()
                self?.refreshLocalizedText()
            }
        }

        preferencesWindowController?.refreshText()
        preferencesWindowController?.showWindow(nil)
        preferencesWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func exportHistory() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Ditto-History.json"

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else {
                return
            }

            do {
                try self?.store.exportArchive(to: url)
                self?.showAlert(message: LocalizationManager.shared.text("export_success"))
            } catch {
                self?.showAlert(message: LocalizationManager.shared.text("operation_failed"))
            }
        }
    }

    @objc private func importHistory() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else {
                return
            }

            do {
                try self?.store.importArchive(from: url)
                self?.historyWindowController?.refresh()
                self?.showAlert(message: LocalizationManager.shared.text("import_success"))
            } catch {
                self?.showAlert(message: LocalizationManager.shared.text("operation_failed"))
            }
        }
    }

    @objc private func importWindowsDatabase() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "db") ?? .data]
        panel.allowsMultipleSelection = false

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else {
                return
            }

            do {
                try self?.store.importWindowsDittoDatabase(from: url)
                self?.historyWindowController?.refresh()
                self?.showAlert(message: LocalizationManager.shared.text("import_windows_success"))
            } catch {
                self?.showAlert(message: LocalizationManager.shared.text("operation_failed"))
            }
        }
    }

    private func showAlert(message: String) {
        let alert = NSAlert()
        alert.messageText = LocalizationManager.shared.text("app_name")
        alert.informativeText = message
        alert.runModal()
    }

    private func refreshLocalizedText() {
        historyWindowController?.refreshText()
        preferencesWindowController?.refreshText()
        if let statusMenu {
            rebuildStatusMenu(statusMenu)
        }
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
        item.button?.title = LocalizationManager.shared.text("app_name")

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
            title: LocalizationManager.shared.text("show_history"),
            action: #selector(showHistory),
            keyEquivalent: ""
        )
        showHistoryItem.target = self
        menu.addItem(showHistoryItem)

        let preferencesItem = NSMenuItem(
            title: LocalizationManager.shared.text("preferences"),
            action: #selector(showPreferences),
            keyEquivalent: ","
        )
        preferencesItem.target = self
        menu.addItem(preferencesItem)

        menu.addItem(.separator())

        let importItem = NSMenuItem(
            title: LocalizationManager.shared.text("import_history"),
            action: #selector(importHistory),
            keyEquivalent: ""
        )
        importItem.target = self
        menu.addItem(importItem)

        let importWindowsDatabaseItem = NSMenuItem(
            title: LocalizationManager.shared.text("import_windows_database"),
            action: #selector(importWindowsDatabase),
            keyEquivalent: ""
        )
        importWindowsDatabaseItem.target = self
        menu.addItem(importWindowsDatabaseItem)

        let exportItem = NSMenuItem(
            title: LocalizationManager.shared.text("export_history"),
            action: #selector(exportHistory),
            keyEquivalent: ""
        )
        exportItem.target = self
        menu.addItem(exportItem)

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
            title: LocalizationManager.shared.text("quit"),
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
