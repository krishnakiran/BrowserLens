import Foundation
import SQLite3

public protocol BrowserImporter: Sendable {
    var source: BrowserSource { get }
    func importVisits() async throws -> [BrowserVisit]
}

public enum ImporterError: LocalizedError, Equatable {
    case unsupportedInScaffold
    case fileNotFound(String)
    case unreadableBookmarks(String)
    case sqliteOpenFailed(String)
    case sqliteQueryFailed(String)
    case temporaryCopyFailed(String)
    case privacyPermissionRequired(browser: String, path: String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedInScaffold:
            return "Importer is not implemented."
        case .fileNotFound(let path):
            return "File not found: \(path)"
        case .unreadableBookmarks(let path):
            return "Could not read bookmarks at \(path)."
        case .sqliteOpenFailed(let message):
            return "Could not open browser database: \(message)"
        case .sqliteQueryFailed(let message):
            return "Could not query browser database: \(message)"
        case .temporaryCopyFailed(let message):
            return "Could not copy browser database: \(message)"
        case .privacyPermissionRequired(let browser, let path):
            return "\(browser) data is protected by macOS. Grant Full Disk Access to BrowserLens.app, or to Terminal if launching with swift run, then click Reindex Now. Blocked path: \(path)"
        }
    }
}

public struct ChromeImporter: BrowserImporter {
    public let source: BrowserSource = .chrome
    public var profileDirectory: URL
    public var maxHistoryItems: Int
    private let canonicalizer: URLCanonicalizer

    public init(
        profileDirectory: URL = URL(fileURLWithPath: "\(NSHomeDirectory())/Library/Application Support/Google/Chrome/Default"),
        maxHistoryItems: Int = 20_000,
        canonicalizer: URLCanonicalizer = URLCanonicalizer()
    ) {
        self.profileDirectory = profileDirectory
        self.maxHistoryItems = maxHistoryItems
        self.canonicalizer = canonicalizer
    }

    public func importVisits() async throws -> [BrowserVisit] {
        var visits: [BrowserVisit] = []
        visits.append(contentsOf: try importHistory())
        visits.append(contentsOf: try importBookmarks())
        return visits
    }

    private func importHistory() throws -> [BrowserVisit] {
        let historyURL = profileDirectory.appendingPathComponent("History")
        guard FileManager.default.fileExists(atPath: historyURL.path) else {
            return []
        }

        let copyURL = try temporaryCopy(of: historyURL, prefix: "browserlens-chrome-history")
        defer { removeTemporarySQLiteCopy(copyURL) }

        let database = try SQLiteDatabase(path: copyURL.path)
        var visits: [BrowserVisit] = []
        let sql = """
        SELECT urls.id,
               urls.url,
               urls.title,
               urls.visit_count,
               COALESCE(MAX(visits.visit_time), urls.last_visit_time) AS last_seen
        FROM urls
        LEFT JOIN visits ON visits.url = urls.id
        WHERE urls.url IS NOT NULL AND urls.url != '' AND urls.hidden = 0
        GROUP BY urls.id
        ORDER BY last_seen DESC
        LIMIT ?;
        """

        try database.query(sql, bind: { statement in
            sqlite3_bind_int(statement, 1, Int32(maxHistoryItems))
        }, row: { row in
            guard let visit = makeVisit(
                title: row.string(2) ?? "",
                urlString: row.string(1),
                kind: .history,
                timestamp: Self.dateFromChromiumTimestamp(row.double(4)),
                sourceItemID: "chrome:\(profileDirectory.lastPathComponent):history:\(row.int(0))",
                occurrenceCount: row.int(3)
            ) else {
                return
            }
            visits.append(visit)
        })

        return visits
    }

    private func importBookmarks() throws -> [BrowserVisit] {
        let bookmarksURL = profileDirectory.appendingPathComponent("Bookmarks")
        guard FileManager.default.fileExists(atPath: bookmarksURL.path) else {
            return []
        }

        let data: Data
        do {
            data = try Data(contentsOf: bookmarksURL)
        } catch {
            throw browserFileAccessError(for: bookmarksURL, error: error)
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ImporterError.unreadableBookmarks(bookmarksURL.path)
        }

        var visits: [BrowserVisit] = []
        if let roots = root["roots"] as? [String: Any] {
            for value in roots.values {
                collectChromeBookmarks(from: value, into: &visits)
            }
        }
        return visits
    }

