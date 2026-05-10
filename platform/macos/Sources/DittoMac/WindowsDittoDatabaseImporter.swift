import AppKit
import CSystem
import Foundation

enum WindowsDittoDatabaseImportError: Error {
    case openFailed(String)
    case prepareFailed(String)
    case invalidDatabase
    case inflateFailed
}

final class WindowsDittoDatabaseImporter {
    private struct MainRow {
        let id: Int64
        let createdAt: Date
        let description: String
        let parentID: Int64
        let favorite: Bool
    }

    private struct DataRow {
        let format: String
        let originalSize: Int?
        let data: Data
    }

    private let blobWriter: (Data, String) -> String?

    init(blobWriter: @escaping (Data, String) -> String?) {
        self.blobWriter = blobWriter
    }

    func importEntries(from url: URL) throws -> [ClipboardEntry] {
        let database = try SQLiteDatabase(url: url)
        guard database.hasTable(named: "Main"), database.hasTable(named: "Data") else {
            throw WindowsDittoDatabaseImportError.invalidDatabase
        }

        let hasExportOriginalSize = database.hasColumn(named: "lOriginalSize", in: "Data")
        let hasWindowsMainMetadata = database.hasColumn(named: "lDate", in: "Main") &&
            database.hasColumn(named: "bIsGroup", in: "Main")
        let groups = hasWindowsMainMetadata ? try groupNames(in: database) : [:]
        let rows = hasWindowsMainMetadata ? try mainRows(in: database) : try exportedMainRows(in: database)

        var entries: [ClipboardEntry] = []
        for row in rows {
            let dataRows = try dataRows(for: row.id, in: database, hasExportOriginalSize: hasExportOriginalSize)
            guard dataRows.isEmpty == false else {
                continue
            }

            let payloads = try payloads(from: dataRows, exportedArchive: hasExportOriginalSize)
            let text = payloads.text ?? (row.description.isEmpty ? nil : row.description)

            guard
                text?.isEmpty == false ||
                payloads.rtfData?.isEmpty == false ||
                payloads.htmlData?.isEmpty == false ||
                payloads.imageData?.isEmpty == false ||
                payloads.fileURLs.isEmpty == false
            else {
                continue
            }

            entries.append(
                ClipboardEntry(
                    id: UUID(),
                    text: text,
                    rtfFileName: payloads.rtfData.flatMap { blobWriter($0, "rtf") },
                    htmlFileName: payloads.htmlData.flatMap { blobWriter($0, "html") },
                    imageFileName: payloads.imageData.flatMap { blobWriter($0, "png") },
                    fileURLs: payloads.fileURLs.isEmpty ? nil : payloads.fileURLs,
                    createdAt: row.createdAt,
                    isFavorite: row.favorite ? true : nil,
                    groupName: groups[row.parentID]
                )
            )
        }

        return entries.sorted { $0.createdAt > $1.createdAt }
    }

    private func groupNames(in database: SQLiteDatabase) throws -> [Int64: String] {
        try database.query(
            """
            SELECT lID, mText
            FROM Main
            WHERE bIsGroup = 1
            """
        ) { statement in
            var values: [Int64: String] = [:]
            while sqlite3_step(statement) == SQLITE_ROW {
                let id = sqlite3_column_int64(statement, 0)
                let name = SQLiteDatabase.string(statement, 1)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if name.isEmpty == false {
                    values[id] = name
                }
            }
            return values
        }
    }

