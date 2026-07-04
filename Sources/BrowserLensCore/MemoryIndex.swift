import Foundation
import SQLite3

public actor MemoryIndex {
    private static let schemaVersion = 1

    private let database: SQLiteDatabase
    private let sessionizer: Sessionizer

    public nonisolated let databaseURL: URL

    public init(
        databaseURL: URL = MemoryIndex.defaultDatabaseURL(),
        sessionizer: Sessionizer = Sessionizer()
    ) {
        self.databaseURL = databaseURL
        self.sessionizer = sessionizer

        do {
            try FileManager.default.createDirectory(
                at: databaseURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            self.database = try SQLiteDatabase(path: databaseURL.path, readOnly: false)
            try Self.configure(self.database)
        } catch {
            fatalError("BrowserLens could not open local database: \(error)")
        }
    }

    public func ingest(_ visits: [BrowserVisit]) {
        guard !visits.isEmpty else {
            return
        }

        do {
            try database.execute("BEGIN IMMEDIATE;")
            for visit in visits {
                try upsert(visit)
            }
            try rebuildSessions()
            try rebuildItems()
            try rebuildSearchIndex()
            try database.execute("COMMIT;")
        } catch {
            try? database.execute("ROLLBACK;")
            fputs("BrowserLens index ingest failed: \(error)\n", stderr)
        }
    }

    public func search(_ query: String, filter: SearchFilter = SearchFilter(), limit: Int = 200) -> [BrowserItem] {
        do {
            let normalizedQuery = normalizedFTSQuery(query)
            let constraints = sqlConstraints(for: filter)
            let whereSQL = constraints.clauses.isEmpty ? "" : "WHERE \(constraints.clauses.joined(separator: " AND "))"
            let ftsFilterSQL = constraints.clauses.isEmpty ? "" : " AND \(constraints.clauses.joined(separator: " AND "))"
            let sql: String
            if normalizedQuery.isEmpty {
                sql = """
                SELECT canonical_url, url, title, domain, sources, kind, first_seen, last_seen, visit_count, session_id, session_title
                FROM items
                \(whereSQL)
                ORDER BY last_seen DESC
                LIMIT ?;
                """
            } else {
                sql = """
                SELECT items.canonical_url, items.url, items.title, items.domain, items.sources, items.kind,
                       items.first_seen, items.last_seen, items.visit_count, items.session_id, items.session_title
                FROM item_fts
                JOIN items ON items.canonical_url = item_fts.canonical_url
                WHERE item_fts MATCH ?
                \(ftsFilterSQL)
                ORDER BY bm25(item_fts), items.visit_count DESC, items.last_seen DESC
                LIMIT ?;
                """
            }

            var items: [BrowserItem] = []
            try database.query(sql, bind: { statement in
                var bindIndex: Int32 = 1
                if normalizedQuery.isEmpty {
                    bind(values: constraints.values, to: statement, startingAt: &bindIndex)
                    sqlite3_bind_int(statement, bindIndex, Int32(limit))
                } else {
                    sqliteBindText(statement, bindIndex, normalizedQuery)
                    bindIndex += 1
                    bind(values: constraints.values, to: statement, startingAt: &bindIndex)
                    sqlite3_bind_int(statement, bindIndex, Int32(limit))
                }
            }, row: { row in
                guard let item = item(from: row) else {
                    return
                }
                items.append(item)
            })
            return items
        } catch {
            fputs("BrowserLens search failed: \(error)\n", stderr)
            return []
        }
    }

    public func context(for canonicalURL: String, nearbyLimit: Int = 5) -> BrowserContext? {
        do {
            guard let item = try itemForCanonicalURL(canonicalURL) else {
                return nil
            }

            return BrowserContext(
                item: item,
                previousVisits: try nearbyVisits(for: canonicalURL, direction: .previous, limit: nearbyLimit),
                nextVisits: try nearbyVisits(for: canonicalURL, direction: .next, limit: nearbyLimit),
                sessionVisits: try sessionVisits(for: item.sessionID),
                savedTrails: try savedTrails(containing: canonicalURL)
            )
        } catch {
            fputs("BrowserLens context lookup failed: \(error)\n", stderr)
            return nil
        }
    }

    @discardableResult
    public func saveTrail(name: String, canonicalURLs: [String]) -> SavedTrail? {
        let orderedURLs = Array(NSOrderedSet(array: canonicalURLs).compactMap { $0 as? String })
        guard !orderedURLs.isEmpty else {
            return nil
        }

        let now = Date()
        let trail = SavedTrail(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Saved Trail" : name,
            createdAt: now,
            updatedAt: now,
            itemCount: orderedURLs.count
        )

        do {
            try database.execute("BEGIN IMMEDIATE;")
            try database.statement("""
            INSERT INTO saved_trails(id, name, created_at, updated_at)
            VALUES (?, ?, ?, ?);
            """) { statement in
                sqliteBindText(statement, 1, trail.id.uuidString)
                sqliteBindText(statement, 2, trail.name)
                sqlite3_bind_double(statement, 3, trail.createdAt.timeIntervalSince1970)
                sqlite3_bind_double(statement, 4, trail.updatedAt.timeIntervalSince1970)
            }

            for (position, canonicalURL) in orderedURLs.enumerated() {
                try database.statement("""
                INSERT INTO saved_trail_items(trail_id, canonical_url, position, added_at)
                VALUES (?, ?, ?, ?);
                """) { statement in
                    sqliteBindText(statement, 1, trail.id.uuidString)
                    sqliteBindText(statement, 2, canonicalURL)
                    sqlite3_bind_int(statement, 3, Int32(position))
                    sqlite3_bind_double(statement, 4, now.timeIntervalSince1970)
                }
            }
            try database.execute("COMMIT;")
            return trail
        } catch {
            try? database.execute("ROLLBACK;")
            fputs("BrowserLens save trail failed: \(error)\n", stderr)
            return nil
        }
    }

    public func clear() {
        do {
            try database.execute("""
            DELETE FROM saved_trail_items;
            DELETE FROM saved_trails;
            DELETE FROM visit_sessions;
            DELETE FROM sessions;
            DELETE FROM imported_visits;
            DELETE FROM items;
            DELETE FROM item_fts;
            """)
        } catch {
            fputs("BrowserLens clear failed: \(error)\n", stderr)
        }
    }

    public func itemCount() -> Int {
        do {
            var count = 0
            try database.query("SELECT COUNT(*) FROM items;") { row in
                count = row.int(0)
            }
            return count
        } catch {
            return 0
        }
    }

    public func sessions(from visits: [BrowserVisit]) -> [BrowserSession] {
        sessionizer.group(visits)
    }

    private func upsert(_ visit: BrowserVisit) throws {
        try database.statement("""
        INSERT INTO imported_visits(
            id, canonical_url, url, title, domain, source, kind, visited_at, occurrence_count
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            canonical_url = excluded.canonical_url,
            url = excluded.url,
            title = excluded.title,
            domain = excluded.domain,
            source = excluded.source,
            kind = excluded.kind,
            visited_at = excluded.visited_at,
            occurrence_count = excluded.occurrence_count;
        """) { statement in
            sqliteBindText(statement, 1, visit.sourceItemID)
            sqliteBindText(statement, 2, visit.canonicalURL)
            sqliteBindText(statement, 3, visit.url.absoluteString)
            sqliteBindText(statement, 4, visit.title)
            sqliteBindText(statement, 5, visit.domain)
            sqliteBindText(statement, 6, visit.source.rawValue)
            sqlite3_bind_int(statement, 7, Int32(visit.kind.rawValue))
            sqlite3_bind_double(statement, 8, visit.visitedAt.timeIntervalSince1970)
            sqlite3_bind_int(statement, 9, Int32(max(1, visit.occurrenceCount)))
        }
    }

    private func rebuildItems() throws {
        try database.execute("""
        DELETE FROM items;
        INSERT INTO items(canonical_url, url, title, domain, sources, kind, first_seen, last_seen, visit_count, session_id, session_title)
        SELECT
            v.canonical_url,
            COALESCE((
                SELECT v2.url FROM imported_visits v2
                WHERE v2.canonical_url = v.canonical_url
                ORDER BY v2.visited_at DESC
                LIMIT 1
            ), v.url) AS url,
            COALESCE(NULLIF((
                SELECT v3.title FROM imported_visits v3
                WHERE v3.canonical_url = v.canonical_url AND v3.title != ''
                ORDER BY v3.visited_at DESC
                LIMIT 1
            ), ''), v.domain) AS title,
            v.domain,
            group_concat(DISTINCT v.source) AS sources,
            (CASE WHEN SUM(v.kind & 1) > 0 THEN 1 ELSE 0 END) |
            (CASE WHEN SUM(v.kind & 2) > 0 THEN 2 ELSE 0 END) AS kind,
            COALESCE(MIN(CASE WHEN (v.kind & 1) = 1 THEN v.visited_at END), MIN(v.visited_at)) AS first_seen,
            COALESCE(MAX(CASE WHEN (v.kind & 1) = 1 THEN v.visited_at END), MAX(v.visited_at)) AS last_seen,
            SUM(v.occurrence_count) AS visit_count,
            (
                SELECT vs.session_id
                FROM imported_visits latest
                JOIN visit_sessions vs ON vs.visit_id = latest.id
                WHERE latest.canonical_url = v.canonical_url AND (latest.kind & 1) = 1
                ORDER BY latest.visited_at DESC
                LIMIT 1
            ) AS session_id,
            (
                SELECT s.title
                FROM imported_visits latest
                JOIN visit_sessions vs ON vs.visit_id = latest.id
                JOIN sessions s ON s.id = vs.session_id
                WHERE latest.canonical_url = v.canonical_url AND (latest.kind & 1) = 1
                ORDER BY latest.visited_at DESC
                LIMIT 1
            ) AS session_title
        FROM imported_visits v
        GROUP BY v.canonical_url;
        """)
    }

    private func rebuildSearchIndex() throws {
        try database.execute("""
        DELETE FROM item_fts;
        INSERT INTO item_fts(canonical_url, title, url, domain)
        SELECT canonical_url, title, url, domain FROM items;
        """)
    }

    private func rebuildSessions() throws {
        var visits: [BrowserVisit] = []
        try database.query("""
        SELECT id, title, url, canonical_url, domain, source, kind, visited_at
        FROM imported_visits
        WHERE (kind & 1) = 1
        ORDER BY visited_at DESC
        LIMIT 5000;
        """) { row in
            guard
                let id = row.string(0),
                let urlString = row.string(2),
                let url = URL(string: urlString),
                let canonicalURL = row.string(3),
                let domain = row.string(4),
                let sourceRaw = row.string(5),
                let source = BrowserSource(rawValue: sourceRaw)
            else {
                return
            }

            visits.append(BrowserVisit(
                title: row.string(1) ?? "",
                url: url,
                canonicalURL: canonicalURL,
                domain: domain,
                source: source,
                kind: BrowserItemKind(rawValue: row.int(6)),
                visitedAt: Date(timeIntervalSince1970: row.double(7)),
                sourceItemID: id
            ))
        }

        let sessions = sessionizer.group(visits)
        try database.execute("""
        DELETE FROM visit_sessions;
        DELETE FROM sessions;
        """)

        for session in sessions {
            try database.statement("""
            INSERT INTO sessions(id, title, started_at, ended_at, primary_domain, visit_count)
            VALUES (?, ?, ?, ?, ?, ?);
            """) { statement in
                sqliteBindText(statement, 1, session.id.uuidString)
                sqliteBindText(statement, 2, session.title)
                sqlite3_bind_double(statement, 3, session.startedAt.timeIntervalSince1970)
                sqlite3_bind_double(statement, 4, session.endedAt.timeIntervalSince1970)
                sqliteBindText(statement, 5, session.primaryDomain)
                sqlite3_bind_int(statement, 6, Int32(session.visits.count))
            }

            for (position, visit) in session.visits.enumerated() {
                try database.statement("""
                INSERT INTO visit_sessions(visit_id, session_id, position)
                VALUES (?, ?, ?);
                """) { statement in
                    sqliteBindText(statement, 1, visit.sourceItemID)
                    sqliteBindText(statement, 2, session.id.uuidString)
                    sqlite3_bind_int(statement, 3, Int32(position))
                }
            }
        }
    }

    private func item(from row: SQLiteRow) -> BrowserItem? {
        guard
            let canonicalURL = row.string(0),
            let urlString = row.string(1),
            let url = URL(string: urlString),
            let title = row.string(2),
            let domain = row.string(3),
            let sources = row.string(4)
        else {
            return nil
        }

        return BrowserItem(
            id: UUID(uuidString: deterministicUUIDString(from: canonicalURL)) ?? UUID(),
            title: title,
            url: url,
            canonicalURL: canonicalURL,
            domain: domain,
            sources: Set(sources.split(separator: ",").compactMap { BrowserSource(rawValue: String($0)) }),
            kind: BrowserItemKind(rawValue: row.int(5)),
            firstSeen: Date(timeIntervalSince1970: row.double(6)),
            lastSeen: Date(timeIntervalSince1970: row.double(7)),
            visitCount: row.int(8),
            sessionID: row.string(9).flatMap(UUID.init(uuidString:)),
            sessionTitle: row.string(10)
        )
    }

    private static func configure(_ database: SQLiteDatabase) throws {
        try database.execute("""
        PRAGMA journal_mode=WAL;
        PRAGMA synchronous=NORMAL;
        """)

        let version = try userVersion(database)
        if version == 0 {
            try database.execute("BEGIN IMMEDIATE;")
            do {
                try createCurrentSchema(database)
                try addColumnIfMissing(database, table: "items", column: "session_id", definition: "TEXT NULL")
                try database.execute("PRAGMA user_version = \(schemaVersion);")
                try database.execute("COMMIT;")
            } catch {
                try? database.execute("ROLLBACK;")
                throw error
            }
        } else if version < schemaVersion {
            try database.execute("BEGIN IMMEDIATE;")
            do {
                try migrate(database, from: version)
                try database.execute("COMMIT;")
            } catch {
                try? database.execute("ROLLBACK;")
                throw error
            }
        }
    }

    public static func defaultDatabaseURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: "\(NSHomeDirectory())/Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("BrowserLens", isDirectory: true)
            .appendingPathComponent("BrowserLens.sqlite")
    }
}