    private func collectChromeBookmarks(from value: Any, into visits: inout [BrowserVisit]) {
        guard let node = value as? [String: Any] else {
            return
        }

        if let type = node["type"] as? String, type == "url" {
            let title = node["name"] as? String ?? ""
            let date = (node["date_added"] as? String).flatMap(Double.init).map(Self.dateFromChromiumTimestamp) ?? Date.distantPast
            let id = node["id"] as? String ?? node["guid"] as? String ?? node["url"] as? String
            if let visit = makeVisit(
                title: title,
                urlString: node["url"] as? String,
                kind: .bookmark,
                timestamp: date,
                sourceItemID: "chrome:\(profileDirectory.lastPathComponent):bookmark:\(id ?? UUID().uuidString)"
            ) {
                visits.append(visit)
            }
        }

        if let children = node["children"] as? [Any] {
            for child in children {
                collectChromeBookmarks(from: child, into: &visits)
            }
        }
    }

    private func makeVisit(
        title: String,
        urlString: String?,
        kind: BrowserItemKind,
        timestamp: Date,
        sourceItemID: String? = nil,
        occurrenceCount: Int = 1
    ) -> BrowserVisit? {
        guard let urlString, let url = URL(string: urlString), url.scheme != nil else {
            return nil
        }
        return BrowserVisit(
            title: title,
            url: url,
            canonicalURL: canonicalizer.canonicalString(for: url),
            domain: canonicalizer.domain(for: url),
            source: .chrome,
            kind: kind,
            visitedAt: timestamp,
            sourceItemID: sourceItemID,
            occurrenceCount: occurrenceCount
        )
    }

    static func dateFromChromiumTimestamp(_ timestamp: Double) -> Date {
        Date(timeIntervalSince1970: (timestamp / 1_000_000) - 11_644_473_600)
    }

    public static func discoverProfiles(
        chromeDirectory: URL = URL(fileURLWithPath: "\(NSHomeDirectory())/Library/Application Support/Google/Chrome"),
        maxHistoryItems: Int = 20_000
    ) -> [ChromeImporter] {
        let skipped = Set(["System Profile", "Guest Profile"])
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: chromeDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return [ChromeImporter(maxHistoryItems: maxHistoryItems)]
        }

        let profiles = children.filter { url in
            guard
                !skipped.contains(url.lastPathComponent),
                (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            else {
                return false
            }

            return FileManager.default.fileExists(atPath: url.appendingPathComponent("History").path)
                || FileManager.default.fileExists(atPath: url.appendingPathComponent("Bookmarks").path)
        }

        let importers = profiles
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map { ChromeImporter(profileDirectory: $0, maxHistoryItems: maxHistoryItems) }

        return importers.isEmpty ? [ChromeImporter(maxHistoryItems: maxHistoryItems)] : importers
    }
}

public struct SafariImporter: BrowserImporter {
    public let source: BrowserSource = .safari
    public var libraryDirectory: URL
    public var maxHistoryItems: Int
    private let canonicalizer: URLCanonicalizer

    public init(
        libraryDirectory: URL = URL(fileURLWithPath: "\(NSHomeDirectory())/Library/Safari"),
        maxHistoryItems: Int = 20_000,
        canonicalizer: URLCanonicalizer = URLCanonicalizer()
    ) {
        self.libraryDirectory = libraryDirectory
        self.maxHistoryItems = maxHistoryItems
        self.canonicalizer = canonicalizer
    }

    public func importVisits() async throws -> [BrowserVisit] {
        var visits: [BrowserVisit] = []
        visits.append(contentsOf: try importHistory())
        visits.append(contentsOf: try importBookmarks())
        return visits
    }

    private func importHistory() throws -> [BrowserVisit] {
        let historyURL = libraryDirectory.appendingPathComponent("History.db")
        guard FileManager.default.fileExists(atPath: historyURL.path) else {
            return []
        }

        let copyURL = try temporaryCopy(of: historyURL, prefix: "browserlens-safari-history")
        defer { removeTemporarySQLiteCopy(copyURL) }

        let database = try SQLiteDatabase(path: copyURL.path)
        var visits: [BrowserVisit] = []
        let sql = """
        SELECT hi.id,
               hi.url,
               COALESCE((
                   SELECT hv2.title
                   FROM history_visits hv2
                   WHERE hv2.history_item = hi.id AND hv2.title IS NOT NULL
                   ORDER BY hv2.visit_time DESC
                   LIMIT 1
               ), '') AS title,
               hi.visit_count,
               MAX(hv.visit_time) AS last_seen
        FROM history_items hi
        JOIN history_visits hv ON hv.history_item = hi.id
        WHERE hi.url IS NOT NULL AND hi.url != '' AND hv.load_successful = 1
        GROUP BY hi.id
        ORDER BY last_seen DESC
        LIMIT ?;
        """

        try database.query(sql, bind: { statement in
            sqlite3_bind_int(statement, 1, Int32(maxHistoryItems))
        }, row: { row in
            guard let visit = makeVisit(
                title: row.string(2) ?? "",
                urlString: row.string(1),
                kind: .history,
                timestamp: Self.dateFromSafariTimestamp(row.double(4)),
                sourceItemID: "safari:history:\(row.int(0))",
                occurrenceCount: row.int(3)
            ) else {
                return
            }
            visits.append(visit)
        })

        return visits
    }

