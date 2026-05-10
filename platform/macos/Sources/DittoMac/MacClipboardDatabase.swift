import CSystem
import Foundation

enum MacClipboardDatabaseError: Error {
    case openFailed(String)
    case prepareFailed(String)
    case executeFailed(String)
}

final class MacClipboardDatabase {
    private var database: OpaquePointer?

    init(url: URL, useWAL: Bool = true, readOnly: Bool = false) throws {
        if readOnly == false {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        }

        let flags = readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE)
        guard sqlite3_open_v2(url.path, &database, flags, nil) == SQLITE_OK else {
            let message = database.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? url.path
            throw MacClipboardDatabaseError.openFailed(message)
        }

        try execute("PRAGMA foreign_keys = ON")
        if readOnly == false {
            try execute(useWAL ? "PRAGMA journal_mode = WAL" : "PRAGMA journal_mode = DELETE")
            try createSchema()
        }
    }

    deinit {
        sqlite3_close(database)
    }

    func loadEntries() throws -> [ClipboardEntry] {
        try query(
            """
            SELECT id, text, rtfBlobKey, htmlBlobKey, imageBlobKey, fileURLsJson, createdAt, isFavorite, groupName
            FROM ClipboardEntries
            ORDER BY createdAt DESC
            """
        ) { statement in
            var entries: [ClipboardEntry] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let id = UUID(uuidString: Self.string(statement, 0)) else {
                    continue
                }

                let fileURLsJson = Self.optionalString(statement, 5)
                let fileURLs = fileURLsJson
                    .flatMap { $0.data(using: .utf8) }
                    .flatMap { try? JSONDecoder().decode([String].self, from: $0) }

                entries.append(
                    ClipboardEntry(
                        id: id,
                        text: Self.optionalString(statement, 1),
                        rtfFileName: Self.optionalString(statement, 2),
                        htmlFileName: Self.optionalString(statement, 3),
                        imageFileName: Self.optionalString(statement, 4),
                        fileURLs: fileURLs,
                        createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6)),
                        isFavorite: sqlite3_column_type(statement, 7) == SQLITE_NULL ? nil : sqlite3_column_int(statement, 7) != 0,
                        groupName: Self.optionalString(statement, 8)
                    )
                )
            }
            return entries
        }
    }

    func replaceEntries(_ entries: [ClipboardEntry]) throws {
        try transaction {
            try execute("DELETE FROM ClipboardEntries")
            for entry in entries {
                let fileURLsJson = entry.fileURLs
                    .flatMap { try? JSONEncoder().encode($0) }
                    .flatMap { String(data: $0, encoding: .utf8) }

                try execute(
                    """
                    INSERT INTO ClipboardEntries(
                        id, text, rtfBlobKey, htmlBlobKey, imageBlobKey, fileURLsJson,
                        createdAt, isFavorite, groupName
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    binds: { statement in
                        sqlite3_bind_text(statement, 1, entry.id.uuidString, -1, databaseTransientDestructor)
                        self.bindOptionalText(statement, 2, entry.text)
                        self.bindOptionalText(statement, 3, entry.rtfFileName)
                        self.bindOptionalText(statement, 4, entry.htmlFileName)
                        self.bindOptionalText(statement, 5, entry.imageFileName)
                        self.bindOptionalText(statement, 6, fileURLsJson)
                        sqlite3_bind_double(statement, 7, entry.createdAt.timeIntervalSince1970)
                        if let isFavorite = entry.isFavorite {
                            sqlite3_bind_int(statement, 8, isFavorite ? 1 : 0)
                        } else {
                            sqlite3_bind_null(statement, 8)
                        }
                        self.bindOptionalText(statement, 9, entry.groupName)
                    }
                )
            }
        }
    }

    func saveBlob(_ data: Data, key: String = UUID().uuidString, fileExtension: String) throws -> String {
        try execute(
            """
            INSERT OR REPLACE INTO ClipBlobs(blobKey, fileExtension, data)
            VALUES (?, ?, ?)
            """,
            binds: { statement in
                sqlite3_bind_text(statement, 1, key, -1, databaseTransientDestructor)
                sqlite3_bind_text(statement, 2, fileExtension, -1, databaseTransientDestructor)
                _ = data.withUnsafeBytes { buffer in
                    sqlite3_bind_blob(statement, 3, buffer.baseAddress, Int32(data.count), databaseTransientDestructor)
                }
            }
        )
        return key
    }

    func blobData(key: String) -> Data? {
        try? query(
            "SELECT data FROM ClipBlobs WHERE blobKey = ?",
            binds: { statement in
                sqlite3_bind_text(statement, 1, key, -1, databaseTransientDestructor)
            }
        ) { statement in
            guard sqlite3_step(statement) == SQLITE_ROW else {
                return nil
            }
            return Self.blob(statement, 0)
        }
    }

    func removeBlobs(keys: [String]) {
        for key in keys {
            try? execute(
                "DELETE FROM ClipBlobs WHERE blobKey = ?",
                binds: { statement in
                    sqlite3_bind_text(statement, 1, key, -1, databaseTransientDestructor)
                }
            )
        }
    }

    func removeAll() throws {
        try transaction {
            try execute("DELETE FROM ClipboardEntries")
            try execute("DELETE FROM ClipBlobs")
        }
    }

    func exportArchive(entries: [ClipboardEntry], to url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }

        let archiveDatabase = try MacClipboardDatabase(url: url, useWAL: false)
        for entry in entries {
            for key in [entry.rtfFileName, entry.htmlFileName, entry.imageFileName].compactMap({ $0 }) {
                guard let data = blobData(key: key) else {
                    continue
                }
                _ = try archiveDatabase.saveBlob(data, key: key, fileExtension: URL(fileURLWithPath: key).pathExtension)
            }
        }
        try archiveDatabase.replaceEntries(entries)
    }

    private func createSchema() throws {
        try execute(
            """
            CREATE TABLE IF NOT EXISTS ClipboardEntries(
                id TEXT PRIMARY KEY,
                text TEXT,
                rtfBlobKey TEXT,
                htmlBlobKey TEXT,
                imageBlobKey TEXT,
                fileURLsJson TEXT,
                createdAt REAL NOT NULL,
                isFavorite INTEGER,
                groupName TEXT
            )
            """
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS ClipBlobs(
                blobKey TEXT PRIMARY KEY,
                fileExtension TEXT NOT NULL,
                data BLOB NOT NULL
            )
            """
        )
        try execute("CREATE INDEX IF NOT EXISTS ClipboardEntries_createdAt ON ClipboardEntries(createdAt DESC)")
        try execute("CREATE INDEX IF NOT EXISTS ClipboardEntries_groupName ON ClipboardEntries(groupName)")
    }

    private func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func execute(_ sql: String, binds: ((OpaquePointer?) -> Void)? = nil) throws {
        try query(sql, binds: binds) { statement in
            let result = sqlite3_step(statement)
            guard result == SQLITE_DONE || result == SQLITE_ROW else {
                let message = database.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? sql
                throw MacClipboardDatabaseError.executeFailed(message)
            }
        }
    }

    private func query<T>(
        _ sql: String,
        binds: ((OpaquePointer?) -> Void)? = nil,
        body: (OpaquePointer?) throws -> T
    ) throws -> T {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            let message = database.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? sql
            throw MacClipboardDatabaseError.prepareFailed(message)
        }

        defer {
            sqlite3_finalize(statement)
        }

        binds?(statement)
        return try body(statement)
    }

    private func bindOptionalText(_ statement: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let value {
            sqlite3_bind_text(statement, index, value, -1, databaseTransientDestructor)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private static func optionalString(_ statement: OpaquePointer?, _ column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else {
            return nil
        }
        return string(statement, column)
    }

    private static func string(_ statement: OpaquePointer?, _ column: Int32) -> String {
        guard let value = sqlite3_column_text(statement, column) else {
            return ""
        }
        return String(cString: value)
    }

    private static func blob(_ statement: OpaquePointer?, _ column: Int32) -> Data? {
        guard let bytes = sqlite3_column_blob(statement, column) else {
            return nil
        }

        let count = Int(sqlite3_column_bytes(statement, column))
        return Data(bytes: bytes, count: count)
    }
}

private let databaseTransientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