private enum NearbyDirection {
    case previous
    case next
}

private enum SQLValue {
    case double(Double)
    case int(Int)
    case text(String)
}

private struct SQLConstraints {
    var clauses: [String] = []
    var values: [SQLValue] = []
}

private extension MemoryIndex {
    func sqlConstraints(for filter: SearchFilter) -> SQLConstraints {
        var constraints = SQLConstraints()

        if filter.sources != Set(BrowserSource.allCases) {
            let sourceClauses = filter.sources
                .sorted { $0.rawValue < $1.rawValue }
                .map { _ in "instr(',' || items.sources || ',', ',' || ? || ',') > 0" }
            if sourceClauses.isEmpty {
                constraints.clauses.append("0")
            } else {
                constraints.clauses.append("(\(sourceClauses.joined(separator: " OR ")))")
                constraints.values.append(contentsOf: filter.sources
                    .sorted { $0.rawValue < $1.rawValue }
                    .map { .text($0.rawValue) })
            }
        }

        if let requiredKind = filter.requiredKind {
            constraints.clauses.append("(items.kind & ?) != 0")
            constraints.values.append(.int(requiredKind.rawValue))
        }

        if let dateRange = filter.dateRange {
            constraints.clauses.append("items.last_seen BETWEEN ? AND ?")
            constraints.values.append(.double(dateRange.lowerBound.timeIntervalSince1970))
            constraints.values.append(.double(dateRange.upperBound.timeIntervalSince1970))
        }

        return constraints
    }

