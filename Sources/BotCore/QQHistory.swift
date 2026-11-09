import Foundation
import CSQLite

/// The engine owns this connection on its main actor. Archive I/O never calls the model.
public final class QQHistory {
    public static let retention: TimeInterval = 365 * 86400
    private let db: OpaquePointer
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(url: URL) throws {
        var handle: OpaquePointer?
        let status = sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        guard status == SQLITE_OK, let handle else {
            sqlite3_close(handle)
            throw CoreError.invalid("无法打开本机会话历史库")
        }
        db = handle
        sqlite3_busy_timeout(db, 250)
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            try execute("PRAGMA secure_delete = ON")
            try execute("""
                CREATE TABLE IF NOT EXISTS messages(scope TEXT, id TEXT, time REAL, speaker TEXT, text TEXT, terms TEXT, UNIQUE(scope,id));
                CREATE INDEX IF NOT EXISTS message_time ON messages(scope,time,id);
                CREATE VIRTUAL TABLE IF NOT EXISTS search USING fts5(terms, content='messages', content_rowid='rowid');
                CREATE TRIGGER IF NOT EXISTS index_message AFTER INSERT ON messages BEGIN
                    INSERT INTO search(rowid,terms) VALUES(new.rowid,new.terms);
                END;
                CREATE TRIGGER IF NOT EXISTS delete_message AFTER DELETE ON messages BEGIN
                    INSERT INTO search(search,rowid,terms) VALUES('delete',old.rowid,old.terms);
                END;
                CREATE TABLE IF NOT EXISTS backfill(scope TEXT PRIMARY KEY, cursor TEXT, state TEXT, pages INTEGER);
                CREATE TABLE IF NOT EXISTS cleared(scope TEXT PRIMARY KEY, time REAL);
                CREATE TABLE IF NOT EXISTS history_vectors(message INTEGER PRIMARY KEY, model TEXT NOT NULL, embedding BLOB NOT NULL);
                CREATE TRIGGER IF NOT EXISTS delete_history_vector AFTER DELETE ON messages BEGIN
                    DELETE FROM history_vectors WHERE message=old.rowid;
                END;
                CREATE VIEW IF NOT EXISTS history_turn_rows AS
                WITH ordered AS (
                    SELECT rowid AS archive_row, scope, id, time, speaker, text,
                           row_number() OVER (PARTITION BY scope ORDER BY time,rowid) AS position,
                           lag(speaker) OVER (PARTITION BY scope ORDER BY time,rowid) AS previous_speaker,
                           lag(time) OVER (PARTITION BY scope,speaker ORDER BY time,rowid) AS previous_time
                    FROM messages
                ), boundaries AS (
                    SELECT *, CASE WHEN speaker != 'SELF_UNKNOWN' AND
                        (speaker=previous_speaker OR time-previous_time<=300) THEN NULL ELSE position END AS turn_start
                    FROM ordered
                )
                SELECT archive_row,scope,id,time,speaker,text,position,
                       max(turn_start) OVER (PARTITION BY scope,speaker ORDER BY position ROWS UNBOUNDED PRECEDING) AS turn
                FROM boundaries;
                """)
        } catch {
            sqlite3_close(handle)
            throw error
        }
    }

    deinit { sqlite3_close(db) }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw CoreError.invalid("会话历史库操作失败") }
    }

    @discardableResult private func query(_ sql: String, _ args: [String]) throws -> [[String]] {
        var handle: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &handle, nil) == SQLITE_OK, let statement = handle else {
            throw CoreError.invalid("会话历史查询失败")
        }
        defer { sqlite3_finalize(statement) }
        for (index, value) in args.enumerated() {
            guard sqlite3_bind_text(statement, Int32(index + 1), value, -1, transient) == SQLITE_OK else {
                throw CoreError.invalid("会话历史查询参数失败")
            }
        }
        var rows: [[String]] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_DONE: return rows
            case SQLITE_ROW:
                rows.append((0..<sqlite3_column_count(statement)).map {
                    sqlite3_column_text(statement, $0).map { String(cString: $0) } ?? ""
                })
            default: throw CoreError.invalid("会话历史查询未完成")
            }
        }
    }

    private func transaction(_ work: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do { try work(); try execute("COMMIT") }
        catch { try? execute("ROLLBACK"); throw error }
    }

    private static func terms(_ text: String) -> [String] {
        var result: [String] = [], word = "", previous: Unicode.Scalar?
        for scalar in text.lowercased().unicodeScalars {
            if (0x3400...0x9fff).contains(scalar.value) {
                if !word.isEmpty { result.append(word); word = "" }
                if let previous { result.append(String(previous) + String(scalar)) }
                previous = scalar
            } else {
                previous = nil
                if CharacterSet.alphanumerics.contains(scalar) { word.unicodeScalars.append(scalar) }
                else if !word.isEmpty { result.append(word); word = "" }
            }
        }
        if !word.isEmpty { result.append(word) }
        return result
    }

    public func append(_ events: [QQMemoryEvent], scope: String) throws {
        guard !events.isEmpty else { return }
        try transaction { try insert(events, scope: scope) }
    }

    private func insert(_ events: [QQMemoryEvent], scope: String) throws {
        let cutoff = Date(timeIntervalSince1970: try cutoff(scope: scope))
        for event in events where event.at >= cutoff {
            let text = String(QQMemoryBook.redact(event.text).prefix(1200)).replacingOccurrences(of: "\0", with: "")
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            try query("INSERT OR IGNORE INTO messages(scope,id,time,speaker,text,terms) VALUES(?,?,?,?,?,?)",
                      [scope, event.id, String(event.at.timeIntervalSince1970), event.subject, text, Self.terms(text).joined(separator: " ")])
        }
    }

    public func prune(now: Date = Date()) throws {
        try query("DELETE FROM messages WHERE time < ?", [String(now.timeIntervalSince1970 - Self.retention)])
    }

    public func clear(scope: String) throws {
        try transaction {
            try query("DELETE FROM messages WHERE scope=?", [scope])
            try query("DELETE FROM backfill WHERE scope=?", [scope])
            try query("INSERT OR REPLACE INTO cleared VALUES(?,?)", [scope, String(Date().timeIntervalSince1970)])
        }
    }

    public func cutoff(scope: String) throws -> Double {
        let cleared = try query("SELECT time FROM cleared WHERE scope=?", [scope]).first?.first.flatMap(Double.init) ?? 0
        return max(cleared, Date().timeIntervalSince1970 - Self.retention)
    }

    public func progress(scope: String) throws -> (cursor: String, state: String, pages: Int) {
        guard let row = try query("SELECT cursor,state,pages FROM backfill WHERE scope=?", [scope]).first else { return ("", "", 0) }
        return (row[0], row[1], Int(row[2]) ?? 0)
    }

    public func savePage(_ events: [QQMemoryEvent], scope: String, cursor: String, state: String, pages: Int) throws {
        try transaction {
            try insert(events, scope: scope)
            try query("INSERT OR REPLACE INTO backfill VALUES(?,?,?,?)", [scope, cursor, state, String(pages)])
        }
    }

    public func context(for text: String, scope: String, through time: Double, excluding: Set<String>, semanticIDs: [String] = []) throws -> String {
        let terms = Set(Self.terms(String(text.suffix(6000)))).sorted().prefix(32)
        let expression = terms.map { "\"\($0)\"" }.joined(separator: " OR ")
        let from = String(Date().timeIntervalSince1970 - Self.retention), through = String(time)
        let lexical = terms.isEmpty ? [] : try query("""
            SELECT m.id,m.time,m.speaker,m.text FROM search JOIN messages m ON m.rowid=search.rowid
            WHERE search MATCH ? AND m.scope=? AND m.time >= ? AND m.time < ?
            ORDER BY bm25(search),m.time DESC,m.id DESC LIMIT 64
            """, [expression, scope, from, through]).filter { !excluding.contains($0[0]) }.prefix(3)
        var semantic: [[String]] = []
        for id in semanticIDs.prefix(6) where !excluding.contains(id) {
            if let row = try query("""
                SELECT id,time,speaker,text FROM messages WHERE scope=? AND id=? AND time >= ? AND time < ?
                """, [scope, id, from, through]).first {
                semantic.append(row)
            }
        }
        let primaryLimit = lexical.isEmpty || semantic.isEmpty ? 3 : 4
        var hits: [[String]] = [], unique = Set<String>()
        for i in 0..<3 {
            for rows in [Array(lexical), semantic] where i < rows.count && hits.count < primaryLimit {
                if unique.insert(rows[i][0]).inserted { hits.append(rows[i]) }
            }
        }
        guard !hits.isEmpty else { return "" }
        var picked = Array(hits), seen = excluding.union(hits.map { $0[0] })
        var neighbors: [([String], Int)] = []
        for hit in hits {
            for (comparison, order) in [("<", "DESC"), (">", "ASC")] {
                let rows = try query("""
                    SELECT id,time,speaker,text FROM messages WHERE scope=? AND time >= ? AND time < ?
                    AND (time,id) \(comparison) (SELECT time,id FROM messages WHERE scope=? AND id=?)
                    ORDER BY time \(order),id \(order) LIMIT 50
                    """, [scope, from, through, scope, hit[0]])
                for row in rows where seen.insert(row[0]).inserted {
                    let score = Set(Self.terms(row[3])).intersection(terms).count
                    if score > 0 { neighbors.append((row, score)) }
                }
            }
        }
        picked += neighbors.sorted { $0.1 > $1.1 }.prefix(max(0, 6 - picked.count)).map(\.0)
        let turnRows = try groupedRows(scope: scope, from: from, through: through, anchors: picked.map { $0[0] })
        var turns: [String: String] = [:]
        var members: [String: [[String]]] = [:]
        for row in turnRows {
            turns[row[0]] = row[4]
            if !excluding.contains(row[0]) { members[row[4], default: []].append(row) }
        }
        var rendered = Set<String>()
        let grouped = picked.compactMap { hit -> [String]? in
            let turn = turns[hit[0]] ?? hit[0]
            guard rendered.insert(turn).inserted else { return nil }
            guard let rows = members[turn], rows.count > 1,
                  let anchor = rows.firstIndex(where: { $0[0] == hit[0] }) else { return hit }
            let start = max(0, anchor - 2), end = min(rows.count, anchor + 3)
            let excerpt = rows[start..<end]
            let text = excerpt.map { String($0[3].prefix(65)) }.joined(separator: "\n")
            return [hit[0], excerpt.first?[1] ?? hit[1], hit[2], text, excerpt.last?[1] ?? hit[1]]
        }
        let formatter = ISO8601DateFormatter()
        let lines = grouped.sorted {
            (Double($0[1]) ?? 0, $0[0]) < (Double($1[1]) ?? 0, $1[0])
        }.compactMap { row -> String? in
            guard let time = Double(row[1]) else { return nil }
            var fields = [
                    "time": formatter.string(from: Date(timeIntervalSince1970: time)),
                    "speaker": row[2], "text": String(row[3].prefix(325))
            ]
            if row.count == 5, let end = Double(row[4]) {
                fields["through"] = formatter.string(from: Date(timeIntervalSince1970: end))
            }
            guard let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]) else { return nil }
            return String(decoding: data, as: UTF8.self)
        }
        var output = ""
        for line in lines where output.count + line.count + 1 <= 1800 { output += line + "\n" }
        return output
    }

    private func groupedRows(scope: String, from: String, through: String, anchors: [String]) throws -> [[String]] {
        let placeholders = Array(repeating: "?", count: anchors.count).joined(separator: ",")
        return try query("""
            WITH eligible AS MATERIALIZED (
                SELECT id,time,speaker,text,turn,position FROM history_turn_rows WHERE scope=? AND time >= ? AND time < ?
            )
            SELECT id,time,speaker,text,turn FROM eligible
            WHERE turn IN (SELECT turn FROM eligible WHERE id IN (\(placeholders))) ORDER BY position
            """, [scope, from, through] + anchors)
    }
}
