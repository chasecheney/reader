import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct IndexRow {
    var stem: String
    var id: String
    var title: String
    var seriesKey: String
    var tags: [String]
    var size: Int
    var mtime: Double
}

/// Local SQLite FTS5 index over titles, tags and full story text.
/// Lives in Application Support on each device and is (re)built
/// incrementally from the shared library folder.
actor SearchIndex {

    enum IndexError: Error { case open(String), sql(String) }

    private var db: OpaquePointer?

    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        var handle: OpaquePointer?
        guard sqlite3_open(url.path, &handle) == SQLITE_OK, let h = handle else {
            throw IndexError.open(String(cString: sqlite3_errmsg(handle)))
        }
        db = h
        try Self.exec(h, """
            PRAGMA journal_mode=WAL;
            PRAGMA synchronous=NORMAL;
            CREATE TABLE IF NOT EXISTS stories(
                stem TEXT PRIMARY KEY,
                id TEXT, title TEXT, serieskey TEXT, tags TEXT,
                size INTEGER, mtime REAL);
            CREATE VIRTUAL TABLE IF NOT EXISTS fts USING fts5(
                title, tags, body, tokenize='porter unicode61');
            """)
    }

    private static func exec(_ h: OpaquePointer, _ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(h, sql, nil, nil, &err) == SQLITE_OK else {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw IndexError.sql(msg)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard let h = db, sqlite3_prepare_v2(h, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else {
            throw IndexError.sql(String(cString: sqlite3_errmsg(db)))
        }
        return s
    }

    private func bind(_ stmt: OpaquePointer, _ idx: Int32, _ value: String) {
        sqlite3_bind_text(stmt, idx, value, -1, SQLITE_TRANSIENT)
    }

    // MARK: - Maintenance

    /// Wrap bulk index work (initial import!) in one transaction per batch —
    /// dramatically faster than SQLite's default transaction-per-statement.
    func beginBatch() { if let h = db { try? Self.exec(h, "BEGIN") } }
    func commitBatch() { if let h = db { try? Self.exec(h, "COMMIT") } }

    /// Empty the entire index (used by "Delete All Stories").
    func clear() {
        guard let h = db else { return }
        try? Self.exec(h, "DELETE FROM fts; DELETE FROM stories; VACUUM;")
    }

    /// stem -> (mtime, size) for change detection.
    func fileStamps() -> [String: (mtime: Double, size: Int)] {
        var out: [String: (Double, Int)] = [:]
        guard let stmt = try? prepare("SELECT stem, mtime, size FROM stories") else { return out }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            let stem = String(cString: sqlite3_column_text(stmt, 0))
            out[stem] = (sqlite3_column_double(stmt, 1), Int(sqlite3_column_int64(stmt, 2)))
        }
        return out
    }

    func upsert(stem: String, id: String, title: String, seriesKey: String,
                tags: [String], size: Int, mtime: Double, body: String) {
        guard let h = db else { return }
        let tagText = tags.joined(separator: " ")

        remove(stem: stem)

        if let ins = try? prepare("""
            INSERT INTO stories(stem,id,title,serieskey,tags,size,mtime)
            VALUES(?,?,?,?,?,?,?)
            """) {
            bind(ins, 1, stem); bind(ins, 2, id); bind(ins, 3, title)
            bind(ins, 4, seriesKey); bind(ins, 5, tagText)
            sqlite3_bind_int64(ins, 6, Int64(size))
            sqlite3_bind_double(ins, 7, mtime)
            sqlite3_step(ins)
            sqlite3_finalize(ins)
        }
        let rowid = sqlite3_last_insert_rowid(h)
        if let ins = try? prepare("INSERT INTO fts(rowid,title,tags,body) VALUES(?,?,?,?)") {
            sqlite3_bind_int64(ins, 1, rowid)
            bind(ins, 2, title); bind(ins, 3, tagText); bind(ins, 4, body)
            sqlite3_step(ins)
            sqlite3_finalize(ins)
        }
    }

    func remove(stem: String) {
        if let sel = try? prepare("SELECT rowid FROM stories WHERE stem=?") {
            bind(sel, 1, stem)
            if sqlite3_step(sel) == SQLITE_ROW {
                let rowid = sqlite3_column_int64(sel, 0)
                if let del = try? prepare("DELETE FROM fts WHERE rowid=?") {
                    sqlite3_bind_int64(del, 1, rowid)
                    sqlite3_step(del)
                    sqlite3_finalize(del)
                }
            }
            sqlite3_finalize(sel)
        }
        if let del = try? prepare("DELETE FROM stories WHERE stem=?") {
            bind(del, 1, stem)
            sqlite3_step(del)
            sqlite3_finalize(del)
        }
    }

    /// Update the tags column (filename tags + custom tags) for search.
    func updateTags(stem: String, tags: [String]) {
        let tagText = tags.joined(separator: " ")
        if let sel = try? prepare("SELECT rowid FROM stories WHERE stem=?") {
            bind(sel, 1, stem)
            if sqlite3_step(sel) == SQLITE_ROW {
                let rowid = sqlite3_column_int64(sel, 0)
                if let up = try? prepare("UPDATE fts SET tags=? WHERE rowid=?") {
                    bind(up, 1, tagText)
                    sqlite3_bind_int64(up, 2, rowid)
                    sqlite3_step(up)
                    sqlite3_finalize(up)
                }
            }
            sqlite3_finalize(sel)
        }
    }

    func allRows() -> [IndexRow] {
        var out: [IndexRow] = []
        guard let stmt = try? prepare("SELECT stem,id,title,serieskey,tags,size,mtime FROM stories") else { return out }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            let tags = String(cString: sqlite3_column_text(stmt, 4))
                .split(separator: " ").map(String.init)
            out.append(IndexRow(
                stem: String(cString: sqlite3_column_text(stmt, 0)),
                id: String(cString: sqlite3_column_text(stmt, 1)),
                title: String(cString: sqlite3_column_text(stmt, 2)),
                seriesKey: String(cString: sqlite3_column_text(stmt, 3)),
                tags: tags,
                size: Int(sqlite3_column_int64(stmt, 5)),
                mtime: sqlite3_column_double(stmt, 6)))
        }
        return out
    }

    /// Full-text search over title, tags and body. Returns matching stems.
    func search(_ text: String) -> Set<String> {
        let tokens = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return [] }
        let match = tokens.map { "\"\($0)\"*" }.joined(separator: " ")

        var out: Set<String> = []
        guard let stmt = try? prepare("""
            SELECT s.stem FROM fts f JOIN stories s ON s.rowid = f.rowid
            WHERE fts MATCH ? LIMIT 5000
            """) else { return out }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, match)
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.insert(String(cString: sqlite3_column_text(stmt, 0)))
        }
        return out
    }

    deinit { if let h = db { sqlite3_close(h) } }
}