    func itemForCanonicalURL(_ canonicalURL: String) throws -> BrowserItem? {
        var item: BrowserItem?
        try database.query("""
        SELECT canonical_url, url, title, domain, sources, kind, first_seen, last_seen, visit_count, session_id, session_title
        FROM items
        WHERE canonical_url = ?
        LIMIT 1;
        """, bind: { statement in
            sqliteBindText(statement, 1, canonicalURL)
        }, row: { row in
            item = self.item(from: row)
        })
        return item
    }

    func nearbyVisits(for canonicalURL: String, direction: NearbyDirection, limit: Int) throws -> [BrowserVisit] {
        let comparison = direction == .previous ? "<" : ">"
        let order = direction == .previous ? "DESC" : "ASC"
        var visits: [BrowserVisit] = []
        try database.query("""
        WITH selected AS (
            SELECT visited_at
            FROM imported_visits
            WHERE canonical_url = ? AND (kind & 1) = 1
            ORDER BY visited_at DESC
            LIMIT 1
        )
        SELECT id, title, url, canonical_url, domain, source, kind, visited_at, occurrence_count
        FROM imported_visits
        WHERE (kind & 1) = 1
          AND visited_at \(comparison) (SELECT visited_at FROM selected)
        ORDER BY visited_at \(order)
        LIMIT ?;
        """, bind: { statement in
            sqliteBindText(statement, 1, canonicalURL)
            sqlite3_bind_int(statement, 2, Int32(max(0, limit)))
        }, row: { row in
            if let visit = self.visit(from: row) {
                visits.append(visit)
            }
        })
        return direction == .previous ? visits.reversed() : visits
    }