    private func mainRows(in database: SQLiteDatabase) throws -> [MainRow] {
        try database.query(
            """
            SELECT lID, lDate, mText, lParentID, lDontAutoDelete, stickyClipOrder, stickyClipGroupOrder
            FROM Main
            WHERE bIsGroup = 0
            ORDER BY COALESCE(clipOrder, lDate) DESC
            """
        ) { statement in
            var rows: [MainRow] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                let dateValue = sqlite3_column_int64(statement, 1)
                let parentID = sqlite3_column_int64(statement, 3)
                let dontAutoDelete = sqlite3_column_int(statement, 4) != 0
                let sticky = Self.isStickyValue(statement, column: 5)
                let stickyGroup = Self.isStickyValue(statement, column: 6)
                rows.append(
                    MainRow(
                        id: sqlite3_column_int64(statement, 0),
                        createdAt: Date(timeIntervalSince1970: TimeInterval(dateValue)),
                        description: SQLiteDatabase.string(statement, 2),
                        parentID: parentID,
                        favorite: dontAutoDelete || sticky || stickyGroup
                    )
                )
            }
            return rows
        }
    }

    private func exportedMainRows(in database: SQLiteDatabase) throws -> [MainRow] {
        let importDate = Date()
        return try database.query(
            """
            SELECT lID, mText
            FROM Main
            ORDER BY lID DESC
            """
        ) { statement in
            var rows: [MainRow] = []
            var offset: TimeInterval = 0
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append(
                    MainRow(
                        id: sqlite3_column_int64(statement, 0),
                        createdAt: importDate.addingTimeInterval(-offset),
                        description: SQLiteDatabase.string(statement, 1),
                        parentID: -1,
                        favorite: false
                    )
                )
                offset += 1
            }
            return rows
        }
    }

    private static func isStickyValue(_ statement: OpaquePointer?, column: Int32) -> Bool {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else {
            return false
        }

        let value = sqlite3_column_double(statement, column)
        return value != 0 && value != -2_147_483_647
    }

    private func dataRows(
        for parentID: Int64,
        in database: SQLiteDatabase,
        hasExportOriginalSize: Bool
    ) throws -> [DataRow] {
        let originalSizeColumn = hasExportOriginalSize ? ", lOriginalSize" : ""
        return try database.query(
            """
            SELECT strClipBoardFormat, ooData\(originalSizeColumn)
            FROM Data
            WHERE lParentID = ?
            ORDER BY lID DESC
            """,
            binds: { statement in
                sqlite3_bind_int64(statement, 1, parentID)
            }
        ) { statement in
            var rows: [DataRow] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let data = SQLiteDatabase.blob(statement, 1), data.isEmpty == false else {
                    continue
                }

                rows.append(
                    DataRow(
                        format: SQLiteDatabase.string(statement, 0),
                        originalSize: hasExportOriginalSize ? Int(sqlite3_column_int(statement, 2)) : nil,
                        data: data
                    )
                )
            }
            return rows
        }
    }

    private func payloads(
        from dataRows: [DataRow],
        exportedArchive: Bool
    ) throws -> (text: String?, rtfData: Data?, htmlData: Data?, imageData: Data?, fileURLs: [String]) {
        var unicodeText: String?
        var text: String?
        var rtfData: Data?
        var htmlData: Data?
        var imageData: Data?
        var fileURLs: [String] = []

        for row in dataRows {
            let data = try decodedData(row, exportedArchive: exportedArchive)
            switch row.format {
            case "CF_UNICODETEXT":
                unicodeText = decodeWindowsUnicodeText(data)
            case "CF_TEXT", "CF_OEMTEXT":
                text = decodeWindowsAnsiText(data)
            case "Rich Text Format", "Rich Text Format Without Objects":
                rtfData = data
            case "HTML Format":
                htmlData = data
            case "PNG":
                imageData = data
            case "CF_DIB":
                imageData = imageData ?? pngDataFromDIB(data)
            case "CF_HDROP":
                fileURLs = decodeHDropFilePaths(data)
            default:
                continue
            }
        }

        return (unicodeText ?? text, rtfData, htmlData, imageData, fileURLs)
    }

    private func decodedData(_ row: DataRow, exportedArchive: Bool) throws -> Data {
        guard exportedArchive, let originalSize = row.originalSize else {
            return row.data
        }

        var output = Data(count: originalSize)
        let result = output.withUnsafeMutableBytes { outputBuffer in
            row.data.withUnsafeBytes { inputBuffer in
                var outputSize = uLongf(originalSize)
                return uncompress(
                    outputBuffer.bindMemory(to: Bytef.self).baseAddress,
                    &outputSize,
                    inputBuffer.bindMemory(to: Bytef.self).baseAddress,
                    uLong(row.data.count)
                )
            }
        }

        guard result == Z_OK else {
            throw WindowsDittoDatabaseImportError.inflateFailed
        }

        return output
    }

    private func decodeWindowsUnicodeText(_ data: Data) -> String? {
        var bytes = data
        while bytes.count >= 2, bytes[bytes.index(before: bytes.endIndex)] == 0, bytes[bytes.index(bytes.endIndex, offsetBy: -2)] == 0 {
            bytes.removeLast(2)
        }
        return String(data: bytes, encoding: .utf16LittleEndian)
    }

    private func decodeWindowsAnsiText(_ data: Data) -> String? {
        var bytes = data
        while bytes.last == 0 {
            bytes.removeLast()
        }

        return String(data: bytes, encoding: .utf8) ??
            String(data: bytes, encoding: .isoLatin1)
    }

    private func decodeHDropFilePaths(_ data: Data) -> [String] {
        guard data.count >= 20 else {
            return []
        }

        let offset = Int(data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian)
        guard offset > 0, offset < data.count else {
            return []
        }

        let isWide = data.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: 16, as: UInt32.self)
        }.littleEndian != 0
        let payload = data.dropFirst(offset)

        if isWide {
            return decodeDoubleNullTerminatedUTF16(payload)
        }

        return decodeDoubleNullTerminatedAnsi(payload)
    }

    private func decodeDoubleNullTerminatedUTF16(_ payload: Data.SubSequence) -> [String] {
        var paths: [String] = []
        var current = Data()
        var iterator = payload.makeIterator()

        while let first = iterator.next(), let second = iterator.next() {
            if first == 0, second == 0 {
                if current.isEmpty {
                    break
                }
                if let path = String(data: current, encoding: .utf16LittleEndian), path.isEmpty == false {
                    paths.append(path)
                }
                current.removeAll(keepingCapacity: true)
            } else {
                current.append(first)
                current.append(second)
            }
        }

        return paths
    }

    private func decodeDoubleNullTerminatedAnsi(_ payload: Data.SubSequence) -> [String] {
        var paths: [String] = []
        var current = Data()

        for byte in payload {
            if byte == 0 {
                if current.isEmpty {
                    break
                }
                if let path = decodeWindowsAnsiText(current), path.isEmpty == false {
                    paths.append(path)
                }
                current.removeAll(keepingCapacity: true)
            } else {
                current.append(byte)
            }
        }

        return paths
    }

    private func pngDataFromDIB(_ dibData: Data) -> Data? {
        guard dibData.count >= 40 else {
            return nil
        }

        let headerSize = Int(dibData.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian)
        guard headerSize > 0, dibData.count >= headerSize else {
            return nil
        }

        let bitCount = dibData.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: 14, as: UInt16.self)
        }.littleEndian
        let colorsUsed = dibData.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: 32, as: UInt32.self)
        }.littleEndian
        let colorTableEntries = colorsUsed == 0 && bitCount <= 8 ? (1 << Int(bitCount)) : Int(colorsUsed)
        let pixelOffset = 14 + headerSize + colorTableEntries * 4
        let fileSize = 14 + dibData.count

        var bmp = Data()
        bmp.append(contentsOf: [0x42, 0x4D])
        bmp.append(littleEndianUInt32(UInt32(fileSize)))
        bmp.append(littleEndianUInt16(0))
        bmp.append(littleEndianUInt16(0))
        bmp.append(littleEndianUInt32(UInt32(pixelOffset)))
        bmp.append(dibData)

        guard
            let representation = NSBitmapImageRep(data: bmp),
            let png = representation.representation(using: .png, properties: [:])
        else {
            return nil
        }

        return png
    }

    private func littleEndianUInt16(_ value: UInt16) -> Data {
        var littleEndian = value.littleEndian
        return Data(bytes: &littleEndian, count: MemoryLayout<UInt16>.size)
    }

    private func littleEndianUInt32(_ value: UInt32) -> Data {
        var littleEndian = value.littleEndian
        return Data(bytes: &littleEndian, count: MemoryLayout<UInt32>.size)
    }
}