    private func importBookmarks() throws -> [BrowserVisit] {
        let bookmarksURL = libraryDirectory.appendingPathComponent("Bookmarks.plist")
        guard FileManager.default.fileExists(atPath: bookmarksURL.path) else {
            return []
        }

        let data: Data
        do {
            data = try Data(contentsOf: bookmarksURL)
        } catch {
            throw browserFileAccessError(for: bookmarksURL, error: error)
        }
        guard let root = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            throw ImporterError.unreadableBookmarks(bookmarksURL.path)
        }

        var visits: [BrowserVisit] = []
        collectSafariBookmarks(from: root, into: &visits)
        return visits
    }

    private func collectSafariBookmarks(from value: Any, into visits: inout [BrowserVisit]) {
        guard let node = value as? [String: Any] else {
            return
        }

        if let urlString = node["URLString"] as? String {
            let title = (node["URIDictionary"] as? [String: Any])?["title"] as? String
                ?? node["Title"] as? String
                ?? ""
            let id = node["WebBookmarkUUID"] as? String ?? urlString
            if let visit = makeVisit(
                title: title,
                urlString: urlString,
                kind: .bookmark,
                timestamp: Self.bookmarkDate(from: node) ?? Date.distantPast,
                sourceItemID: "safari:bookmark:\(id)"
            ) {
                visits.append(visit)
            }
        }

        if let children = node["Children"] as? [Any] {
            for child in children {
                collectSafariBookmarks(from: child, into: &visits)
            }
        }
    }

    private func makeVisit(
        title: String,
        urlString: String?,
        kind: BrowserItemKind,
        timestamp: Date,
        sourceItemID: String? = nil,
        occurrenceCount: Int = 1
    ) -> BrowserVisit? {
        guard let urlString, let url = URL(string: urlString), url.scheme != nil else {
            return nil
        }
        return BrowserVisit(
            title: title,
            url: url,
            canonicalURL: canonicalizer.canonicalString(for: url),
            domain: canonicalizer.domain(for: url),
            source: .safari,
            kind: kind,
            visitedAt: timestamp,
            sourceItemID: sourceItemID,
            occurrenceCount: occurrenceCount
        )
    }

    static func dateFromSafariTimestamp(_ timestamp: Double) -> Date {
        Date(timeIntervalSinceReferenceDate: timestamp)
    }

    private static func bookmarkDate(from node: [String: Any]) -> Date? {
        for key in ["DateAdded", "WebBookmarkDateAdded", "WebBookmarkDateLastViewed"] {
            if let date = node[key] as? Date {
                return date
            }
            if let timestamp = node[key] as? Double {
                return Date(timeIntervalSinceReferenceDate: timestamp)
            }
            if let timestamp = node[key] as? String, let value = Double(timestamp) {
                return Date(timeIntervalSinceReferenceDate: value)
            }
        }
        return nil
    }
}

private func temporaryCopy(of sourceURL: URL, prefix: String) throws -> URL {
    let temporaryDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    let destination = temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        .appendingPathExtension(sourceURL.pathExtension)

    do {
        try FileManager.default.copyItem(at: sourceURL, to: destination)
        for suffix in ["-wal", "-shm"] {
            let sidecar = URL(fileURLWithPath: sourceURL.path + suffix)
            guard FileManager.default.fileExists(atPath: sidecar.path) else {
                continue
            }
            try? FileManager.default.copyItem(at: sidecar, to: URL(fileURLWithPath: destination.path + suffix))
        }
        return destination
    } catch {
        throw browserFileAccessError(for: sourceURL, error: error)
    }
}

private func removeTemporarySQLiteCopy(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
    try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + "-wal"))
    try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + "-shm"))
}

private func browserFileAccessError(for url: URL, error: Error) -> ImporterError {
    if isPermissionError(error) {
        return .privacyPermissionRequired(browser: browserName(for: url), path: url.path)
    }
    return .temporaryCopyFailed("\(url.path): \(error.localizedDescription)")
}

private func isPermissionError(_ error: Error) -> Bool {
    let nsError = error as NSError
    if nsError.domain == NSCocoaErrorDomain {
        return nsError.code == NSFileReadNoPermissionError
            || nsError.code == NSFileReadNoSuchFileError
            || nsError.code == NSFileWriteNoPermissionError
    }
    if nsError.domain == NSPOSIXErrorDomain {
        return nsError.code == Int(EACCES) || nsError.code == Int(EPERM)
    }
    return false
}

private func browserName(for url: URL) -> String {
    let path = url.path
    if path.contains("/Library/Safari/") {
        return "Safari"
    }
    if path.contains("/Application Support/Google/Chrome/") {
        return "Chrome"
    }
    return "Browser"
}