    func sessionVisits(for sessionID: UUID?) throws -> [BrowserVisit] {
        guard let sessionID else {
            return []
        }
        var visits: [BrowserVisit] = []
        try database.query("""
        SELECT v.id, v.title, v.url, v.canonical_url, v.domain, v.source, v.kind, v.visited_at, v.occurrence_count
        FROM visit_sessions vs
        JOIN imported_visits v ON v.id = vs.visit_id
        WHERE vs.session_id = ?
        ORDER BY vs.position ASC;
        """, bind: { statement in
            sqliteBindText(statement, 1, sessionID.uuidString)
        }, row: { row in
            if let visit = self.visit(from: row) {
                visits.append(visit)
            }
        })
        return visits
    }

    func savedTrails(containing canonicalURL: String) throws -> [SavedTrail] {
        var trails: [SavedTrail] = []
        try database.query("""
        SELECT st.id, st.name, st.created_at, st.updated_at, COUNT(sti2.canonical_url) AS item_count
        FROM saved_trail_items sti
        JOIN saved_trails st ON st.id = sti.trail_id
        JOIN saved_trail_items sti2 ON sti2.trail_id = st.id
        WHERE sti.canonical_url = ?
        GROUP BY st.id, st.name, st.created_at, st.updated_at
        ORDER BY st.updated_at DESC;
        """, bind: { statement in
            sqliteBindText(statement, 1, canonicalURL)
        }, row: { row in
            guard
                let idString = row.string(0),
                let id = UUID(uuidString: idString),
                let name = row.string(1)
            else {
                return
            }
            trails.append(SavedTrail(
                id: id,
                name: name,
                createdAt: Date(timeIntervalSince1970: row.double(2)),
                updatedAt: Date(timeIntervalSince1970: row.double(3)),
                itemCount: row.int(4)
            ))
        })
        return trails
    }