private final class SQLiteDatabase {
    private var database: OpaquePointer?

    init(url: URL) throws {
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
        let result = sqlite3_open_v2(url.path, &database, flags, nil)
        guard result == SQLITE_OK else {
            let message = database.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? url.path
            throw WindowsDittoDatabaseImportError.openFailed(message)
        }
    }

    deinit {
        sqlite3_close(database)
    }

    func hasTable(named table: String) -> Bool {
        (try? query(
            """
            SELECT 1
            FROM sqlite_master
            WHERE type = 'table' AND name = ?
            LIMIT 1
            """,
            binds: { statement in
                sqlite3_bind_text(statement, 1, table, -1, transientDestructor)
            }
        ) { statement in
            sqlite3_step(statement) == SQLITE_ROW
        }) ?? false
    }

    func hasColumn(named column: String, in table: String) -> Bool {
        (try? query("PRAGMA table_info(\(quotedIdentifier(table)))") { statement in
            while sqlite3_step(statement) == SQLITE_ROW {
                if Self.string(statement, 1).caseInsensitiveCompare(column) == .orderedSame {
                    return true
                }
            }
            return false
        }) ?? false
    }

    func query<T>(
        _ sql: String,
        binds: ((OpaquePointer?) -> Void)? = nil,
        body: (OpaquePointer?) throws -> T
    ) throws -> T {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            let message = database.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? sql
            throw WindowsDittoDatabaseImportError.prepareFailed(message)
        }

        defer {
            sqlite3_finalize(statement)
        }

        binds?(statement)
        return try body(statement)
    }

    static func string(_ statement: OpaquePointer?, _ column: Int32) -> String {
        guard let value = sqlite3_column_text(statement, column) else {
            return ""
        }
        return String(cString: value)
    }

    static func blob(_ statement: OpaquePointer?, _ column: Int32) -> Data? {
        guard let bytes = sqlite3_column_blob(statement, column) else {
            return nil
        }

        let count = Int(sqlite3_column_bytes(statement, column))
        return Data(bytes: bytes, count: count)
    }

    private func quotedIdentifier(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}

private let transientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