    func visit(from row: SQLiteRow) -> BrowserVisit? {
        guard
            let id = row.string(0),
            let title = row.string(1),
            let urlString = row.string(2),
            let url = URL(string: urlString),
            let canonicalURL = row.string(3),
            let domain = row.string(4),
            let sourceRaw = row.string(5),
            let source = BrowserSource(rawValue: sourceRaw)
        else {
            return nil
        }

        return BrowserVisit(
            title: title,
            url: url,
            canonicalURL: canonicalURL,
            domain: domain,
            source: source,
            kind: BrowserItemKind(rawValue: row.int(6)),
            visitedAt: Date(timeIntervalSince1970: row.double(7)),
            sourceItemID: id,
            occurrenceCount: row.int(8)
        )
    }
}

private func bind(values: [SQLValue], to statement: OpaquePointer?, startingAt index: inout Int32) {
    for value in values {
        switch value {
        case .double(let double):
            sqlite3_bind_double(statement, index, double)
        case .int(let int):
            sqlite3_bind_int(statement, index, Int32(int))
        case .text(let text):
            sqliteBindText(statement, index, text)
        }
        index += 1
    }
}

private extension MemoryIndex {
    static func userVersion(_ database: SQLiteDatabase) throws -> Int {
        var version = 0
        try database.query("PRAGMA user_version;") { row in
            version = row.int(0)
        }
        return version
    }

    static func migrate(_ database: SQLiteDatabase, from version: Int) throws {
        if version < 1 {
            try createCurrentSchema(database)
            try addColumnIfMissing(database, table: "items", column: "session_id", definition: "TEXT NULL")
            try database.execute("PRAGMA user_version = 1;")
        }
    }

    static func createCurrentSchema(_ database: SQLiteDatabase) throws {
        try database.execute("""
        CREATE TABLE IF NOT EXISTS imported_visits(
            id TEXT PRIMARY KEY,
            canonical_url TEXT NOT NULL,
            url TEXT NOT NULL,
            title TEXT NOT NULL,
            domain TEXT NOT NULL,
            source TEXT NOT NULL,
            kind INTEGER NOT NULL,
            visited_at REAL NOT NULL,
            occurrence_count INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS imported_visits_canonical_idx ON imported_visits(canonical_url);
        CREATE INDEX IF NOT EXISTS imported_visits_seen_idx ON imported_visits(visited_at DESC);
        CREATE TABLE IF NOT EXISTS sessions(
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            started_at REAL NOT NULL,
            ended_at REAL NOT NULL,
            primary_domain TEXT NOT NULL,
            visit_count INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS visit_sessions(
            visit_id TEXT PRIMARY KEY,
            session_id TEXT NOT NULL,
            position INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS visit_sessions_session_idx ON visit_sessions(session_id, position);
        CREATE TABLE IF NOT EXISTS items(
            canonical_url TEXT PRIMARY KEY,
            url TEXT NOT NULL,
            title TEXT NOT NULL,
            domain TEXT NOT NULL,
            sources TEXT NOT NULL,
            kind INTEGER NOT NULL,
            first_seen REAL NOT NULL,
            last_seen REAL NOT NULL,
            visit_count INTEGER NOT NULL,
            session_id TEXT NULL,
            session_title TEXT NULL
        );
        CREATE TABLE IF NOT EXISTS saved_trails(
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS saved_trail_items(
            trail_id TEXT NOT NULL,
            canonical_url TEXT NOT NULL,
            position INTEGER NOT NULL,
            added_at REAL NOT NULL,
            PRIMARY KEY(trail_id, canonical_url)
        );
        CREATE INDEX IF NOT EXISTS saved_trail_items_url_idx ON saved_trail_items(canonical_url);
        CREATE VIRTUAL TABLE IF NOT EXISTS item_fts USING fts5(
            canonical_url UNINDEXED,
            title,
            url,
            domain
        );
        """)
    }

    static func addColumnIfMissing(
        _ database: SQLiteDatabase,
        table: String,
        column: String,
        definition: String
    ) throws {
        var exists = false
        try database.query("PRAGMA table_info(\(table));") { row in
            if row.string(1) == column {
                exists = true
            }
        }
        if !exists {
            try database.execute("ALTER TABLE \(table) ADD COLUMN \(column) \(definition);")
        }
    }
}

private func normalizedFTSQuery(_ query: String) -> String {
    let tokens = query
        .lowercased()
        .split { !$0.isLetter && !$0.isNumber }
        .map(String.init)
        .filter { !$0.isEmpty }

    return tokens.map { "\"\($0)\"*" }.joined(separator: " ")
}

private func deterministicUUIDString(from string: String) -> String {
    var hash = UInt64(14_695_981_039_346_656_037)
    for byte in string.utf8 {
        hash ^= UInt64(byte)
        hash &*= 1_099_511_628_211
    }
    let hex = String(format: "%016llx%016llx", hash, hash ^ 0x9e3779b97f4a7c15)
    return "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-\(hex.dropFirst(20).prefix(12))"
}
